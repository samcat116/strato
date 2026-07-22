import Foundation
import Testing
import Vapor
import StratoShared
@testable import App

/// Tests for the Valkey coordination layer (issue #258) against the in-memory
/// store, which mirrors the Valkey store's semantics: TTL expiry, NX lock
/// acquisition, and atomic capacity reservation.
@Suite("CoordinationService Tests")
struct CoordinationServiceTests {

    private func makeService() -> CoordinationService {
        CoordinationService(store: InMemoryCoordinationStore(), logger: Logger(label: "coordination-test"))
    }

    // MARK: - Agent presence

    @Test("Presence is visible after recording and absent for unknown agents")
    func presenceRoundTrip() async {
        let service = makeService()

        #expect(await service.isAgentPresent(agentKey: agentKey("agent-a")) == false)

        await service.recordAgentPresence(agentKey: agentKey("agent-a"))
        #expect(await service.isAgentPresent(agentKey: agentKey("agent-a")) == true)
        #expect(await service.isAgentPresent(agentKey: agentKey("agent-b")) == false)
    }

    @Test("Presence expires after its TTL")
    func presenceTTLExpiry() async throws {
        let service = makeService()

        await service.recordAgentPresence(agentKey: agentKey("agent-a"), ttlSeconds: 1)
        #expect(await service.isAgentPresent(agentKey: agentKey("agent-a")) == true)

        try await Task.sleep(for: .milliseconds(1200))
        #expect(await service.isAgentPresent(agentKey: agentKey("agent-a")) == false)
    }

    @Test("Heartbeat refresh extends presence")
    func presenceRefresh() async throws {
        let service = makeService()

        await service.recordAgentPresence(agentKey: agentKey("agent-a"), ttlSeconds: 1)
        try await Task.sleep(for: .milliseconds(600))
        await service.recordAgentPresence(agentKey: agentKey("agent-a"), ttlSeconds: 1)
        try await Task.sleep(for: .milliseconds(600))

        // 1.2s after the first write, but only 0.6s after the refresh.
        #expect(await service.isAgentPresent(agentKey: agentKey("agent-a")) == true)
    }

    // MARK: - Sweep locks

    @Test("Sweep lock excludes a second acquirer until the TTL expires")
    func sweepLockExclusion() async throws {
        let service = makeService()

        #expect(await service.acquireSweepLock("stuck_vms", ttlSeconds: 1) == true)
        // Second pass in the same window — held, must skip.
        #expect(await service.acquireSweepLock("stuck_vms", ttlSeconds: 1) == false)
        // A different sweep has its own lock.
        #expect(await service.acquireSweepLock("other_sweep", ttlSeconds: 1) == true)

        try await Task.sleep(for: .milliseconds(1200))
        // Expired — the next interval's pass may run.
        #expect(await service.acquireSweepLock("stuck_vms", ttlSeconds: 1) == true)
    }

    // MARK: - Placement reservations

    private let capacity = ReservationAmounts(cpu: 4, memory: 8192, disk: 50000)
    private let wholeAgent = ReservationAmounts(cpu: 4, memory: 8192, disk: 50000)

    @Test("Two concurrent reservations for capacity that fits one: exactly one wins")
    func concurrentReservationRace() async {
        let service = makeService()

        let results = await withTaskGroup(of: Bool.self) { group in
            for vmId in ["vm-1", "vm-2"] {
                group.addTask {
                    await service.reserveCapacity(
                        agentId: "agent-a", vmId: vmId, amounts: self.wholeAgent, capacity: self.capacity)
                }
            }
            var wins: [Bool] = []
            for await result in group { wins.append(result) }
            return wins
        }

        #expect(results.count(where: { $0 }) == 1)
        #expect(results.count(where: { !$0 }) == 1)
    }

