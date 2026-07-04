import Foundation

/// CPU architecture of a hypervisor host or a guest image.
///
/// KVM and HVF acceleration are same-architecture only, so the scheduler must
/// match guest architecture to host architecture; a mismatch would silently
/// degrade to TCG emulation.
public enum CPUArchitecture: String, Codable, CaseIterable, Sendable {
    case x86_64 = "x86_64"
    case arm64 = "arm64"

    /// The architecture this binary was compiled for (the host architecture,
    /// since agents run natively on their hypervisor node).
    public static var current: CPUArchitecture {
        #if arch(arm64)
        return .arm64
        #elseif arch(x86_64)
        return .x86_64
        #else
        #error("Unsupported CPU architecture: Strato supports x86_64 and arm64 hosts")
        #endif
    }

    /// Human-readable display name
    public var displayName: String {
        switch self {
        case .x86_64:
            return "x86_64"
        case .arm64:
            return "ARM64"
        }
    }
}
