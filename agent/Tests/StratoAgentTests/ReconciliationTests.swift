import Testing
import Foundation
@testable import StratoAgentCore
import StratoShared
import Logging

@Suite("Reconciliation Tests")
struct ReconciliationTests {

    // MARK: - Fixtures

    private static func spec(cpus: Int = 1) -> VMSpec {
        VMSpec(cpus: cpus, memoryBytes: 1 << 30, boot: .disk(firmware: nil))
    }

    private static func desired(
        _ vmId: UUID,
        status: DesiredVMStatus,
        generation: Int64 = 1
    ) -> DesiredVMState {
        DesiredVMState(
            vmId: vmId,
            hypervisorType: .qemu,
            spec: spec(),
            desiredStatus: status,
            generation: generation
        )
    }

    private static func sync(_ vms: [DesiredVMState]) -> DesiredStateMessage {
        DesiredStateMessage(vms: vms)
    }

    /// Actuator double that records steps and simulates the hypervisor by
    /// updating its own presence map on each action.
    private actor MockActuator: ReconcileActuator {
        var presence: [String: VMPresence]
        private(set) var performed: [(step: ReconcileStep, vmId: String)] = []
        private(set) var reportCount = 0
        /// Status an adopted orphan turns out to have.
        var adoptedStatus: VMStatus = .running
        /// When set, every action throws this error.
        var failWith: (any Error)?

        init(presence: [String: VMPresence] = [:]) {
            self.presence = presence
        }

        func setFailure(_ error: (any Error)?) {
            failWith = error
        }

        func setAdoptedStatus(_ status: VMStatus) {
            adoptedStatus = status
        }

        func observedPresence() -> [String: VMPresence] {
            presence
        }

        func adoptVM(_ item: ReconcileWorkItem) throws -> VMStatus {
            if let failWith { throw failWith }
            performed.append((.adopt, item.vmId))
            presence[item.vmId] = .managed(adoptedStatus)
            return adoptedStatus
        }

        func perform(_ step: ReconcileStep, item: ReconcileWorkItem) throws {
            if let failWith { throw failWith }
            performed.append((step, item.vmId))
            switch step {
            case .create: presence[item.vmId] = .managed(.created)
            case .boot, .resume: presence[item.vmId] = .managed(.running)
            case .pause: presence[item.vmId] = .managed(.paused)
            case .shutdown: presence[item.vmId] = .managed(.shutdown)
            case .delete: presence.removeValue(forKey: item.vmId)
            case .adopt: break
            }
        }

        func convergenceDidChange() {
            reportCount += 1
        }

        /// Wait until `reportCount` reaches `count` (one report per finished
        /// work item), or time out.
        func waitForReports(_ count: Int, timeoutMillis: Int = 5000) async -> Int {
            var waited = 0
            while reportCount < count && waited < timeoutMillis {
                try? await Task.sleep(nanoseconds: 5_000_000)
                waited += 5
            }
            return reportCount
        }
    }

    private func makeReconciler(_ actuator: MockActuator) -> Reconciler {
        Reconciler(actuator: actuator, queue: SerialTaskQueue(), logger: Logger(label: "test"))
    }

    // MARK: - Pure diff engine

    @Test("Desired-but-absent VM plans create plus boot steps")
    func planCreatesAbsentVM() {
        let vmId = UUID()
        let items = Reconciler.plan(
            desired: [Self.desired(vmId, status: .running)],
            present: [:],
            lastApplied: [:]
        )
        #expect(items.count == 1)
        #expect(items[0].vmId == vmId.uuidString)
        #expect(items[0].steps == [.create, .boot])
    }

    @Test("Present-but-undesired VM plans deletion (full-list semantics)")
    func planDeletesUndesiredVM() {
        let vmId = UUID().uuidString
        let items = Reconciler.plan(
            desired: [],
            present: [vmId: .managed(.running)],
            lastApplied: [:]
        )
        #expect(items.count == 1)
        #expect(items[0].vmId == vmId)
        #expect(items[0].steps == [.delete])
        #expect(items[0].desired == nil)
    }