    @Test("Releasing a reservation frees its capacity")
    func releaseFreesCapacity() async {
        let service = makeService()

        #expect(
            await service.reserveCapacity(
                agentId: "agent-a", vmId: "vm-1", amounts: wholeAgent, capacity: capacity) == true)
        #expect(
            await service.reserveCapacity(
                agentId: "agent-a", vmId: "vm-2", amounts: wholeAgent, capacity: capacity) == false)

        await service.releaseReservation(agentId: "agent-a", vmId: "vm-1")

        #expect(
            await service.reserveCapacity(
                agentId: "agent-a", vmId: "vm-2", amounts: wholeAgent, capacity: capacity) == true)
    }

    @Test("Re-reserving the same VM replaces its amounts instead of double-counting")
    func reReserveIsIdempotent() async {
        let service = makeService()

        #expect(
            await service.reserveCapacity(
                agentId: "agent-a", vmId: "vm-1", amounts: wholeAgent, capacity: capacity) == true)
        // A retried placement of the same VM must not fail against its own reservation.
        #expect(
            await service.reserveCapacity(
                agentId: "agent-a", vmId: "vm-1", amounts: wholeAgent, capacity: capacity) == true)

        let reserved = await service.activeReservations(agentId: "agent-a")
        #expect(reserved == wholeAgent)
    }

    @Test("Reservations expire after their TTL")
    func reservationTTLExpiry() async throws {
        let service = makeService()

        #expect(
            await service.reserveCapacity(
                agentId: "agent-a", vmId: "vm-1", amounts: wholeAgent, capacity: capacity, ttlSeconds: 1)
                == true)
        #expect(
            await service.reserveCapacity(
                agentId: "agent-a", vmId: "vm-2", amounts: wholeAgent, capacity: capacity) == false)

        try await Task.sleep(for: .milliseconds(1200))

        // The stale reservation expired; capacity is placeable again.
        #expect(
            await service.reserveCapacity(
                agentId: "agent-a", vmId: "vm-2", amounts: wholeAgent, capacity: capacity) == true)
    }

    @Test("Heartbeat-reported VMs release exactly their reservations")
    func heartbeatReportedVMsReleaseReservations() async {
        let service = makeService()
        let half = ReservationAmounts(cpu: 2, memory: 4096, disk: 25000)

        _ = await service.reserveCapacity(agentId: "agent-a", vmId: "vm-1", amounts: half, capacity: capacity)
        _ = await service.reserveCapacity(agentId: "agent-a", vmId: "vm-2", amounts: half, capacity: capacity)

        // Heartbeat lists vm-1 (created) and vm-9 (no reservation): only
        // vm-1's reservation is released; vm-2's placement is still in flight.
        await service.releaseReservations(agentId: "agent-a", vmIds: ["vm-1", "vm-9"])

        let reserved = await service.activeReservations(agentId: "agent-a")
        #expect(reserved == half)
    }

    @Test("Active reservations sum across VMs and are scoped per agent")
    func activeReservationsSum() async {
        let service = makeService()
        let half = ReservationAmounts(cpu: 2, memory: 4096, disk: 25000)

        _ = await service.reserveCapacity(agentId: "agent-a", vmId: "vm-1", amounts: half, capacity: capacity)
        _ = await service.reserveCapacity(agentId: "agent-a", vmId: "vm-2", amounts: half, capacity: capacity)

        let reservedA = await service.activeReservations(agentId: "agent-a")
        #expect(reservedA == ReservationAmounts(cpu: 4, memory: 8192, disk: 50000))

        let reservedB = await service.activeReservations(agentId: "agent-b")
        #expect(reservedB == .zero)
    }
}

/// Scheduler placement with the reservation step (issue #258).
@Suite("Scheduler Reservation Tests")
struct SchedulerReservationTests {

    private func makeScheduler() -> SchedulerService {
        SchedulerService(logger: Logger(label: "scheduler-reservation-test"))
    }

