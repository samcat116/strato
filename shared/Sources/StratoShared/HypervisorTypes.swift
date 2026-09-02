import Foundation

/// Identity of a VM backend *driver*, not of the accelerator behind it.
///
/// `.qemu` is the QEMU driver wherever it runs — accelerated by KVM on Linux
/// or Hypervisor.framework (HVF) on macOS, falling back to TCG emulation
/// when neither is usable. Whether acceleration is actually in effect is a
/// per-host attribute probed at agent startup and reported separately
/// (`HypervisorSupport.accelerated`), never encoded in this enum. A backend
/// that talks to a different VMM (e.g. a native Virtualization.framework
/// driver on macOS) would be a new case here with its own `HypervisorService`
/// conformance, not a variation of `.qemu`.
///
/// Adding a case means: `displayName`, the default snapshot capability on
/// `HypervisorSupport`, a probe report in `HypervisorProbe.probeAll`, and one
/// driver registration in `Agent.start()`.
public enum HypervisorType: String, Codable, CaseIterable, Sendable {
    /// QEMU with KVM (Linux) or HVF (macOS) acceleration
    case qemu = "qemu"

    /// Amazon Firecracker microVM (Linux only)
    case firecracker = "firecracker"

    /// Human-readable display name
    public var displayName: String {
        switch self {
        case .qemu:
            return "QEMU"
        case .firecracker:
            return "Firecracker"
        }
    }
}

/// Networking capability of an agent host, as reported at registration.
public enum NetworkCapability: String, Codable, CaseIterable, Sendable {
    /// Software-defined overlay networking (OVN/OVS): inter-VM traffic,
    /// tenant isolation, and inbound connections are supported.
    case overlay = "overlay"

    /// User-mode (SLIRP) networking only: outbound NAT, no VM-to-VM traffic,
    /// no inbound connections, no isolation.
    case userMode = "user_mode"
}

/// One hypervisor on an agent host: what it is, whether it can actually run
/// VMs right now (probed at agent startup, not assumed from the platform),
/// and what it supports.
public struct HypervisorSupport: Codable, Equatable, Sendable {
    /// The hypervisor type
    public let type: HypervisorType

    /// Whether the hypervisor is usable on this host (binary present, etc.)
    public let available: Bool

    /// Whether hardware acceleration (KVM/HVF) backs this hypervisor
    public let accelerated: Bool

    /// Why the hypervisor is unavailable, when `available` is false
    public let unavailabilityReason: String?

    /// Whether this backend can create and restore snapshots.
    public let supportsSnapshots: Bool

    /// Whether this host can attach a virtio-vsock device for this
    /// hypervisor. Optional/additive so persisted registrations from before
    /// vsock probing still decode; absence must be treated as not capable.
    public let supportsVsock: Bool?

    /// Whether this agent can bridge guest-exec sessions to VMs running on
    /// this hypervisor. Optional/additive because virtio-vsock availability
    /// alone does not imply that the node-agent bridge exists; absence must
    /// be treated as not capable.
    public let supportsGuestExec: Bool?

    /// The hypervisor binary's version, probed at agent startup (e.g. "1.7.0"
    /// from `firecracker --version`). Optional/additive: nil from agents that
    /// predate version probing, or when the probe failed. Snapshot mobility
    /// (issue #428) keys cross-agent restore placement on Firecracker version
    /// equality, and treats nil as incompatible rather than guessing.
    public let version: String?

    public init(
        type: HypervisorType,
        available: Bool,
        accelerated: Bool,
        unavailabilityReason: String? = nil,
        supportsSnapshots: Bool? = nil,
        supportsVsock: Bool? = nil,
        supportsGuestExec: Bool? = nil,
        version: String? = nil
    ) {
        self.type = type
        self.available = available
        self.accelerated = accelerated
        self.unavailabilityReason = unavailabilityReason
        self.supportsSnapshots = supportsSnapshots ?? type.supportsSnapshots
        self.supportsVsock = supportsVsock
        self.supportsGuestExec = supportsGuestExec
        self.version = version
    }
    private enum CodingKeys: String, CodingKey {
        case type, available, accelerated, unavailabilityReason, supportsSnapshots
        case supportsVsock, supportsGuestExec, version
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(HypervisorType.self, forKey: .type)
        available = try container.decode(Bool.self, forKey: .available)
        accelerated = try container.decode(Bool.self, forKey: .accelerated)
        unavailabilityReason = try container.decodeIfPresent(String.self, forKey: .unavailabilityReason)
        supportsSnapshots =
            try container.decodeIfPresent(Bool.self, forKey: .supportsSnapshots)
            ?? type.supportsSnapshots
        supportsVsock = try container.decodeIfPresent(Bool.self, forKey: .supportsVsock)
        supportsGuestExec = try container.decodeIfPresent(Bool.self, forKey: .supportsGuestExec)
        version = try container.decodeIfPresent(String.self, forKey: .version)
    }
}

extension HypervisorType {
    fileprivate var supportsSnapshots: Bool {
        switch self {
        case .qemu, .firecracker:
            return true
        }
    }
}
