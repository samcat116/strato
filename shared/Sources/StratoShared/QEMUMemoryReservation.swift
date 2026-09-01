import Foundation

/// QEMU virtio-mem reservation arithmetic shared by placement preflight and
/// node admission. The block size follows the guest architecture's hot-plug
/// rules; sub-block headroom cannot be realized and therefore is not reserved.
public enum QEMUMemoryReservation {
    public static func blockBytes(architecture: CPUArchitecture) -> Int64 {
        switch architecture {
        case .arm64: return 512 * 1024 * 1024
        case .x86_64: return 2 * 1024 * 1024
        }
    }

    public static func alignedHotplugBytes(
        memoryBytes: Int64, maxMemoryBytes: Int64, architecture: CPUArchitecture
    ) -> Int64 {
        let (requested, overflow) = maxMemoryBytes.subtractingReportingOverflow(memoryBytes)
        guard !overflow, requested > 0 else { return 0 }
        let block = blockBytes(architecture: architecture)
        return requested - (requested % block)
    }

    /// The realizable hot-plug region requested by a VM spec. The architecture
    /// is the guest's: QEMU derives virtio-mem's block size from its page size.
    public static func alignedHotplugBytes(
        spec: VMSpec, architecture: CPUArchitecture
    ) -> Int64 {
        alignedHotplugBytes(
            memoryBytes: spec.memoryBytes,
            maxMemoryBytes: spec.maxMemoryBytes,
            architecture: architecture)
    }

    public static func reservedBytes(
        memoryBytes: Int64, maxMemoryBytes: Int64, architecture: CPUArchitecture
    ) -> Int64 {
        let hotplug = alignedHotplugBytes(
            memoryBytes: memoryBytes, maxMemoryBytes: maxMemoryBytes, architecture: architecture)
        let (reserved, overflow) = memoryBytes.addingReportingOverflow(hotplug)
        return overflow ? Int64.max : reserved
    }
}
