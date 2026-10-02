import Foundation
import Testing
import Vapor
import StratoShared
@testable import App

@Suite("Resource class placement")
struct ResourceClassPlacementTests {
    @Test func fractionalClaimsAreAtomic() async throws {
        let store = InMemoryCoordinationStore()
        let capacity = ReservationAmounts(cpu: 1, memory: 0, disk: 0)
        for index in 0..<4 {
            #expect(
                await store.tryReserve(
                    agentKey: "host", vmId: "w\(index)",
                    amounts: ReservationAmounts(memory: 0, disk: 0, cpuMicroUnits: 250_000), capacity: capacity,
                    ttlSeconds: 60))
        }
        #expect(await store.reservedTotal(agentKey: "host").cpuMicroUnits == 1_000_000)
        #expect(
            await store.tryReserve(
                agentKey: "host", vmId: "extra",
                amounts: ReservationAmounts(memory: 0, disk: 0, cpuMicroUnits: 1), capacity: capacity, ttlSeconds: 60)
                == false)
        #expect(
            await store.tryReserve(
                agentKey: "host", vmId: "w0",
                amounts: ReservationAmounts(memory: 0, disk: 0, cpuMicroUnits: 250_000), capacity: capacity,
                ttlSeconds: 60))
    }

    @Test func saturatedCapacityCannotWrapAndAdmitAnotherClaim() async {
        let store = InMemoryCoordinationStore()
        let capacity = ReservationAmounts(memory: .max, disk: .max, cpuMicroUnits: .max)
        #expect(
            await store.tryReserve(
                agentKey: "overflow", vmId: "full", amounts: capacity, capacity: capacity, ttlSeconds: 60))
        #expect(
            await store.tryReserve(
                agentKey: "overflow", vmId: "extra", amounts: ReservationAmounts(memory: 1, disk: 1, cpuMicroUnits: 1),
                capacity: capacity, ttlSeconds: 60) == false)
        #expect(await store.reservedTotal(agentKey: "overflow") == capacity)
    }

    @Test func burstableGrowthIsRefusedButExistingGrantAndLegacySizingRemainUnchanged() throws {
        let vm = VM(
            name: "test", description: "", image: "test", projectID: UUID(), environment: "test", cpu: 2, memory: 4096,
            disk: 0)
        try WorkloadResourceClassService.requireGrowthAvailable(vm: vm, cpu: 4, memory: 8192)
        vm.resourceClass = try WorkloadResourceClassSnapshot(
            classID: WorkloadResourceClassSnapshot.burstableID, siteID: UUID(), revision: 1, policy: .burstable)
        try WorkloadResourceClassService.requireGrowthAvailable(vm: vm, cpu: 2, memory: 4096)
        #expect(throws: Abort.self) {
            try WorkloadResourceClassService.requireGrowthAvailable(vm: vm, cpu: 3, memory: 4096)
        }
        #expect(throws: Abort.self) {
            try WorkloadResourceClassService.requireGrowthAvailable(vm: vm, cpu: 2, memory: 8192)
        }
        #expect(vm.cpu == 2 && vm.memory == 4096 && vm.generation == 0)
    }

    @Test func guaranteedReferencePinsItsSiteWithoutRequiringOverlayNetworking() throws {
        let fixture = SchedulerServiceTests()
        let siteID = UUID()
        let snapshot = try WorkloadResourceClassSnapshot(
            classID: WorkloadResourceClassSnapshot.guaranteedID, siteID: siteID, revision: 1, policy: .guaranteed)
        let requirements = VMPlacementRequirements(cpu: 1, memory: 1024, disk: 0, resourceClass: snapshot)
        let selected = try SchedulerService(logger: Logger(label: "class-test")).selectAgent(
            requirements: requirements,
            from: [fixture.createTestAgent(id: "other"), fixture.createTestAgent(id: "scoped", siteID: siteID)],
            vmName: "guaranteed")
        #expect(selected == "scoped")
    }

    @Test func outstandingFractionalClaimsPreserveSubCPUCapacity() {
        let agent = SchedulerServiceTests().createTestAgent(availableCPU: 1)
        let net = agent.subtractingReservations(ReservationAmounts(memory: 0, disk: 0, cpuMicroUnits: 250_000))
        #expect(net.availableCPUMicroUnits == 750_000)
        #expect(net.availableCPU == 0)
        let second = net.subtractingReservations(ReservationAmounts(memory: 0, disk: 0, cpuMicroUnits: 250_000))
        #expect(second.availableCPUMicroUnits == 500_000)
    }

    @Test func generationClaimsReplaceRetriesButRollbackOnlyTheirOwnDelta() async throws {
        let store = InMemoryCoordinationStore()
        let id = UUID()
        let first = CoordinationService.growthReservationID(workloadID: id, generation: 1, mutationID: UUID())
        // An aborted transaction's generation may be reused by another writer.
        let second = CoordinationService.growthReservationID(workloadID: id, generation: 1, mutationID: UUID())
        #expect(first != second)
        let capacity = ReservationAmounts(memory: 4096, disk: 0, cpuMicroUnits: 500_000)
        let quarter = ReservationAmounts(memory: 1024, disk: 0, cpuMicroUnits: 250_000)
        #expect(
            await store.tryReserve(agentKey: "host", vmId: first, amounts: quarter, capacity: capacity, ttlSeconds: 60))
        #expect(
            await store.tryReserve(agentKey: "host", vmId: first, amounts: quarter, capacity: capacity, ttlSeconds: 60))
        #expect(
            await store.tryReserve(agentKey: "host", vmId: second, amounts: quarter, capacity: capacity, ttlSeconds: 60)
        )
        #expect(await store.reservedTotal(agentKey: "host").cpuMicroUnits == 500_000)
        await store.releaseReservation(agentKey: "host", vmId: second)
        #expect(await store.reservedVMIds(agentKey: "host") == [first])
        #expect(await store.reservedTotal(agentKey: "host") == quarter)
    }

    @Test func hostCriteriaRequireCompleteBackendEvidenceAndReceiptFreshness() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let siteID = UUID()
        let snapshot = try WorkloadResourceClassSnapshot(
            classID: WorkloadResourceClassSnapshot.burstableID, siteID: siteID, revision: 1, policy: .burstable)
        let signal = PressureStallTelemetry.available(
            some: .init(average10: 0, average60: 0, average300: 0, totalMicroseconds: 0), full: nil)
        let telemetry = HostResourceTelemetry(
            sampledAt: now.addingTimeInterval(9999), health: .healthy,
            cpuPressure: signal, memoryPressure: signal, ioPressure: .unavailable, swapTotalBytes: .unavailable,
            swapUsedBytes: .unavailable, zswapStoredBytes: .unavailable, zswapPoolBytes: .unavailable,
            zramUsedBytes: .unavailable, majorFaultsTotal: .unavailable, reclaimScannedPagesTotal: .unavailable,
            reclaimReclaimedPagesTotal: .unavailable, oomKillsTotal: .unavailable, mglruEnabled: .unavailable)
        let agent = Agent(
            name: "host", hostname: "host.test", version: "test", siteID: siteID,
            resources: .init(
                totalCPU: 1, availableCPU: 1, totalMemory: 4096, availableMemory: 4096, totalDisk: 4096,
                availableDisk: 4096),
            resourceTelemetry: telemetry, resourceTelemetryReceivedAt: now)
        for mask in 0..<16 {
            agent.resourceClassEnforcement = [
                .init(
                    backend: .qemuVM, controllersDelegated: mask & 1 != 0,
                    stableOwnership: mask & 2 != 0, preExecutionEnforcement: mask & 4 != 0,
                    effectiveReadback: mask & 8 != 0)
            ]
            let refusal = WorkloadResourceClassService.hostRefusal(snapshot, backend: .qemuVM, agent: agent, now: now)
            #expect((refusal == nil) == (mask == 15))
        }
        #expect(
            WorkloadResourceClassService.hostRefusal(
                snapshot, backend: .jailedFirecrackerSandbox, agent: agent, now: now) != nil)
        agent.resourceTelemetryReceivedAt = now.addingTimeInterval(-61)
        #expect(WorkloadResourceClassService.hostRefusal(snapshot, backend: .qemuVM, agent: agent, now: now) != nil)
        agent.resourceTelemetryReceivedAt = nil
        #expect(WorkloadResourceClassService.hostRefusal(snapshot, backend: .qemuVM, agent: agent, now: now) != nil)
        agent.resourceTelemetryReceivedAt = now
        agent.resourceClassEnforcement = (agent.resourceClassEnforcement ?? []) + (agent.resourceClassEnforcement ?? [])
        #expect(WorkloadResourceClassService.hostRefusal(snapshot, backend: .qemuVM, agent: agent, now: now) != nil)
    }

    @Test func burstableSchedulerFailsClosedAndOperandsRetainOverhead() throws {
        let snapshot = try WorkloadResourceClassSnapshot(
            classID: WorkloadResourceClassSnapshot.burstableID,
            siteID: UUID(), revision: 1, policy: .burstable)
        let requirements = VMPlacementRequirements(cpu: 1, memory: 1024, disk: 0, resourceClass: snapshot)
        #expect(requirements.effectiveCPU == 250_000)
        #expect(throws: SchedulerError.self) {
            try SchedulerService(logger: Logger(label: "class-test")).selectAgent(
                requirements: requirements, from: [], vmName: "burstable")
        }
    }
}