    private func makeCoordination() -> CoordinationService {
        CoordinationService(store: InMemoryCoordinationStore(), logger: Logger(label: "coordination-test"))
    }

    private func agent(
        id: String,
        availableCPU: Int = 4,
        availableMemory: Int64 = 8192,
        availableDisk: Int64 = 50000
    ) -> SchedulableAgent {
        SchedulableAgent(
            id: id,
            name: id,
            totalCPU: 8,
            availableCPU: availableCPU,
            totalMemory: 16384,
            availableMemory: availableMemory,
            totalDisk: 100_000,
            availableDisk: availableDisk,
            status: .online,
            runningVMCount: 0
        )
    }

    private let vmRequirements = VMPlacementRequirements(cpu: 4, memory: 8192, disk: 50000)

    @Test("Two concurrent creates against capacity for one: one placement, one clean scheduling failure")
    func concurrentPlacementRace() async {
        let scheduler = makeScheduler()
        let coordination = makeCoordination()
        // One agent with room for exactly one of the two VMs.
        let agents = [agent(id: "agent-a")]

        let outcomes = await withTaskGroup(of: Result<String, Error>.self) { group in
            for vmId in ["vm-1", "vm-2"] {
                group.addTask {
                    do {
                        let placed = try await scheduler.selectAndReserveAgent(
                            requirements: self.vmRequirements,
                            vmId: vmId,
                            from: agents,
                            coordination: coordination,
                            vmName: vmId
                        )
                        return .success(placed)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var collected: [Result<String, Error>] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }

        let placements = outcomes.compactMap { try? $0.get() }
        let failures = outcomes.filter { (try? $0.get()) == nil }

        #expect(placements == ["agent-a"])
        #expect(failures.count == 1)
        // The loser fails with a scheduler error (insufficient resources once
        // the winner's reservation is subtracted), not a crash or a hang.
        if case .failure(let error) = failures.first {
            #expect(error is SchedulerError)
        }
    }

    @Test("Selection skips an agent whose capacity is consumed by reservations")
    func selectionHonorsExistingReservations() async throws {
        let scheduler = makeScheduler()
        let coordination = makeCoordination()
        let agents = [agent(id: "agent-a"), agent(id: "agent-b")]

        let first = try await scheduler.selectAndReserveAgent(
            requirements: vmRequirements, vmId: "vm-1", from: agents, coordination: coordination)
        let second = try await scheduler.selectAndReserveAgent(
            requirements: vmRequirements, vmId: "vm-2", from: agents, coordination: coordination)

        // Each agent fits exactly one VM, so the two placements must not stack.
        #expect(Set([first, second]) == Set(["agent-a", "agent-b"]))
    }

    @Test("Placement fails cleanly when reservations exhaust the fleet")
    func placementFailsWhenFleetReserved() async throws {
        let scheduler = makeScheduler()
        let coordination = makeCoordination()
        let agents = [agent(id: "agent-a")]

        _ = try await scheduler.selectAndReserveAgent(
            requirements: vmRequirements, vmId: "vm-1", from: agents, coordination: coordination)

        await #expect(throws: SchedulerError.self) {
            _ = try await scheduler.selectAndReserveAgent(
                requirements: self.vmRequirements, vmId: "vm-2", from: agents, coordination: coordination)
        }
    }

    @Test("Released reservation makes the agent placeable again")
    func releaseRestoresPlacement() async throws {
        let scheduler = makeScheduler()
        let coordination = makeCoordination()
        let agents = [agent(id: "agent-a")]

        let placed = try await scheduler.selectAndReserveAgent(
            requirements: vmRequirements, vmId: "vm-1", from: agents, coordination: coordination)
        await coordination.releaseReservation(agentId: placed, vmId: "vm-1")

        let second = try await scheduler.selectAndReserveAgent(
            requirements: vmRequirements, vmId: "vm-2", from: agents, coordination: coordination)
        #expect(second == "agent-a")
    }
}