    @Test("Satisfied VM at an already-applied generation plans nothing")
    func planIsIdempotentForConvergedState() {
        let vmId = UUID()
        let items = Reconciler.plan(
            desired: [Self.desired(vmId, status: .running, generation: 3)],
            present: [vmId.uuidString: .managed(.running)],
            lastApplied: [vmId.uuidString: 3]
        )
        #expect(items.isEmpty)
    }

    @Test("Stale generation is rejected by the generation guard")
    func planRejectsStaleGeneration() {
        let vmId = UUID()
        // The agent already applied generation 5; a replayed generation-2 sync
        // asking for a different state must not roll the VM backward.
        let items = Reconciler.plan(
            desired: [Self.desired(vmId, status: .shutdown, generation: 2)],
            present: [vmId.uuidString: .managed(.running)],
            lastApplied: [vmId.uuidString: 5]
        )
        #expect(items.isEmpty)
    }

    @Test("Equal generation with drifted state re-plans convergence")
    func planCorrectsDriftAtSameGeneration() {
        let vmId = UUID()
        // Same generation as applied, but the VM regressed out of band
        // (e.g. the guest powered itself off): drift correction must act.
        let items = Reconciler.plan(
            desired: [Self.desired(vmId, status: .running, generation: 3)],
            present: [vmId.uuidString: .managed(.shutdown)],
            lastApplied: [vmId.uuidString: 3]
        )
        #expect(items.count == 1)
        #expect(items[0].steps == [.boot])
    }

    @Test("Orphan matching a desired VM plans re-adoption")
    func planAdoptsMatchingOrphan() {
        let vmId = UUID()
        let items = Reconciler.plan(
            desired: [Self.desired(vmId, status: .running)],
            present: [vmId.uuidString: .orphaned],
            lastApplied: [:]
        )
        #expect(items.count == 1)
        #expect(items[0].steps == [.adopt])
    }

    @Test("Absent VM desired absent yields an empty-step generation record")
    func planRecordsAlreadyAbsentDeletion() {
        let vmId = UUID()
        let items = Reconciler.plan(
            desired: [Self.desired(vmId, status: .absent, generation: 4)],
            present: [:],
            lastApplied: [:]
        )
        #expect(items.count == 1)
        #expect(items[0].steps.isEmpty)
        #expect(items[0].generation == 4)
    }

    @Test("Status mismatch maps to the right convergence steps")
    func statusStepMappings() {
        #expect(Reconciler.statusSteps(desired: .running, observed: .paused) == [.resume])
        #expect(Reconciler.statusSteps(desired: .running, observed: .shutdown) == [.boot])
        #expect(Reconciler.statusSteps(desired: .running, observed: .created) == [.boot])
        #expect(Reconciler.statusSteps(desired: .running, observed: .running) == [])
        #expect(Reconciler.statusSteps(desired: .paused, observed: .running) == [.pause])
        #expect(Reconciler.statusSteps(desired: .paused, observed: .shutdown) == [.boot, .pause])
        #expect(Reconciler.statusSteps(desired: .shutdown, observed: .running) == [.shutdown])
        #expect(Reconciler.statusSteps(desired: .shutdown, observed: .created) == [])
        #expect(Reconciler.statusSteps(desired: .shutdown, observed: .paused) == [.shutdown])
    }

    // MARK: - Reconciler end to end

    @Test("Duplicate sync is a no-op: identical syncs diff to nothing")
    func duplicateSyncIsNoOp() async {
        let vmId = UUID()
        let actuator = MockActuator()
        let reconciler = makeReconciler(actuator)
        let message = Self.sync([Self.desired(vmId, status: .running, generation: 1)])

        await reconciler.apply(message)
        _ = await actuator.waitForReports(1)
        let afterFirst = await actuator.performed
        #expect(afterFirst.map(\.step) == [.create, .boot])

        // Replaying the identical sync N times must change nothing.
        for _ in 0..<3 {
            await reconciler.apply(message)
        }
        // Allow any (wrong) work to surface before asserting.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let afterReplays = await actuator.performed
        #expect(afterReplays.map(\.step) == [.create, .boot])
        let generation = await reconciler.observedGeneration(for: vmId.uuidString)
        #expect(generation == 1)
    }

