import Foundation

/// Identity of a VM backend *driver*, not of the accelerator behind it.
///
/// QEMU and Firecracker are Linux drivers. Apple Virtualization is a native
/// macOS driver; acceleration is reported separately from driver identity.
public enum HypervisorType: String, Codable, CaseIterable, Sendable {
    /// QEMU through libvirt (Linux)
    case qemu = "qemu"

    /// Amazon Firecracker microVM (Linux only)
    case firecracker = "firecracker"

    /// Apple Virtualization.framework (macOS only)
    case appleVirtualization = "apple_virtualization"

    /// Human-readable display name
    public var displayName: String {
        switch self {
        case .qemu:
            return "QEMU"
        case .firecracker:
            return "Firecracker"
        case .appleVirtualization:
            return "Apple Virtualization"
        }
    }
}

/// Networking capability of an agent host, as reported at registration.
public enum NetworkCapability: String, Codable, CaseIterable, Sendable {
    /// Software-defined overlay networking (OVN/OVS): inter-VM traffic,
    /// tenant isolation, and inbound connections are supported.
    case overlay = "overlay"

    /// Outbound NAT (QEMU SLIRP or Apple NAT), without managed VM-to-VM guarantees,
    /// inbound routing, or logical-network isolation.
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

    /// Whether this backend can enforce and read back per-volume total IOPS
    /// and bytes-per-second ceilings. Optional/additive so registrations
    /// persisted before STR-270 decode as not capable rather than inheriting
    /// support from the backend name alone.
    public let supportsVolumeIOLimits: Bool?

    /// The hypervisor binary's version, probed at agent startup (e.g. "1.7.0"
    /// from `firecracker --version`). Optional/additive: nil from agents that
    /// predate version probing, or when the probe failed. Snapshot mobility
    /// (issue #428) keys cross-agent restore placement on Firecracker version
    /// equality, and treats nil as incompatible rather than guessing.
    public let version: String?

    /// Host-specific guest memory bounds. Apple placement requires both;
    /// older registrations without them must refresh before accepting VMs.
    public let minimumMemoryBytes: Int64?
    public let maximumMemoryBytes: Int64?

    public func supportsMemorySize(_ bytes: Int64) -> Bool {
        guard type == .appleVirtualization else { return true }
        guard let minimumMemoryBytes, let maximumMemoryBytes,
            minimumMemoryBytes > 0, maximumMemoryBytes >= minimumMemoryBytes
        else { return false }
        return bytes >= minimumMemoryBytes && bytes <= maximumMemoryBytes && bytes % (1 << 20) == 0
    }

    public init(
        type: HypervisorType,
        available: Bool,
        accelerated: Bool,
        unavailabilityReason: String? = nil,
        supportsSnapshots: Bool? = nil,
        supportsVsock: Bool? = nil,
        supportsGuestExec: Bool? = nil,
        supportsVolumeIOLimits: Bool? = nil,
        version: String? = nil,
        minimumMemoryBytes: Int64? = nil,
        maximumMemoryBytes: Int64? = nil
    ) {
        self.type = type
        self.available = available
        self.accelerated = accelerated
        self.unavailabilityReason = unavailabilityReason
        self.supportsSnapshots = supportsSnapshots ?? type.supportsSnapshots
        self.supportsVsock = supportsVsock
        self.supportsGuestExec = supportsGuestExec
        self.supportsVolumeIOLimits = supportsVolumeIOLimits
        self.version = version
        self.minimumMemoryBytes = minimumMemoryBytes
        self.maximumMemoryBytes = maximumMemoryBytes
    }
    private enum CodingKeys: String, CodingKey {
        case type, available, accelerated, unavailabilityReason, supportsSnapshots
        case supportsVsock, supportsGuestExec, supportsVolumeIOLimits, version, minimumMemoryBytes, maximumMemoryBytes
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
        supportsVolumeIOLimits = try container.decodeIfPresent(Bool.self, forKey: .supportsVolumeIOLimits)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        minimumMemoryBytes = try container.decodeIfPresent(Int64.self, forKey: .minimumMemoryBytes)
        maximumMemoryBytes = try container.decodeIfPresent(Int64.self, forKey: .maximumMemoryBytes)
    }
}

extension HypervisorType {
    fileprivate var supportsSnapshots: Bool {
        switch self {
        case .qemu, .firecracker:
            return true
        case .appleVirtualization:
            return false
        }
    }
}
