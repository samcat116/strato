import Foundation
import StratoShared

/// Probes whether this host can run sandbox workloads — OCI-image Firecracker
/// microVMs (issue #410). The result drives the explicit capability signal the
/// scheduler keys sandbox placement on (`AgentRegisterMessage.sandboxCapable`,
/// issue #415): speaking wire protocol v5 is deliberately not sufficient, so
/// the agent must prove the runtime's host prerequisites at every registration.
///
/// Capability requires everything a Firecracker VM needs — the binary and KVM,
/// both already folded into the Firecracker probe's `available` — plus the
/// sandbox guest base image (the maintained kernel + init/guest agent, issue
/// #419) present on disk. The guest image is the natural switch: a host that
/// has Firecracker but no guest image cannot boot any sandbox, and gating on
/// its presence means the capability lights up exactly when the runtime's
/// artifacts are installed.
///
/// There are **two** capabilities here, and the second is strictly stronger
/// (STR-103): whether this host can give a sandbox a *NIC*. It needs OVN, the
/// jailer barrier, and a guest image whose init configures an interface — none
/// of which the first capability implies, and none of which any wire version
/// implies either. The report carries both, each with its own operator-facing
/// reason, because "runs sandboxes but cannot network them" is a real and
/// otherwise invisible state.
public enum SandboxRuntimeProbe {

    /// Well-known capability string advertised in the legacy `capabilities`
    /// list alongside the typed `sandboxCapable` flag (for operator-facing
    /// display; the scheduler reads only the typed flag).
    public static let capabilityName = "sandbox_runtime"

    /// Whether this agent build actually contains the sandbox runtime driver
    /// (`SandboxRuntimeService`, issue #421). Now that the runtime ships
    /// (`FirecrackerSandboxRuntime`, registered by the Agent on Linux), the
    /// hard build gate is open; the remaining host prerequisites below — a
    /// usable Firecracker and the guest base image on disk — decide whether a
    /// given host actually advertises the capability.
    public static let runtimeBuilt = true

    /// Well-known capability string for sandbox *networking* (STR-103),
    /// advertised alongside `capabilityName` when a sandbox on this host can
    /// have a NIC. Display-only, like its sibling: the scheduler and
    /// desired-state assembly read the typed
    /// `AgentRegisterMessage.sandboxNetworkingCapable` flag.
    public static let networkingCapabilityName = "sandbox_networking"

    /// Result of probing the sandbox runtime's host prerequisites.
    public struct Report: Equatable, Sendable {
        /// Whether this host can run sandbox workloads right now.
        public let capable: Bool
        /// Why the runtime is unavailable, when it is.
        public let unavailabilityReason: String?
        /// Whether a sandbox on this host can have a NIC (STR-103). Strictly
        /// stronger than ``capable`` — every network-free prerequisite plus
        /// OVN, the jailer, and a guest image that configures an interface.
        public let networkingCapable: Bool
        /// Why sandbox networking is unavailable, when it is. Always populated
        /// when ``networkingCapable`` is false, because this is the only place
        /// an operator ever learns that a host runs sandboxes but silently
        /// cannot network them.
        public let networkingUnavailabilityReason: String?

        public init(
            capable: Bool,
            unavailabilityReason: String? = nil,
            networkingCapable: Bool = false,
            networkingUnavailabilityReason: String? = nil
        ) {
            self.capable = capable
            self.unavailabilityReason = unavailabilityReason
            self.networkingCapable = networkingCapable
            self.networkingUnavailabilityReason = networkingUnavailabilityReason
        }

        /// A report for a host that cannot run sandboxes at all. Networking is
        /// unavailable for the same reason, restated rather than left nil — an
        /// operator reading the networking line should not have to know it is
        /// downstream of the other.
        static func unavailable(_ reason: String) -> Report {
            Report(
                capable: false, unavailabilityReason: reason,
                networkingCapable: false,
                networkingUnavailabilityReason: "the sandbox runtime is unavailable: \(reason)")
        }
    }