    @Test("Stale sync arriving after a newer one cannot roll state backward")
    func staleSyncIgnoredAfterNewerApplied() async {
        let vmId = UUID()
        let actuator = MockActuator(presence: [vmId.uuidString: .managed(.running)])
        let reconciler = makeReconciler(actuator)

        // Generation 5 asks for shutdown; converge it.
        await reconciler.apply(Self.sync([Self.desired(vmId, status: .shutdown, generation: 5)]))
        _ = await actuator.waitForReports(1)
        let converged = await actuator.performed
        #expect(converged.map(\.step) == [.shutdown])

        // A reordered/replayed older sync still wants the VM running. It must
        // be rejected outright.
        await reconciler.apply(Self.sync([Self.desired(vmId, status: .running, generation: 2)]))
        try? await Task.sleep(nanoseconds: 100_000_000)
        let after = await actuator.performed
        #expect(after.map(\.step) == [.shutdown])
        let generation = await reconciler.observedGeneration(for: vmId.uuidString)
        #expect(generation == 5)
    }

    @Test("Orphan is re-adopted and then converged toward the desired status")
    func orphanReadoptedAndConverged() async {
        let vmId = UUID()
        let actuator = MockActuator(presence: [vmId.uuidString: .orphaned])
        await actuator.setAdoptedStatus(.shutdown)
        let reconciler = makeReconciler(actuator)

        await reconciler.apply(Self.sync([Self.desired(vmId, status: .running, generation: 1)]))
        _ = await actuator.waitForReports(1)

        // Adoption first, then the post-adoption plan (shutdown → running = boot).
        let performed = await actuator.performed
        #expect(performed.map(\.step) == [.adopt, .boot])
        let generation = await reconciler.observedGeneration(for: vmId.uuidString)
        #expect(generation == 1)
    }

    @Test("Failing convergence stops retrying after the per-generation attempt cap")
    func failureAttemptCap() async {
        struct Boom: Error {}
        let vmId = UUID()
        let actuator = MockActuator()
        await actuator.setFailure(Boom())
        let reconciler = makeReconciler(actuator)
        let message = Self.sync([Self.desired(vmId, status: .running, generation: 1)])

        // Each sync re-drives one attempt until the cap; further syncs are skipped.
        for attempt in 1...(Reconciler.maxAttemptsPerGeneration + 3) {
            await reconciler.apply(message)
            _ = await actuator.waitForReports(min(attempt, Reconciler.maxAttemptsPerGeneration))
        }
        try? await Task.sleep(nanoseconds: 100_000_000)

        let reports = await actuator.reportCount
        #expect(reports == Reconciler.maxAttemptsPerGeneration)
        let lastError = await reconciler.lastError(for: vmId.uuidString)
        #expect(lastError != nil)

        // A new generation re-arms the loop.
        await actuator.setFailure(nil)
        await reconciler.apply(Self.sync([Self.desired(vmId, status: .running, generation: 2)]))
        _ = await actuator.waitForReports(Reconciler.maxAttemptsPerGeneration + 1)
        let performed = await actuator.performed
        #expect(performed.map(\.step) == [.create, .boot])
        let clearedError = await reconciler.lastError(for: vmId.uuidString)
        #expect(clearedError == nil)
    }

    @Test("Deletion of an undesired VM removes it and reports")
    func undesiredVMDeleted() async {
        let vmId = UUID().uuidString
        let actuator = MockActuator(presence: [vmId: .managed(.running)])
        let reconciler = makeReconciler(actuator)

        await reconciler.apply(Self.sync([]))
        _ = await actuator.waitForReports(1)

        let performed = await actuator.performed
        #expect(performed.map(\.step) == [.delete])
        let presence = await actuator.presence
        #expect(presence.isEmpty)
    }
}
