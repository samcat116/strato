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
/// Adding a case means: the data tables in this file (`isAvailable`,
/// `displayName`, `description`, `HypervisorCapabilities.capabilities(for:)`
/// — all compiler-enforced), a probe report in `HypervisorProbe.probeAll`,
/// and one driver registration in `Agent.start()`.
public enum HypervisorType: String, Codable, CaseIterable, Sendable {
    /// QEMU with KVM (Linux) or HVF (macOS) acceleration
    case qemu = "qemu"

    /// Amazon Firecracker microVM (Linux only)
    case firecracker = "firecracker"

    /// Default hypervisor for the platform
    public static var platformDefault: HypervisorType {
        #if os(Linux)
        return .qemu  // Default to QEMU, user can explicitly choose Firecracker
        #else
        return .qemu  // Firecracker not available on non-Linux platforms
        #endif
    }

    /// Whether this hypervisor is available on the current platform
    public var isAvailable: Bool {
        switch self {
        case .qemu:
            return true  // QEMU is available on all platforms
        case .firecracker:
            #if os(Linux)
            return true
            #else
            return false
            #endif
        }
    }

    /// Human-readable display name
    public var displayName: String {
        switch self {
        case .qemu:
            return "QEMU"
        case .firecracker:
            return "Firecracker"
        }
    }

    /// Description of the hypervisor
    public var description: String {
        switch self {
        case .qemu:
            return "Full-featured virtual machine monitor with broad hardware support"
        case .firecracker:
            return "Lightweight microVM optimized for fast startup and minimal overhead"
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

    /// Feature capabilities of this hypervisor
    public let capabilities: HypervisorCapabilities

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
        capabilities: HypervisorCapabilities,
        version: String? = nil
    ) {
        self.type = type
        self.available = available
        self.accelerated = accelerated
        self.unavailabilityReason = unavailabilityReason
        self.capabilities = capabilities
        self.version = version
    }
}

/// Capabilities of a hypervisor
public struct HypervisorCapabilities: Codable, Equatable, Sendable {
    /// The hypervisor type
    public let type: HypervisorType

    /// Whether the hypervisor supports pause/resume
    public let supportsPause: Bool

    /// Whether the hypervisor supports live migration
    public let supportsLiveMigration: Bool

    /// Whether the hypervisor supports snapshots
    public let supportsSnapshots: Bool

    /// Whether the hypervisor requires direct kernel boot (kernel + rootfs)
    public let requiresDirectKernelBoot: Bool

    /// Maximum vCPUs supported
    public let maxVCPUs: Int

    /// Maximum memory in bytes supported
    public let maxMemory: Int64

    public init(
        type: HypervisorType,
        supportsPause: Bool,
        supportsLiveMigration: Bool,
        supportsSnapshots: Bool,
        requiresDirectKernelBoot: Bool,
        maxVCPUs: Int,
        maxMemory: Int64
    ) {
        self.type = type
        self.supportsPause = supportsPause
        self.supportsLiveMigration = supportsLiveMigration
        self.supportsSnapshots = supportsSnapshots
        self.requiresDirectKernelBoot = requiresDirectKernelBoot
        self.maxVCPUs = maxVCPUs
        self.maxMemory = maxMemory
    }

    /// Capabilities for QEMU
    public static let qemu = HypervisorCapabilities(
        type: .qemu,
        supportsPause: true,
        supportsLiveMigration: true,
        supportsSnapshots: true,
        requiresDirectKernelBoot: false,
        maxVCPUs: 1024,
        maxMemory: 16 * 1024 * 1024 * 1024 * 1024  // 16 TB
    )

    /// Capabilities for Firecracker
    public static let firecracker = HypervisorCapabilities(
        type: .firecracker,
        supportsPause: true,
        supportsLiveMigration: false,
        supportsSnapshots: true,  // Via snapshotting
        requiresDirectKernelBoot: true,
        maxVCPUs: 32,
        maxMemory: 32 * 1024 * 1024 * 1024  // 32 GB
    )

    /// Get capabilities for a hypervisor type
    public static func capabilities(for type: HypervisorType) -> HypervisorCapabilities {
        switch type {
        case .qemu:
            return .qemu
        case .firecracker:
            return .firecracker
        }
    }
}
