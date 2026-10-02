import Foundation

/// One host commitment. QEMU guest bytes include its realized virtio-mem region.
/// Process overhead is charged once, independently of the guest grant.
public struct WorkloadMemoryReservation: Codable, Sendable, Equatable {
    public static let defaultQEMUOverheadBytes: Int64 = 512 * 1024 * 1024
    public static let firecrackerOverheadBytes: Int64 = 128 * 1024 * 1024
    public let guestBytes: Int64
    public let backendOverheadBytes: Int64
    public let effectiveBytes: Int64

    public init(guestBytes: Int64, backendOverheadBytes: Int64) {
        self.guestBytes = max(0, guestBytes)
        self.backendOverheadBytes = max(0, backendOverheadBytes)
        let (bytes, overflow) = self.guestBytes.addingReportingOverflow(self.backendOverheadBytes)
        self.effectiveBytes = overflow ? Int64.max : bytes
    }

    public static func vm(
        memoryBytes: Int64, maxMemoryBytes: Int64, hypervisorType: HypervisorType,
        architecture: CPUArchitecture, qemuOverheadBytes: Int64 = defaultQEMUOverheadBytes
    ) -> Self {
        Self(
            guestBytes: hypervisorType == .qemu
                ? QEMUMemoryReservation.reservedBytes(
                    memoryBytes: max(0, memoryBytes), maxMemoryBytes: maxMemoryBytes, architecture: architecture)
                : memoryBytes,
            backendOverheadBytes: hypervisorType == .qemu ? qemuOverheadBytes : firecrackerOverheadBytes)
    }

    public static func sandbox(memoryBytes: Int64) -> Self {
        Self(guestBytes: memoryBytes, backendOverheadBytes: firecrackerOverheadBytes)
    }
}

/// Physical memory remains physical. Consumers use remainingAllocatableBytes directly;
/// neither the host reserve nor workload commitments may be subtracted again.
public struct HostMemoryAccounting: Codable, Sendable, Equatable {
    public let physicalBytes: Int64
    public let hostReservedBytes: Int64
    public let workloadEffectiveBytes: Int64
    public let remainingAllocatableBytes: Int64
    public let qemuOverheadBytes: Int64

    public init(
        physicalBytes: Int64, hostReservedBytes: Int64, workloadEffectiveBytes: Int64,
        inventoryKnown: Bool = true,
        qemuOverheadBytes: Int64 = WorkloadMemoryReservation.defaultQEMUOverheadBytes
    ) {
        self.physicalBytes = max(0, physicalBytes)
        self.hostReservedBytes = max(0, hostReservedBytes)
        self.workloadEffectiveBytes = max(0, workloadEffectiveBytes)
        self.qemuOverheadBytes = max(0, qemuOverheadBytes)
        let afterHost = self.hostReservedBytes >= self.physicalBytes ? 0 : self.physicalBytes - self.hostReservedBytes
        self.remainingAllocatableBytes = !inventoryKnown || self.workloadEffectiveBytes >= afterHost
            ? 0 : afterHost - self.workloadEffectiveBytes
    }
}
