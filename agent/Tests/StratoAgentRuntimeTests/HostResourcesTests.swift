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

    @Test("managed allocation growth retains the later conservative sample")
    func allocationRaceIsConservative() {
        let unmanaged = HostResources.conservativeUnmanagedDiskUsage(
            capacitySamples: [
                (total: 100 * gib, free: 30 * gib),
                (total: 100 * gib, free: 0),
            ],
            managedAllocated: 40 * gib)

        #expect(unmanaged == 60 * gib)
    }

    @Test("managed discard retains the earlier conservative sample")
    func discardRaceIsConservative() {
        let unmanaged = HostResources.conservativeUnmanagedDiskUsage(
            capacitySamples: [
                (total: 100 * gib, free: 30 * gib),
                (total: 100 * gib, free: 60 * gib),
            ],
            managedAllocated: 40 * gib)

        #expect(unmanaged == 30 * gib)
    }

    @Test("time-skewed per-volume allocations are not subtracted")
    func timeSkewedAllocationSweepIsRejected() {
        let first = ["volume-a": 70 * gib, "volume-b": 40 * gib]
        let second = ["volume-a": 30 * gib, "volume-b": 40 * gib]
        let samples = [
            (total: 150 * gib, free: 50 * gib),
            (total: 150 * gib, free: 50 * gib),
            (total: 150 * gib, free: 50 * gib),
        ]

        let managed = HostResources.validatedManagedDiskAllocation(
            first: first, second: second, capacitySamples: samples)
        let unmanaged = HostResources.conservativeUnmanagedDiskUsage(
            capacitySamples: samples, managedAllocated: managed ?? 0)

        #expect(managed == nil)
        #expect(unmanaged == 100 * gib)
    }

    @Test("an impossible stable allocation sum is not subtracted")
    func impossibleStableAllocationSweepIsRejected() {
        let allocations = ["volume-a": 70 * gib, "volume-b": 40 * gib]
        let samples = [
            (total: 150 * gib, free: 50 * gib),
            (total: 150 * gib, free: 50 * gib),
            (total: 150 * gib, free: 50 * gib),
        ]

        #expect(
            HostResources.validatedManagedDiskAllocation(
                first: allocations, second: allocations,
                capacitySamples: samples) == nil)
    }

    @Test("a stable physically possible allocation sum is subtracted")
    func stableAllocationSweepIsAccepted() {
        let allocations = ["volume-a": 20 * gib, "volume-b": 20 * gib]
        let samples = [
            (total: 100 * gib, free: 30 * gib),
            (total: 100 * gib, free: 30 * gib),
            (total: 100 * gib, free: 30 * gib),
        ]

        #expect(
            HostResources.validatedManagedDiskAllocation(
                first: allocations, second: allocations,
                capacitySamples: samples) == 40 * gib)
    }
}
