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
