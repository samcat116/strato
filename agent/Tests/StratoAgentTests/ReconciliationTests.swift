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

    /// A desired entry whose spec asks for a specific size (issue #568).
    private static func desiredSized(
        _ vmId: UUID,
        status: DesiredVMStatus = .running,
        generation: Int64 = 1,
        cpus: Int,
        memoryBytes: Int64 = 1 << 30,
        balloonTargetBytes: Int64? = nil
    ) -> DesiredVMState {
        DesiredVMState(
            vmId: vmId,
            hypervisorType: .qemu,
            spec: VMSpec(
                cpus: cpus, maxCpus: 8, memoryBytes: memoryBytes, maxMemoryBytes: 8 << 30,
                balloonTargetBytes: balloonTargetBytes,
                boot: .disk(firmware: nil)),
            desiredStatus: status,
            generation: generation
        )
    }

    private static func sync(
        _ vms: [DesiredVMState],
        tombstones: [DesiredWorkloadTombstone] = []
    ) -> DesiredStateMessage {
        DesiredStateMessage(vms: vms, tombstones: tombstones)
    }

    /// Actuator double that records steps and simulates the hypervisor by
    /// updating its own presence map on each action.
    private actor MockActuator: ReconcileActuator {
        var presence: [String: VMPresence]
        /// False models an agent whose durable manifest could not be read, so
        /// `presence` is empty because the host's contents are unknown
        /// (STR-138).
        var presenceComplete = true
        /// What each managed VM is running with, diffed against the desired
        /// spec to plan resizes (issue #568).
        var sizing: [String: VMSizing] = [:]
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

        func presenceIsComplete() -> Bool {
            presenceComplete
        }

        func setPresenceComplete(_ complete: Bool) {
            presenceComplete = complete
        }

        func observedPresence() -> [String: VMPresence] {
            presence
        }

        func observedSizing() -> [String: VMSizing] {
            sizing
        }

        func setSizing(_ sizing: [String: VMSizing]) {
            self.sizing = sizing
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
            case .resize:
                if let desired = item.desired {
                    sizing[item.vmId] = VMSizing(cpus: desired.spec.cpus, memoryBytes: desired.spec.memoryBytes)
                }
            case .adopt: break
            case .attach, .detach: break  // volume-only steps; never planned for a VM
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
        let plan = Reconciler.plan(
            desired: [Self.desired(vmId, status: .running)],
            present: [:],
            lastApplied: [:]
        )
        #expect(plan.items.count == 1)
        #expect(plan.items[0].vmId == vmId.uuidString)
        #expect(plan.items[0].steps == [.create, .boot])
    }

    @Test("Present-but-unlisted VM is held and reported, never deleted")
    func planHoldsUnlistedVM() {
        // The core of STR-98: a sync that fails to mention a running VM — a
        // restored database, a re-enrolled agent, a scoping bug — is not an
        // instruction to destroy it.
        let vmId = UUID()
        let plan = Reconciler.plan(
            desired: [],
            present: [vmId.uuidString: .managed(.running)],
            lastApplied: [vmId.uuidString: 4]
        )
        #expect(plan.items.isEmpty)
        #expect(plan.unrecognized.count == 1)
        #expect(plan.unrecognized[0].kind == .vm)
        #expect(plan.unrecognized[0].workloadId == vmId)
        #expect(plan.unrecognized[0].observedGeneration == 4)
        #expect(plan.unrecognized[0].status == VMStatus.running.rawValue)
    }

    @Test("An orphaned VM the sync omits is held too, and reports as orphaned")
    func planHoldsUnlistedOrphan() {
        let vmId = UUID()
        let plan = Reconciler.plan(
            desired: [],
            present: [vmId.uuidString: .orphaned],
            lastApplied: [:]
        )
        #expect(plan.items.isEmpty)
        #expect(plan.unrecognized.map(\.status) == ["orphaned"])
        #expect(plan.unrecognized[0].observedGeneration == 0)
    }

    @Test("A tombstone deletes the workload it names, at its own generation")
    func planDeletesTombstonedVM() {
        let vmId = UUID()
        let plan = Reconciler.plan(
            desired: [],
            present: [vmId.uuidString: .managed(.running)],
            lastApplied: [vmId.uuidString: 4],
            tombstones: [DesiredWorkloadTombstone(kind: .vm, workloadId: vmId, generation: 5)]
        )
        #expect(plan.unrecognized.isEmpty)
        #expect(plan.items.count == 1)
        #expect(plan.items[0].vmId == vmId.uuidString)
        #expect(plan.items[0].steps == [.delete])
        #expect(plan.items[0].generation == 5)
        #expect(plan.items[0].isTombstone)
        #expect(plan.items[0].desired == nil)
    }

    @Test("A tombstone older than what the agent applied is dropped as stale")
    func planRejectsStaleTombstone() {
        // A replayed tombstone must not undo a newer sync that re-adopted the
        // workload — the same staleness rule desired entries live under.
        let vmId = UUID()
        let plan = Reconciler.plan(
            desired: [],
            present: [vmId.uuidString: .managed(.running)],
            lastApplied: [vmId.uuidString: 9],
            tombstones: [DesiredWorkloadTombstone(kind: .vm, workloadId: vmId, generation: 4)]
        )
        #expect(plan.items.isEmpty)
        #expect(plan.unrecognized.isEmpty)  // tombstoned, just not at a generation we accept
    }

    @Test("A tombstone for a workload this host doesn't have plans nothing")
    func planIgnoresTombstoneForAbsentWorkload() {
        let plan = Reconciler.plan(
            desired: [],
            present: [:],
            lastApplied: [:],
            tombstones: [DesiredWorkloadTombstone(kind: .vm, workloadId: UUID(), generation: 1)]
        )
        #expect(plan.items.isEmpty)
        #expect(plan.unrecognized.isEmpty)
    }

    @Test("An explicit absent entry still deletes, exactly as before")
    func planDeletesExplicitlyAbsentVM() {
        let vmId = UUID()
        let plan = Reconciler.plan(
            desired: [Self.desired(vmId, status: .absent, generation: 2)],
            present: [vmId.uuidString: .managed(.running)],
            lastApplied: [:]
        )
        #expect(plan.items.count == 1)
        #expect(plan.items[0].steps == [.delete])
        #expect(plan.items[0].isTombstone == false)
        #expect(plan.unrecognized.isEmpty)
    }

    @Test("Satisfied VM at an already-applied generation plans nothing")
    func planIsIdempotentForConvergedState() {
        let vmId = UUID()
        let plan = Reconciler.plan(
            desired: [Self.desired(vmId, status: .running, generation: 3)],
            present: [vmId.uuidString: .managed(.running)],
            lastApplied: [vmId.uuidString: 3]
        )
        #expect(plan.items.isEmpty)
    }

    @Test("Stale generation is rejected by the generation guard")
    func planRejectsStaleGeneration() {
        let vmId = UUID()
        // The agent already applied generation 5; a replayed generation-2 sync
        // asking for a different state must not roll the VM backward.
        let plan = Reconciler.plan(
            desired: [Self.desired(vmId, status: .shutdown, generation: 2)],
            present: [vmId.uuidString: .managed(.running)],
            lastApplied: [vmId.uuidString: 5]
        )
        #expect(plan.items.isEmpty)
    }

    @Test("Equal generation with drifted state re-plans convergence")
    func planCorrectsDriftAtSameGeneration() {
        let vmId = UUID()
        // Same generation as applied, but the VM regressed out of band
        // (e.g. the guest powered itself off): drift correction must act.
        let plan = Reconciler.plan(
            desired: [Self.desired(vmId, status: .running, generation: 3)],
            present: [vmId.uuidString: .managed(.shutdown)],
            lastApplied: [vmId.uuidString: 3]
        )
        #expect(plan.items.count == 1)
        #expect(plan.items[0].steps == [.boot])
    }

    @Test("Orphan matching a desired VM plans re-adoption")
    func planAdoptsMatchingOrphan() {
        let vmId = UUID()
        let plan = Reconciler.plan(
            desired: [Self.desired(vmId, status: .running)],
            present: [vmId.uuidString: .orphaned],
            lastApplied: [:]
        )
        #expect(plan.items.count == 1)
        #expect(plan.items[0].steps == [.adopt])
    }

    @Test("Absent VM desired absent yields an empty-step generation record")
    func planRecordsAlreadyAbsentDeletion() {
        let vmId = UUID()
        let plan = Reconciler.plan(
            desired: [Self.desired(vmId, status: .absent, generation: 4)],
            present: [:],
            lastApplied: [:]
        )
        #expect(plan.items.count == 1)
        #expect(plan.items[0].steps.isEmpty)
        #expect(plan.items[0].generation == 4)
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

    // MARK: - Unknown host contents (STR-138)

    @Test("A sync arriving while the manifest is unreadable converges nothing")
    func unknownPresenceConvergesNothing() async {
        let vmId = UUID()
        // Empty presence because the agent cannot read its own manifest — not
        // because the host is idle. Planning `.create` here would point a
        // second hypervisor process at a disk image the first one still has
        // open.
        let actuator = MockActuator()
        await actuator.setPresenceComplete(false)
        let reconciler = makeReconciler(actuator)

        await reconciler.apply(Self.sync([Self.desired(vmId, status: .running, generation: 3)]))
        try? await Task.sleep(nanoseconds: 100_000_000)

        let performed = await actuator.performed
        #expect(performed.isEmpty)
        // And the generation is not recorded: this agent has not converged the
        // entry and must not claim it has, so a repaired host picks the work up.
        let generation = await reconciler.observedGeneration(for: vmId.uuidString)
        #expect(generation == 0)
    }

    @Test("A tombstone is not honored either while the host's contents are unknown")
    func unknownPresenceIgnoresTombstones() async {
        let vmId = UUID()
        let actuator = MockActuator(presence: [vmId.uuidString: .managed(.running)])
        await actuator.setPresenceComplete(false)
        let reconciler = makeReconciler(actuator)

        let tombstone = DesiredWorkloadTombstone(kind: .vm, workloadId: vmId, generation: 9)
        await reconciler.apply(Self.sync([], tombstones: [tombstone]))
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(await actuator.performed.isEmpty)
        #expect(await reconciler.unrecognizedWorkloads().isEmpty)
    }

    @Test("A quarantined workload is never created, deleted, or adopted")
    func quarantinedWorkloadIsUntouchable() {
        let vmId = UUID()
        // The entry exists — something is running under this id — but this
        // build cannot name the backend that owns it.
        let plan = Reconciler.plan(
            desired: [Self.desired(vmId, status: .running, generation: 7)],
            present: [vmId.uuidString: .quarantined],
            lastApplied: [:]
        )
        #expect(plan.items.isEmpty)

        let deleting = Reconciler.plan(
            desired: [Self.desired(vmId, status: .absent, generation: 7)],
            present: [vmId.uuidString: .quarantined],
            lastApplied: [:]
        )
        #expect(deleting.items.isEmpty)
    }

    @Test("A quarantined workload no sync lists is reported, never torn down")
    func quarantinedWorkloadIsReportedNotTornDown() {
        let vmId = UUID()
        let tombstone = DesiredWorkloadTombstone(kind: .vm, workloadId: vmId, generation: 4)
        let plan = Reconciler.plan(
            desired: [],
            present: [vmId.uuidString: .quarantined],
            lastApplied: [:],
            tombstones: [tombstone]
        )
        // Even an explicit teardown authorization cannot be acted on: there is
        // no backend to ask, which is the whole reason the entry is quarantined.
        #expect(plan.items.isEmpty)
        #expect(plan.unrecognized.map(\.status) == ["quarantined"])
        #expect(plan.unrecognized[0].workloadId == vmId)
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

    @Test("Permanent failures exhaust the attempt cap on the first attempt")
    func permanentFailureStopsRetriesImmediately() async {
        let vmId = UUID()
        let actuator = MockActuator()
        await actuator.setFailure(StorageBackendError.hostMisconfiguration("qemu-img missing"))
        let reconciler = makeReconciler(actuator)
        let message = Self.sync([Self.desired(vmId, status: .running, generation: 1)])

        await reconciler.apply(message)
        _ = await actuator.waitForReports(1)

        // Re-driving the same generation is pointless for a host problem —
        // the convergence must not run again.
        await reconciler.apply(message)
        await reconciler.apply(message)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let reports = await actuator.reportCount
        #expect(reports == 1)
        let lastError = await reconciler.lastError(for: vmId.uuidString)
        #expect(lastError?.contains("qemu-img missing") == true)

        // A new generation (operator retry after fixing the host) re-arms
        // the loop exactly like a capped transient failure.
        await actuator.setFailure(nil)
        await reconciler.apply(Self.sync([Self.desired(vmId, status: .running, generation: 2)]))
        _ = await actuator.waitForReports(2)
        let performed = await actuator.performed
        #expect(performed.map(\.step) == [.create, .boot])
        let clearedError = await reconciler.lastError(for: vmId.uuidString)
        #expect(clearedError == nil)
    }

    @Test("Waiting on a dependency reports no error and retries past the attempt cap")
    func dependencyPendingWaitsWithoutFailing() async {
        let vmId = UUID()
        let actuator = MockActuator()
        // e.g. a VM port on a shared site NB whose switch the site's network
        // controller hasn't realized yet (issue #343).
        await actuator.setFailure(DependencyPendingError("switch not realized yet"))
        let reconciler = makeReconciler(actuator)
        let message = Self.sync([Self.desired(vmId, status: .running, generation: 1)])

        // Every sync keeps re-driving the item, well past the attempt cap...
        let rounds = Reconciler.maxAttemptsPerGeneration + 2
        for attempt in 1...rounds {
            await reconciler.apply(message)
            _ = await actuator.waitForReports(attempt)
        }
        let reports = await actuator.reportCount
        #expect(reports == rounds)
        // ...and none of it is reported as an error — a `lastError` here would
        // fail the pending create operation on the control plane before the
        // controller's topology sync had a chance to land.
        let lastError = await reconciler.lastError(for: vmId.uuidString)
        #expect(lastError == nil)

        // The dependency lands (controller realized the switch): converges.
        await actuator.setFailure(nil)
        await reconciler.apply(message)
        _ = await actuator.waitForReports(rounds + 1)
        let performed = await actuator.performed
        #expect(performed.map(\.step) == [.create, .boot])
        let generation = await reconciler.observedGeneration(for: vmId.uuidString)
        #expect(generation == 1)
    }

    @Test("Tombstoned deletes are exempt from the attempt cap")
    func tombstonedDeleteRetriesPastCap() async {
        struct Boom: Error {}
        let vmId = UUID()
        let actuator = MockActuator(presence: [vmId.uuidString: .managed(.running)])
        await actuator.setFailure(Boom())
        let reconciler = makeReconciler(actuator)

        // A tombstoned workload has no control-plane row, so nothing can ever
        // mint a new generation to re-arm a capped failure — every sync must
        // keep retrying the delete or the stray process leaks until restart.
        let tombstone = DesiredWorkloadTombstone(kind: .vm, workloadId: vmId, generation: 1)
        let rounds = Reconciler.maxAttemptsPerGeneration + 2
        for attempt in 1...rounds {
            await reconciler.apply(Self.sync([], tombstones: [tombstone]))
            _ = await actuator.waitForReports(attempt)
        }
        let reports = await actuator.reportCount
        #expect(reports == rounds)

        // Once the failure clears, the delete converges.
        await actuator.setFailure(nil)
        await reconciler.apply(Self.sync([], tombstones: [tombstone]))
        _ = await actuator.waitForReports(rounds + 1)
        let presence = await actuator.presence
        #expect(presence.isEmpty)
    }

    @Test("A sync that omits a VM holds it and reports it; only a tombstone removes it")
    func unlistedVMHeldThenTombstoned() async {
        let vmId = UUID()
        let actuator = MockActuator(presence: [vmId.uuidString: .managed(.running)])
        let reconciler = makeReconciler(actuator)

        await reconciler.apply(Self.sync([]))
        _ = await actuator.waitForReports(1)

        // Nothing was actuated, the VM is still running, and the control plane
        // has been told about it.
        let performedWhileHeld = await actuator.performed
        #expect(performedWhileHeld.isEmpty)
        let heldPresence = await actuator.presence
        #expect(heldPresence.count == 1)
        let held = await reconciler.unrecognizedWorkloads()
        #expect(held.map(\.workloadId) == [vmId])
        // The hold is reported immediately rather than waiting for the next
        // heartbeat: it is one half of a round trip the control plane can't
        // finish until it has seen it.
        #expect(await actuator.reportCount == 1)

        await reconciler.apply(
            Self.sync(
                [],
                tombstones: [DesiredWorkloadTombstone(kind: .vm, workloadId: vmId, generation: 1)]))
        // Two more reports: the held set emptying, and the delete finishing.
        _ = await actuator.waitForReports(3)

        let performed = await actuator.performed
        #expect(performed.map(\.step) == [.delete])
        let presence = await actuator.presence
        #expect(presence.isEmpty)
        // Gone from the host, so no longer held either.
        let stillHeld = await reconciler.unrecognizedWorkloads()
        #expect(stillHeld.isEmpty)
    }

    // MARK: - Blast-radius guard (STR-98 phase 2)

    @Test("A sync tombstoning the whole host is refused and reported")
    func teardownGuardRefusesWholeHost() async {
        let ids = (0..<5).map { _ in UUID() }
        let actuator = MockActuator(
            presence: Dictionary(uniqueKeysWithValues: ids.map { ($0.uuidString, .managed(.running)) }))
        let reconciler = makeReconciler(actuator)

        let tombstones = ids.map {
            DesiredWorkloadTombstone(kind: .vm, workloadId: $0, generation: 1)
        }
        await reconciler.apply(Self.sync([], tombstones: tombstones))
        _ = await actuator.waitForReports(1)

        let performed = await actuator.performed
        #expect(performed.isEmpty)
        let presence = await actuator.presence
        #expect(presence.count == 5)
        let refusal = await reconciler.lastTeardownRefusal()
        #expect(refusal?.requestedTeardowns == 5)
        #expect(refusal?.presentWorkloads == 5)
    }

    @Test("A small share of the host tears down normally, and clears a prior refusal")
    func teardownGuardAllowsSmallBatch() async {
        let ids = (0..<20).map { _ in UUID() }
        let actuator = MockActuator(
            presence: Dictionary(uniqueKeysWithValues: ids.map { ($0.uuidString, .managed(.running)) }))
        let reconciler = makeReconciler(actuator)

        // Refuse first, so the next sync has a refusal to clear.
        await reconciler.apply(
            Self.sync(
                [],
                tombstones: ids.map { DesiredWorkloadTombstone(kind: .vm, workloadId: $0, generation: 1) }))
        _ = await actuator.waitForReports(1)
        #expect(await reconciler.lastTeardownRefusal() != nil)

        await reconciler.apply(
            Self.sync(
                [],
                tombstones: [DesiredWorkloadTombstone(kind: .vm, workloadId: ids[0], generation: 1)]))
        // The refusal clearing reports, and so does the delete finishing.
        _ = await actuator.waitForReports(3)

        let performed = await actuator.performed
        #expect(performed.map(\.step) == [.delete])
        let presence = await actuator.presence
        #expect(presence.count == 19)
        #expect(await reconciler.lastTeardownRefusal() == nil)
    }

    @Test("A refused sync still converges everything that isn't a teardown")
    func teardownGuardDoesNotBlockOtherWork() async {
        let ids = (0..<5).map { _ in UUID() }
        let bootId = UUID()
        var presence = Dictionary(
            uniqueKeysWithValues: ids.map { ($0.uuidString, VMPresence.managed(.running)) })
        presence[bootId.uuidString] = .managed(.shutdown)
        let actuator = MockActuator(presence: presence)
        let reconciler = makeReconciler(actuator)

        await reconciler.apply(
            Self.sync(
                [Self.desired(bootId, status: .running, generation: 1)],
                tombstones: ids.map { DesiredWorkloadTombstone(kind: .vm, workloadId: $0, generation: 1) }))
        // One report for the refusal, one for the boot that still ran.
        _ = await actuator.waitForReports(2)

        let performed = await actuator.performed
        #expect(performed.map(\.step) == [.boot])
        #expect(await reconciler.lastTeardownRefusal() != nil)
    }

    @Test("The operator override converges a full-host teardown")
    func teardownGuardOverride() async {
        let ids = (0..<5).map { _ in UUID() }
        let actuator = MockActuator(
            presence: Dictionary(uniqueKeysWithValues: ids.map { ($0.uuidString, .managed(.running)) }))
        let reconciler = Reconciler(
            actuator: actuator, queue: SerialTaskQueue(), logger: Logger(label: "test"),
            teardownGuard: TeardownGuard(allowBulkTeardown: true))

        await reconciler.apply(
            Self.sync(
                [],
                tombstones: ids.map { DesiredWorkloadTombstone(kind: .vm, workloadId: $0, generation: 1) }))
        _ = await actuator.waitForReports(5)

        let presence = await actuator.presence
        #expect(presence.isEmpty)
        #expect(await reconciler.lastTeardownRefusal() == nil)
    }

    @Test("The guard needs both halves: three teardowns on a three-VM host proceed")
    func teardownGuardHonorsTheAbsoluteFloor() async {
        let ids = (0..<3).map { _ in UUID() }
        let actuator = MockActuator(
            presence: Dictionary(uniqueKeysWithValues: ids.map { ($0.uuidString, .managed(.running)) }))
        let reconciler = makeReconciler(actuator)

        await reconciler.apply(
            Self.sync(
                [],
                tombstones: ids.map { DesiredWorkloadTombstone(kind: .vm, workloadId: $0, generation: 1) }))
        _ = await actuator.waitForReports(3)

        let presence = await actuator.presence
        #expect(presence.isEmpty)
        #expect(await reconciler.lastTeardownRefusal() == nil)
    }

    // MARK: - Online resize (issue #568)

    @Test("Running VM whose desired spec grew plans a resize")
    func planResizesGrownRunningVM() {
        let vmId = UUID()
        let plan = Reconciler.plan(
            desired: [Self.desiredSized(vmId, generation: 2, cpus: 6)],
            present: [vmId.uuidString: .managed(.running)],
            lastApplied: [vmId.uuidString: 1],
            presentSizing: [vmId.uuidString: VMSizing(cpus: 2, memoryBytes: 1 << 30)]
        )
        #expect(plan.items.count == 1)
        #expect(plan.items[0].steps == [.resize])
        #expect(plan.items[0].generation == 2)
    }

    @Test("Memory-only change on a running VM plans a resize")
    func planResizesMemoryChange() {
        let vmId = UUID()
        let plan = Reconciler.plan(
            desired: [Self.desiredSized(vmId, generation: 2, cpus: 2, memoryBytes: 4 << 30)],
            present: [vmId.uuidString: .managed(.running)],
            lastApplied: [vmId.uuidString: 1],
            presentSizing: [vmId.uuidString: VMSizing(cpus: 2, memoryBytes: 1 << 30)]
        )
        #expect(plan.items.map(\.steps) == [[.resize]])
    }

    @Test("Matching sizing on a converged VM plans nothing")
    func planSkipsResizeWhenSizeMatches() {
        let vmId = UUID()
        let plan = Reconciler.plan(
            desired: [Self.desiredSized(vmId, generation: 2, cpus: 2)],
            present: [vmId.uuidString: .managed(.running)],
            lastApplied: [vmId.uuidString: 2],
            presentSizing: [vmId.uuidString: VMSizing(cpus: 2, memoryBytes: 1 << 30)]
        )
        #expect(plan.items.isEmpty)
    }

    // MARK: - Balloon targets (issue #567 phase 2)

    @Test("Setting a balloon target on a running VM plans a resize")
    func planResizesForNewBalloonTarget() {
        let vmId = UUID()
        let plan = Reconciler.plan(
            desired: [Self.desiredSized(vmId, generation: 2, cpus: 2, balloonTargetBytes: 512 << 20)],
            present: [vmId.uuidString: .managed(.running)],
            lastApplied: [vmId.uuidString: 1],
            presentSizing: [vmId.uuidString: VMSizing(cpus: 2, memoryBytes: 1 << 30)]
        )
        #expect(plan.items.map(\.steps) == [[.resize]])
    }

    /// Clearing a target is a real convergence step — the balloon has to
    /// deflate — not the same as never having had one.
    @Test("Clearing a balloon target on a running VM plans a resize")
    func planResizesWhenBalloonTargetCleared() {
        let vmId = UUID()
        let plan = Reconciler.plan(
            desired: [Self.desiredSized(vmId, generation: 2, cpus: 2)],
            present: [vmId.uuidString: .managed(.running)],
            lastApplied: [vmId.uuidString: 1],
            presentSizing: [
                vmId.uuidString: VMSizing(cpus: 2, memoryBytes: 1 << 30, balloonTargetBytes: 512 << 20)
            ]
        )
        #expect(plan.items.map(\.steps) == [[.resize]])
    }

    @Test("A balloon target already applied plans nothing")
    func planSkipsResizeWhenBalloonTargetMatches() {
        let vmId = UUID()
        let plan = Reconciler.plan(
            desired: [Self.desiredSized(vmId, generation: 2, cpus: 2, balloonTargetBytes: 512 << 20)],
            present: [vmId.uuidString: .managed(.running)],
            lastApplied: [vmId.uuidString: 2],
            presentSizing: [
                vmId.uuidString: VMSizing(cpus: 2, memoryBytes: 1 << 30, balloonTargetBytes: 512 << 20)
            ]
        )
        #expect(plan.items.isEmpty)
    }

    @Test("A stopped VM boots into the new size instead of resizing")
    func planBootsRatherThanResizesStoppedVM() {
        let vmId = UUID()
        let plan = Reconciler.plan(
            desired: [Self.desiredSized(vmId, generation: 2, cpus: 6)],
            present: [vmId.uuidString: .managed(.shutdown)],
            lastApplied: [vmId.uuidString: 1],
            presentSizing: [vmId.uuidString: VMSizing(cpus: 2, memoryBytes: 1 << 30)]
        )
        #expect(plan.items.map(\.steps) == [[.boot]])
    }

    @Test("A stale resize sync is dropped")
    func planDropsStaleResize() {
        let vmId = UUID()
        let plan = Reconciler.plan(
            desired: [Self.desiredSized(vmId, generation: 1, cpus: 6)],
            present: [vmId.uuidString: .managed(.running)],
            lastApplied: [vmId.uuidString: 4],
            presentSizing: [vmId.uuidString: VMSizing(cpus: 2, memoryBytes: 1 << 30)]
        )
        #expect(plan.items.isEmpty)
    }

    @Test("Applying a resize sync drives the step and advances the generation")
    func resizeConverges() async {
        let vmId = UUID()
        let key = vmId.uuidString
        let actuator = MockActuator(presence: [key: .managed(.running)])
        await actuator.setSizing([key: VMSizing(cpus: 2, memoryBytes: 1 << 30)])
        let reconciler = makeReconciler(actuator)

        await reconciler.apply(Self.sync([Self.desiredSized(vmId, generation: 2, cpus: 6)]))
        _ = await actuator.waitForReports(1)

        let performed = await actuator.performed
        #expect(performed.map(\.step) == [.resize])
        let applied = await reconciler.observedGeneration(for: key)
        #expect(applied == 2)

        // Re-applying the same sync is a no-op now that the VM runs the size
        // the spec asks for.
        await reconciler.apply(Self.sync([Self.desiredSized(vmId, generation: 2, cpus: 6)]))
        let stillOnce = await actuator.performed
        #expect(stillOnce.count == 1)
    }
}
