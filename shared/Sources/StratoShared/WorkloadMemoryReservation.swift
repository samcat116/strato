import Foundation
import SwiftProtobuf

/// One host commitment. QEMU guest bytes include its realized virtio-mem region.
/// Process overhead is charged once, independently of the guest grant.
public struct WorkloadMemoryReservation: Codable, Sendable, Equatable {
    public static let defaultQEMUOverheadBytes: Int64 = 512 * 1024 * 1024
    public static let appleVirtualizationOverheadBytes: Int64 = 512 * 1024 * 1024
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
        let overhead: Int64
        switch hypervisorType {
        case .qemu: overhead = qemuOverheadBytes
        case .firecracker: overhead = firecrackerOverheadBytes
        case .appleVirtualization: overhead = appleVirtualizationOverheadBytes
        case .unspecified, .UNRECOGNIZED: overhead = .max
        }
        return Self(
            guestBytes: hypervisorType == .qemu
                ? QEMUMemoryReservation.reservedBytes(
                    memoryBytes: max(0, memoryBytes), maxMemoryBytes: maxMemoryBytes, architecture: architecture)
                : memoryBytes,
            backendOverheadBytes: overhead)
    }

    public static func sandbox(memoryBytes: Int64) -> Self {
        Self(guestBytes: memoryBytes, backendOverheadBytes: firecrackerOverheadBytes)
    }
}

/// Physical memory remains physical. Consumers use remainingAllocatableBytes directly;
/// neither the host reserve nor workload commitments may be subtracted again.
public typealias HostMemoryAccounting = Strato_Agent_V1_HostMemoryAccounting
extension Strato_Agent_V1_HostMemoryAccounting: Codable {

    public init(
        physicalBytes: Int64, hostReservedBytes: Int64, workloadEffectiveBytes: Int64,
        inventoryKnown: Bool = true,
        qemuOverheadBytes: Int64 = WorkloadMemoryReservation.defaultQEMUOverheadBytes
    ) {
        self.init()
        self._jsonPhysicalBytes = max(0, physicalBytes)
        self._jsonHostReservedBytes = max(0, hostReservedBytes)
        self._jsonWorkloadEffectiveBytes = max(0, workloadEffectiveBytes)
        self._jsonQemuOverheadBytes = max(0, qemuOverheadBytes)
        let afterHost =
            self._jsonHostReservedBytes >= self._jsonPhysicalBytes
            ? 0 : self._jsonPhysicalBytes - self._jsonHostReservedBytes
        self._jsonRemainingAllocatableBytes =
            !inventoryKnown || self._jsonWorkloadEffectiveBytes >= afterHost
            ? 0 : afterHost - self._jsonWorkloadEffectiveBytes
    }

    private enum CodingKeys: String, CodingKey {
        case physicalBytes; case hostReservedBytes; case workloadEffectiveBytes; case remainingAllocatableBytes;
        case qemuOverheadBytes
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonPhysicalBytes = try container.decode(Int64.self, forKey: .physicalBytes)
        self._jsonHostReservedBytes = try container.decode(Int64.self, forKey: .hostReservedBytes)
        self._jsonWorkloadEffectiveBytes = try container.decode(Int64.self, forKey: .workloadEffectiveBytes)
        self._jsonRemainingAllocatableBytes = try container.decode(Int64.self, forKey: .remainingAllocatableBytes)
        self._jsonQemuOverheadBytes = try container.decode(Int64.self, forKey: .qemuOverheadBytes)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonPhysicalBytes, forKey: .physicalBytes)
        try container.encode(_jsonHostReservedBytes, forKey: .hostReservedBytes)
        try container.encode(_jsonWorkloadEffectiveBytes, forKey: .workloadEffectiveBytes)
        try container.encode(_jsonRemainingAllocatableBytes, forKey: .remainingAllocatableBytes)
        try container.encode(_jsonQemuOverheadBytes, forKey: .qemuOverheadBytes)
    }

    var _jsonPhysicalBytes: Int64 {
        get { physicalBytes }
        set { let value = newValue; physicalBytes = value }
    }
    var _jsonHostReservedBytes: Int64 {
        get { hostReservedBytes }
        set { let value = newValue; hostReservedBytes = value }
    }
    var _jsonWorkloadEffectiveBytes: Int64 {
        get { workloadEffectiveBytes }
        set { let value = newValue; workloadEffectiveBytes = value }
    }
    var _jsonRemainingAllocatableBytes: Int64 {
        get { remainingAllocatableBytes }
        set { let value = newValue; remainingAllocatableBytes = value }
    }
    var _jsonQemuOverheadBytes: Int64 {
        get { qemuOverheadBytes }
        set { let value = newValue; qemuOverheadBytes = value }
    }
}
