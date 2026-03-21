import Foundation

/// Type of hypervisor used to run VMs
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

/// Capabilities of a hypervisor
public struct HypervisorCapabilities: Codable, Sendable {
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
