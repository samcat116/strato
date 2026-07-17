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

    /// Result of probing the sandbox runtime's host prerequisites.
    public struct Report: Equatable, Sendable {
        /// Whether this host can run sandbox workloads right now.
        public let capable: Bool
        /// Why the runtime is unavailable, when it is.
        public let unavailabilityReason: String?

        public init(capable: Bool, unavailabilityReason: String? = nil) {
            self.capable = capable
            self.unavailabilityReason = unavailabilityReason
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
    public static func probe(
        firecracker: HypervisorSupport?,
        guestImagePath: String?,
        runtimeBuilt: Bool = SandboxRuntimeProbe.runtimeBuilt,
        jailerBlockedReason: String? = nil
    ) -> Report {
        guard runtimeBuilt else {
            return Report(
                capable: false,
                unavailabilityReason: "this agent build does not include the sandbox runtime (issue #421)")
        }
        if let jailerBlockedReason {
            return Report(
                capable: false,
                unavailabilityReason:
                    "sandbox_jailer_mode is 'required' but the jailer is unusable: \(jailerBlockedReason)")
        }
        guard let firecracker, firecracker.type == .firecracker else {
            return Report(capable: false, unavailabilityReason: "Firecracker was not probed on this host")
        }
        guard firecracker.available else {
            return Report(
                capable: false,
                unavailabilityReason: firecracker.unavailabilityReason ?? "Firecracker is unavailable")
        }
        guard let guestImagePath, !guestImagePath.isEmpty else {
            return Report(capable: false, unavailabilityReason: "sandbox_guest_image_path is not configured")
        }
        guard FileManager.default.fileExists(atPath: guestImagePath) else {
            return Report(
                capable: false,
                unavailabilityReason: "sandbox guest base image not present at \(guestImagePath)")
        }
        return Report(capable: true)
    }
}