    /// Probe sandbox-runtime availability from the already-probed Firecracker
    /// report and the configured guest base image location.
    ///
    /// - Parameters:
    ///   - firecracker: The Firecracker entry from `HypervisorProbe.probeAll`
    ///     (post host-preflight gating), or nil when none was probed.
    ///   - guestImagePath: Where the guest base image is installed
    ///     (`sandbox_guest_image_path`). File or directory — the internal
    ///     layout is owned by the guest-image work (issue #419); this probe
    ///     only asserts presence.
    ///   - runtimeBuilt: Whether the running build includes the sandbox
    ///     runtime driver. Defaults to this build's `runtimeBuilt` constant;
    ///     injectable so tests can exercise the host-prerequisite checks.
    ///   - jailerBlockedReason: Non-nil when `sandbox_jailer_mode = "required"`
    ///     could not be satisfied at agent start (issue #425). Running
    ///     untrusted workloads unjailed on a host whose operator demanded the
    ///     jailer is not an option, so the capability goes dark instead.
    ///   - jailsNewSandboxes: Whether the jailer barrier is actually applied to
    ///     sandboxes created from now on. Only relevant to the networking arm:
    ///     an unjailed sandbox runs in the host network namespace and there is
    ///     nowhere to attach its NIC (STR-100).
    ///   - networkCapability: The backend this agent reports at registration.
    ///     Only `.overlay` can realize a sandbox NIC — the veth-plus-in-namespace-TAP
    ///     recipe is OVN/OVS all the way down, and Firecracker's only network
    ///     backend is a TAP opened by name.
    ///   - fileManager: Injected for testing.
    public static func probe(
        firecracker: HypervisorSupport?,
        guestImagePath: String?,
        runtimeBuilt: Bool = SandboxRuntimeProbe.runtimeBuilt,
        jailerBlockedReason: String? = nil,
        jailsNewSandboxes: Bool = false,
        networkCapability: NetworkCapability? = nil,
        fileManager: FileManager = .default
    ) -> Report {
        guard runtimeBuilt else {
            return .unavailable("this agent build does not include the sandbox runtime (issue #421)")
        }
        if let jailerBlockedReason {
            return .unavailable(
                "sandbox_jailer_mode is 'required' but the jailer is unusable: \(jailerBlockedReason)")
        }
        guard let firecracker, firecracker.type == .firecracker else {
            return .unavailable("Firecracker was not probed on this host")
        }
        guard firecracker.available else {
            return .unavailable(firecracker.unavailabilityReason ?? "Firecracker is unavailable")
        }
        guard let guestImagePath, !guestImagePath.isEmpty else {
            return .unavailable("sandbox_guest_image_path is not configured")
        }
        guard fileManager.fileExists(atPath: guestImagePath) else {
            return .unavailable("sandbox guest base image not present at \(guestImagePath)")
        }
        let networkingBlocker = networkingUnavailability(
            guestImagePath: guestImagePath, jailsNewSandboxes: jailsNewSandboxes,
            networkCapability: networkCapability, fileManager: fileManager)
        return Report(
            capable: true,
            networkingCapable: networkingBlocker == nil,
            networkingUnavailabilityReason: networkingBlocker)
    }

    /// Why this host cannot give a sandbox a NIC, or nil when it can.
    ///
    /// Only reached once the base sandbox prerequisites hold, so it asks the
    /// three questions that are specific to the NIC — and asks the guest image
    /// last, because that is the read that touches the disk. A manifest that
    /// cannot be read or is a schema this build does not know is *not*
    /// capable: unlike the base capability (which deliberately never fails on a
    /// parse error, since a host that boots sandboxes today must keep booting
    /// them), advertising networking off an unreadable manifest would be
    /// claiming a guest behavior nothing has confirmed.
    private static func networkingUnavailability(
        guestImagePath: String,
        jailsNewSandboxes: Bool,
        networkCapability: NetworkCapability?,
        fileManager: FileManager
    ) -> String? {
        guard networkCapability == .overlay else {
            return "sandbox networking needs network_mode = \"ovn\" with a connected OVN/OVS "
                + "(this host reports \(networkCapability?.rawValue ?? "no networking capability"))"
        }
        guard jailsNewSandboxes else {
            return "a sandbox NIC lives in the jail's network namespace, and this agent creates "
                + "sandboxes unjailed; set sandbox_jailer_mode = \"required\" and satisfy its prerequisites"
        }
        let capabilities: Set<String>
        do {
            capabilities = try SandboxGuestImage.capabilities(
                atDirectory: guestImagePath, fileManager: fileManager)
        } catch {
            return "the installed sandbox guest image could not be read: "
                + ((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        guard capabilities.contains(SandboxGuestImage.GuestCapability.network) else {
            return "the installed sandbox guest image at \(guestImagePath) does not advertise the "
                + "'\(SandboxGuestImage.GuestCapability.network)' capability; it predates in-guest "
                + "interface bring-up (STR-101) and would refuse a config drive carrying a NIC"
        }
        return nil
    }
}
