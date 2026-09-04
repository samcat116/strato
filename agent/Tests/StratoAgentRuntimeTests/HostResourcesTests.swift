import Testing
import StratoAgentCore

@testable import StratoAgentRuntime

@Suite("host disk commitment baseline")
struct HostResourcesTests {
    private let gib: Int64 = 1_073_741_824

    @Test("unmanaged filesystem use reduces committed availability")
    func unmanagedUsageIsReserved() {
        let unmanaged = HostResources.unmanagedDiskUsage(
            total: 100 * gib,
            free: 30 * gib,
            managedAllocated: 0)
        let snapshot = HostCapacitySnapshot(
            total: HostReservation(diskBytes: 100 * gib),
            reserved: HostReservation(diskBytes: unmanaged))

        #expect(unmanaged == 70 * gib)
        #expect(snapshot.available.diskBytes == 30 * gib)
    }

    @Test("allocated managed blocks are not charged twice")
    func managedAllocationOffsetsPhysicalUsage() {
        let unmanaged = HostResources.unmanagedDiskUsage(
            total: 100 * gib,
            free: 50 * gib,
            managedAllocated: 10 * gib)
        let snapshot = HostCapacitySnapshot(
            total: HostReservation(diskBytes: 100 * gib),
            reserved: HostReservation(diskBytes: 20 * gib + unmanaged))

        #expect(unmanaged == 40 * gib)
        #expect(snapshot.available.diskBytes == 40 * gib)
    }

    @Test("managed allocation is bounded by total physical use")
    func managedAllocationCannotCreateCapacity() {
        let unmanaged = HostResources.unmanagedDiskUsage(
            total: 100 * gib,
            free: 30 * gib,
            managedAllocated: 80 * gib)

        #expect(unmanaged == 0)
    }
}
