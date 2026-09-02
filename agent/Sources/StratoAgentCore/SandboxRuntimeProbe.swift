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
/// #419) installed with the current manifest. The guest image is the natural
/// switch: a host that has Firecracker but no current guest image cannot boot
/// a supported sandbox.
///
/// There are **two** capabilities here, and the second is strictly stronger
/// (STR-103): whether this host can give a sandbox a *NIC*. It needs OVN, the
/// jailer barrier, and a guest image whose init configures an interface — none
/// of which the first capability implies, and none of which any wire version
/// implies either. The report carries both, each with its own operator-facing
/// reason, because "runs sandboxes but cannot network them" is a real and
/// otherwise invisible state.
public enum SandboxRuntimeProbe {

    /// Result of probing the sandbox runtime's host prerequisites.
    public struct Report: Equatable, Sendable {
        /// Whether this host can run sandbox workloads right now.
        public let capable: Bool
        /// Why the runtime is unavailable, when it is.
        public let unavailabilityReason: String?
        /// Why sandbox networking is unavailable, or nil when it is available.
        ///
        /// Not defaulted in the initializer, unlike `unavailabilityReason`:
        /// this is the *only* place an operator ever learns that a host runs
        /// sandboxes but silently cannot network them, so every construction
        /// site has to answer the question rather than fall through to a nil
        /// that reads as "fine".
        public let networkingUnavailabilityReason: String?

        /// Whether a sandbox on this host can have a NIC (STR-103). Strictly
        /// stronger than ``capable`` — every network-free prerequisite plus
        /// OVN, the jailer, and a guest image that configures an interface.
        ///
        /// Derived rather than stored so "withheld" and "here is why" cannot
        /// drift apart: there is no way to construct a report that refuses the
        /// NIC without naming what would restore it. (``capable`` keeps the
        /// looser stored pair it has had since issue #415 — its reason is a
        /// convenience, not the sole surface, since a host with no sandbox
        /// capability is visible as such in the fleet view.)
        public var networkingCapable: Bool { networkingUnavailabilityReason == nil }

        public init(
            capable: Bool,
            unavailabilityReason: String? = nil,
            networkingUnavailabilityReason: String?
        ) {
            self.capable = capable
            self.unavailabilityReason = unavailabilityReason
            self.networkingUnavailabilityReason = networkingUnavailabilityReason
        }

        /// A report for a host that cannot run sandboxes at all. Networking is
        /// unavailable for the same reason, restated rather than left nil — an
        /// operator reading the networking line should not have to know it is
        /// downstream of the other.
        static func unavailable(_ reason: String) -> Report {
            Report(
                capable: false, unavailabilityReason: reason,
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
    ///     (`sandbox_guest_image_path`). The current manifest schema is part of
    ///     the base capability: an old installed guest must be replaced before
    ///     this agent accepts sandbox placements.
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
        jailerBlockedReason: String? = nil,
        jailsNewSandboxes: Bool = false,
        networkCapability: NetworkCapability? = nil,
        fileManager: FileManager = .default
    ) -> Report {
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
        let capabilities: Set<String>
        do {
            capabilities = try SandboxGuestImage.capabilities(
                atDirectory: guestImagePath, fileManager: fileManager)
        } catch {
            return .unavailable(
                "the installed sandbox guest image could not be read: "
                    + ((error as? LocalizedError)?.errorDescription ?? "\(error)"))
        }
        return Report(
            capable: true,
            networkingUnavailabilityReason: networkingUnavailability(
                guestImagePath: guestImagePath, capabilities: capabilities,
                jailsNewSandboxes: jailsNewSandboxes, networkCapability: networkCapability))
    }

    /// Why this host cannot give a sandbox a NIC, or nil when it can.
    ///
    /// Only reached once the base sandbox prerequisites and current guest
    /// manifest hold, so it asks the remaining questions that are specific to
    /// the NIC.
    private static func networkingUnavailability(
        guestImagePath: String,
        capabilities: Set<String>,
        jailsNewSandboxes: Bool,
        networkCapability: NetworkCapability?
    ) -> String? {
        guard networkCapability == .overlay else {
            return "sandbox networking needs network_mode = \"ovn\" with a connected OVN/OVS "
                + "(this host reports \(networkCapability?.rawValue ?? "no networking capability"))"
        }
        guard jailsNewSandboxes else {
            return "a sandbox NIC lives in the jail's network namespace, and this agent creates "
                + "sandboxes unjailed; set sandbox_jailer_mode = \"required\" and satisfy its prerequisites"
        }
        guard capabilities.contains(SandboxGuestImage.GuestCapability.network) else {
            return "the installed sandbox guest image at \(guestImagePath) does not advertise the "
                + "'\(SandboxGuestImage.GuestCapability.network)' capability; it predates in-guest "
                + "interface bring-up (STR-101) and would refuse a config drive carrying a NIC"
        }
        return nil
    }
}
