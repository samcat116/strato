import Foundation
import Testing
@testable import StratoShared

@Suite("shared host memory contract")
struct WorkloadMemoryReservationTests {
    private let mib: Int64 = 1024 * 1024

    @Test func hotplugArchitectureAndAllowance() {
        let arm = WorkloadMemoryReservation.vm(memoryBytes: 1024 * mib, maxMemoryBytes: 1792 * mib,
            hypervisorType: .qemu, architecture: .arm64)
        let x86 = WorkloadMemoryReservation.vm(memoryBytes: 1024 * mib, maxMemoryBytes: 1792 * mib,
            hypervisorType: .qemu, architecture: .x86_64, qemuOverheadBytes: 256 * mib)
        #expect(arm.guestBytes == 1536 * mib)
        #expect(arm.effectiveBytes == 2048 * mib)
        #expect(x86.guestBytes == 1792 * mib)
        #expect(x86.effectiveBytes == 2048 * mib)
        #expect(WorkloadMemoryReservation.vm(memoryBytes: mib, maxMemoryBytes: 8 * mib,
            hypervisorType: .firecracker, architecture: .arm64).effectiveBytes == 129 * mib)
    }

    @Test func clampingAndOverflow() {
        #expect(WorkloadMemoryReservation(guestBytes: .max, backendOverheadBytes: 1).effectiveBytes == .max)
        #expect(WorkloadMemoryReservation(guestBytes: -1, backendOverheadBytes: -1).effectiveBytes == 0)
        let full = HostMemoryAccounting(physicalBytes: 1024, hostReservedBytes: .max, workloadEffectiveBytes: .max)
        #expect(full.remainingAllocatableBytes == 0)
        let exact = HostMemoryAccounting(physicalBytes: 1024, hostReservedBytes: 256, workloadEffectiveBytes: 768)
        #expect(exact.remainingAllocatableBytes == 0)
        #expect(HostMemoryAccounting(physicalBytes: 1024, hostReservedBytes: 256,
            workloadEffectiveBytes: 767).remainingAllocatableBytes == 1)
        #expect(HostMemoryAccounting(physicalBytes: 1024, hostReservedBytes: 0,
            workloadEffectiveBytes: 0, inventoryKnown: false).remainingAllocatableBytes == 0)
    }

    @Test func wireRoundTrip() throws {
        let accounting = HostMemoryAccounting(physicalBytes: 8192, hostReservedBytes: 1024,
            workloadEffectiveBytes: 2048, qemuOverheadBytes: 768)
        let resources = AgentResources(totalCPU: 4, availableCPU: 2, totalMemory: accounting.physicalBytes,
            availableMemory: accounting.remainingAllocatableBytes, totalDisk: 1, availableDisk: 1,
            memoryAccounting: accounting)
        let restored = try WireProtocol.makeDecoder().decode(AgentResources.self,
            from: WireProtocol.makeEncoder().encode(resources))
        #expect(restored.memoryAccounting == accounting)
        #expect(restored.availableMemory == 5120)
        #expect(restored.totalMemory == 8192)
    }
}
