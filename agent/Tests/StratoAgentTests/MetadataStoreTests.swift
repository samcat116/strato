import Foundation
import Logging
import StratoShared
import Testing

@testable import StratoAgentCore

@Suite("Metadata Store Tests")
struct MetadataStoreTests {

    // MARK: - Fixtures

    private static func metadata(_ vmId: UUID, hostname: String, projectId: UUID = UUID()) -> InstanceMetadata {
        InstanceMetadata(instanceId: vmId, hostname: hostname, projectId: projectId)
    }

    private static func spec() -> VMSpec {
        VMSpec(cpus: 1, memoryBytes: 1 << 30, boot: .disk(firmware: nil))
    }

    private static func desired(
        _ vmId: UUID,
        status: DesiredVMStatus = .running,
        generation: Int64 = 1,
        metadata: InstanceMetadata?
    ) -> DesiredVMState {
        DesiredVMState(
            vmId: vmId, hypervisorType: .qemu, spec: spec(), desiredStatus: status,
            generation: generation, metadata: metadata)
    }

    /// Minimal actuator: enough presence bookkeeping to plan and run VM
    /// steps, since what these tests assert on is the metadata store rather
    /// than the runtime.
    private actor MockActuator: ReconcileActuator {
        var presence: [String: VMPresence]
        private(set) var reportCount = 0
        var failWith: (any Error)?

        init(presence: [String: VMPresence] = [:]) {
            self.presence = presence
        }

        func setFailure(_ error: (any Error)?) {
            failWith = error
        }

        func observedPresence() -> [String: VMPresence] { presence }

        func adoptVM(_ item: ReconcileWorkItem) throws -> VMStatus {
            presence[item.vmId] = .managed(.running)
            return .running
        }

        func perform(_ step: ReconcileStep, item: ReconcileWorkItem) throws {
            if let failWith { throw failWith }
            switch step {
            case .create: presence[item.vmId] = .managed(.created)
            case .boot, .resume: presence[item.vmId] = .managed(.running)
            case .pause: presence[item.vmId] = .managed(.paused)
            case .shutdown: presence[item.vmId] = .managed(.shutdown)
            case .delete: presence.removeValue(forKey: item.vmId)
            case .adopt, .resize, .attach, .detach: break
            }
        }

        func convergenceDidChange() { reportCount += 1 }

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

    private func makeReconciler(
        _ actuator: MockActuator, store: MetadataStore, teardownGuard: TeardownGuard = TeardownGuard()
    ) -> Reconciler {
        Reconciler(
            actuator: actuator, queue: SerialTaskQueue(), logger: Logger(label: "test"),
            teardownGuard: teardownGuard, metadataStore: store)
    }

    // MARK: - The store itself

    @Test("A written record is what the metadata service serves")
    func servesWhatWasWritten() async {
        let store = MetadataStore()
        let vmId = UUID()
        #expect(await store.metadata(for: vmId) == nil)
        #expect(await store.appliedGeneration(for: vmId) == nil)

        await store.apply(Self.metadata(vmId, hostname: "web-1"), generation: 3, for: vmId)

        #expect(await store.metadata(for: vmId)?.hostname == "web-1")
        #expect(await store.appliedGeneration(for: vmId) == 3)
        #expect(await store.snapshot().keys.sorted(by: { $0.uuidString < $1.uuidString }) == [vmId])
    }

    @Test("A strictly older write is refused; metadata never rolls backward")
    func refusesOlderGeneration() async {
        let store = MetadataStore()
        let vmId = UUID()
        await store.apply(Self.metadata(vmId, hostname: "new"), generation: 7, for: vmId)

        let outcome = await store.apply(Self.metadata(vmId, hostname: "old"), generation: 6, for: vmId)

        // The refusal names the standing generation, so the reconciler can log
        // which two disagreed instead of swallowing the write.
        #expect(outcome == .stale(recorded: 7))
        #expect(await store.metadata(for: vmId)?.hostname == "new")
        #expect(await store.appliedGeneration(for: vmId) == 7)
    }

    @Test("An equal generation still applies, so a metadata-only edit reaches the guest")
    func appliesEqualGeneration() async {
        // Load-bearing rather than merely consistent with the reconciler's
        // drift-correction reading: editing a hostname or an SSH key changes
        // nothing about how the VM is realized, so the control plane bumps no
        // generation for it. A strict `>` would freeze the edit out forever.
        let store = MetadataStore()
        let vmId = UUID()
        await store.apply(Self.metadata(vmId, hostname: "before"), generation: 4, for: vmId)

        let outcome = await store.apply(Self.metadata(vmId, hostname: "after"), generation: 4, for: vmId)

        #expect(outcome == .applied)
        #expect(await store.metadata(for: vmId)?.hostname == "after")
    }

    @Test("A withdrawal seals its generation, so no replay of that sync resurrects the metadata")
    func withdrawalIsStickyAgainstReplay() async {
        // Both withdrawal reasons seal. The store's premise is that one
        // generation can carry different content — that is why `==` applies —
        // so a same-generation replay is indistinguishable from an edit, and
        // for a VM that is leaving the host the replay is the likelier one.
        for reason in [MetadataWithdrawal.desiredAbsent, .tornDown] {
            let store = MetadataStore()
            let vmId = UUID()
            await store.apply(Self.metadata(vmId, hostname: "gone"), generation: 6, for: vmId)

            await store.withdraw(vmId, generation: 6, because: reason)
            let replayed = await store.apply(Self.metadata(vmId, hostname: "gone"), generation: 6, for: vmId)

            #expect(replayed == .stale(recorded: 6))
            #expect(await store.metadata(for: vmId) == nil)
            // The record survives so the guard has something to compare
            // against; only the payload is gone.
            #expect(await store.appliedGeneration(for: vmId) == 6)
            #expect(await store.snapshot().isEmpty)
        }
    }

    @Test("A control plane's own nil is reversible; only a withdrawal seals")
    func authoritativeNilStaysReversible() async {
        // "Nothing to serve right now" is a claim the next sync may correct,
        // and it need not bump a generation to do so — the same reason an equal
        // generation applies at all. Sealing it would freeze a VM out of its
        // own metadata for a reason the control plane never intended.
        let store = MetadataStore()
        let vmId = UUID()
        await store.apply(nil, generation: 5, for: vmId)

        let outcome = await store.apply(Self.metadata(vmId, hostname: "web-1"), generation: 5, for: vmId)

        #expect(outcome == .applied)
        #expect(await store.metadata(for: vmId)?.hostname == "web-1")
    }

    @Test("Re-withdrawing at the same generation is a no-op, not a disagreement")
    func repeatedWithdrawalIsNotStale() async {
        // An absent VM is re-listed on every sync until it is gone, so this is
        // the steady state rather than an edge case: reporting it stale would
        // log a refusal per sync per departing VM.
        let store = MetadataStore()
        let vmId = UUID()
        await store.apply(Self.metadata(vmId, hostname: "web-1"), generation: 3, for: vmId)
        await store.withdraw(vmId, generation: 4, because: .desiredAbsent)

        #expect(await store.withdraw(vmId, generation: 4, because: .desiredAbsent) == .applied)
        #expect(await store.metadata(for: vmId) == nil)
        // An older replay of "this VM should be gone" is still refused, since
        // that one *is* a claim a newer sync may have overtaken.
        #expect(await store.withdraw(vmId, generation: 2, because: .desiredAbsent) == .stale(recorded: 4))
    }

    @Test("A VM that left the host stops being served even from behind its recorded generation")
    func withdrawalIgnoresGeneration() async {
        // A teardown is authorized from the *observed* generation the agent
        // reported, which lags the sync generations this store records whenever
        // convergence is failing — so the withdrawal cannot be generation
        // guarded without leaving a deleted VM servable.
        let store = MetadataStore()
        let vmId = UUID()
        await store.apply(Self.metadata(vmId, hostname: "web-1"), generation: 9, for: vmId)

        await store.withdraw(vmId, generation: 4, because: .tornDown)

        #expect(await store.metadata(for: vmId) == nil)
        // The high-water mark stands, and the teardown is remembered, so
        // neither an older replay nor the very sync that last listed the VM can
        // resurrect it.
        #expect(await store.appliedGeneration(for: vmId) == 9)
        #expect(
            await store.apply(Self.metadata(vmId, hostname: "web-1"), generation: 9, for: vmId) == .stale(recorded: 9))
        #expect(await store.metadata(for: vmId) == nil)
        // A strictly newer sync still wins: level-triggering has to stay able
        // to correct even this.
        #expect(await store.apply(Self.metadata(vmId, hostname: "web-1"), generation: 10, for: vmId) == .applied)
        #expect(await store.metadata(for: vmId)?.hostname == "web-1")
    }

    @Test("An absent withdrawal from a stale sync cannot undo a newer one")
    func absentWithdrawalIsGenerationGuarded() async {
        // Unlike a teardown, `.absent` is a claim from a sync rather than a
        // fact about the host, so a replayed old "this VM should be gone" must
        // not blind a VM a newer sync says is running.
        let store = MetadataStore()
        let vmId = UUID()
        await store.apply(Self.metadata(vmId, hostname: "web-1"), generation: 8, for: vmId)

        let outcome = await store.withdraw(vmId, generation: 7, because: .desiredAbsent)

        #expect(outcome == .stale(recorded: 8))
        #expect(await store.metadata(for: vmId)?.hostname == "web-1")
    }

    // MARK: - Fed by the reconciler

    @Test("A sync populates the store for every VM it carries")
    func syncPopulatesStore() async {
        let store = MetadataStore()
        let actuator = MockActuator()
        let reconciler = makeReconciler(actuator, store: store)
        let first = UUID()
        let second = UUID()

        await reconciler.apply(
            DesiredStateMessage(vms: [
                Self.desired(first, metadata: Self.metadata(first, hostname: "web-1")),
                Self.desired(second, metadata: Self.metadata(second, hostname: "web-2")),
            ]),
            includeMetadata: true)

        #expect(await store.metadata(for: first)?.hostname == "web-1")
        #expect(await store.metadata(for: second)?.hostname == "web-2")
        _ = await actuator.waitForReports(2)
    }

    @Test("A nil payload from a control plane that speaks the field withdraws what we serve")
    func nilFromNewControlPlaneIsAuthoritative() async {
        let store = MetadataStore()
        let reconciler = makeReconciler(MockActuator(), store: store)
        let vmId = UUID()
        await store.apply(Self.metadata(vmId, hostname: "stale"), generation: 1, for: vmId)

        await reconciler.apply(
            DesiredStateMessage(vms: [Self.desired(vmId, generation: 2, metadata: nil)]),
            includeMetadata: true)

        #expect(await store.metadata(for: vmId) == nil)
    }

    @Test("A control plane that predates the field leaves the store alone")
    func silenceFromOldControlPlaneChangesNothing() async {
        // The rollback case: a pre-v26 control plane sends no metadata at all,
        // and reading that as authoritative would blind every guest on the host.
        let store = MetadataStore()
        let reconciler = makeReconciler(MockActuator(), store: store)
        let vmId = UUID()
        await store.apply(Self.metadata(vmId, hostname: "web-1"), generation: 1, for: vmId)

        await reconciler.apply(
            DesiredStateMessage(vms: [Self.desired(vmId, generation: 2, metadata: nil)]),
            includeMetadata: false)

        #expect(await store.metadata(for: vmId)?.hostname == "web-1")
        #expect(await store.appliedGeneration(for: vmId) == 1)
    }

    @Test("A replayed older sync does not roll the served metadata back")
    func replayedSyncDoesNotRollBack() async {
        // The actuator fails every step, so `lastApplied` never advances and
        // the planner's own staleness rule offers no cover: what refuses the
        // replay here is the store's generation guard.
        let store = MetadataStore()
        let actuator = MockActuator()
        await actuator.setFailure(HypervisorServiceError.diskError("boom"))
        let reconciler = makeReconciler(actuator, store: store)
        let vmId = UUID()

        await reconciler.apply(
            DesiredStateMessage(vms: [Self.desired(vmId, generation: 5, metadata: Self.metadata(vmId, hostname: "old"))]
            ), includeMetadata: true)
        await reconciler.apply(
            DesiredStateMessage(vms: [Self.desired(vmId, generation: 6, metadata: Self.metadata(vmId, hostname: "new"))]
            ), includeMetadata: true)
        await reconciler.apply(
            DesiredStateMessage(vms: [Self.desired(vmId, generation: 5, metadata: Self.metadata(vmId, hostname: "old"))]
            ), includeMetadata: true)

        #expect(await store.metadata(for: vmId)?.hostname == "new")
        #expect(await reconciler.observedGeneration(for: vmId.uuidString) == 0)
    }

    @Test("An absent entry withdraws the metadata, whatever the sender's version")
    func absentEntryWithdrawsMetadata() async {
        // `desiredStatus` is a field every control plane sends, and having
        // nothing to serve is the safe state for a VM leaving this host: the
        // IMDS identifies its caller by source address, and an address outlives
        // the VM it was allocated to.
        let store = MetadataStore()
        let reconciler = makeReconciler(MockActuator(), store: store)
        let vmId = UUID()
        await store.apply(Self.metadata(vmId, hostname: "web-1"), generation: 1, for: vmId)

        await reconciler.apply(
            DesiredStateMessage(vms: [
                Self.desired(vmId, status: .absent, generation: 2, metadata: Self.metadata(vmId, hostname: "web-1"))
            ]),
            includeMetadata: false)

        #expect(await store.metadata(for: vmId) == nil)
        #expect(await store.appliedGeneration(for: vmId) == 2)
    }

    @Test("A replay of the sync that preceded an absent entry cannot serve the VM again")
    func absentWithdrawalSurvivesReplay() async {
        // The absent path seals like a teardown does. Unreachable in today's
        // control plane — flipping to `.absent` bumps the generation, so no one
        // generation says both things — but the store's premise is that a
        // generation *can* carry different content, and that is the reasoning
        // this file otherwise declines to lean on.
        let store = MetadataStore()
        let reconciler = makeReconciler(MockActuator(), store: store)
        let vmId = UUID()

        await reconciler.apply(
            DesiredStateMessage(vms: [
                Self.desired(vmId, status: .absent, generation: 4, metadata: Self.metadata(vmId, hostname: "web-1"))
            ]),
            includeMetadata: true)
        await reconciler.apply(
            DesiredStateMessage(vms: [
                Self.desired(vmId, generation: 4, metadata: Self.metadata(vmId, hostname: "web-1"))
            ]),
            includeMetadata: true)

        #expect(await store.metadata(for: vmId) == nil)
    }

    @Test("A delete that keeps failing leaves the VM running with its metadata already withdrawn")
    func stuckDeleteHasAlreadyWithdrawnMetadata() async {
        // Documenting the consequence of withdrawing at sync time rather than
        // at convergence: the `.absent` withdrawal leads the VM off the host,
        // because it must also cover a VM already gone (which plans no work
        // item to hook). The trade is deliberate — the other end serves a
        // released VM's keys and user data to whoever next holds its address.
        let store = MetadataStore()
        let vmId = UUID()
        let actuator = MockActuator(presence: [vmId.uuidString: .managed(.running)])
        await actuator.setFailure(HypervisorServiceError.diskError("delete failed"))
        let reconciler = makeReconciler(actuator, store: store)
        await store.apply(Self.metadata(vmId, hostname: "web-1"), generation: 1, for: vmId)

        await reconciler.apply(
            DesiredStateMessage(vms: [
                Self.desired(vmId, status: .absent, generation: 2, metadata: Self.metadata(vmId, hostname: "web-1"))
            ]),
            includeMetadata: true)
        _ = await actuator.waitForReports(1)

        #expect(await store.metadata(for: vmId) == nil)
        // The VM really is still here: the delete threw, so nothing converged.
        #expect(await actuator.observedPresence()[vmId.uuidString] == .managed(.running))
        #expect(await reconciler.observedGeneration(for: vmId.uuidString) == 0)
    }

    @Test("A VM the sync omits keeps its metadata; omission is not an instruction")
    func heldVMKeepsMetadata() async {
        // STR-98's rule, applied to what the guest reads: a sync that fails to
        // mention a running VM leaves it running, so blinding its metadata
        // service would be the one half of the guest that silence did break.
        let store = MetadataStore()
        let vmId = UUID()
        let actuator = MockActuator(presence: [vmId.uuidString: .managed(.running)])
        let reconciler = makeReconciler(actuator, store: store)
        await store.apply(Self.metadata(vmId, hostname: "web-1"), generation: 1, for: vmId)

        await reconciler.apply(DesiredStateMessage(vms: []), includeMetadata: true)

        #expect(await store.metadata(for: vmId)?.hostname == "web-1")
    }

    @Test("A converged tombstone teardown evicts the VM's metadata")
    func tombstonedTeardownEvictsMetadata() async {
        let store = MetadataStore()
        let vmId = UUID()
        let actuator = MockActuator(presence: [vmId.uuidString: .managed(.running)])
        let reconciler = makeReconciler(actuator, store: store)
        await store.apply(Self.metadata(vmId, hostname: "web-1"), generation: 1, for: vmId)

        await reconciler.apply(
            DesiredStateMessage(
                vms: [], tombstones: [DesiredWorkloadTombstone(kind: .vm, workloadId: vmId, generation: 2)]),
            includeMetadata: true)
        _ = await actuator.waitForReports(1)

        #expect(await store.metadata(for: vmId) == nil)
        #expect(await store.appliedGeneration(for: vmId) == 2)
    }

    @Test("A teardown the blast-radius guard refused keeps serving its metadata")
    func refusedTeardownKeepsMetadata() async {
        // The guard exists to keep those VMs running; taking their metadata
        // away would blind guests this agent deliberately kept alive.
        let store = MetadataStore()
        let vmIds = (0..<4).map { _ in UUID() }
        var presence: [String: VMPresence] = [:]
        for vmId in vmIds { presence[vmId.uuidString] = .managed(.running) }
        let actuator = MockActuator(presence: presence)
        let reconciler = makeReconciler(actuator, store: store)
        for (index, vmId) in vmIds.enumerated() {
            await store.apply(Self.metadata(vmId, hostname: "web-\(index)"), generation: 1, for: vmId)
        }

        await reconciler.apply(
            DesiredStateMessage(
                vms: [],
                tombstones: vmIds.map { DesiredWorkloadTombstone(kind: .vm, workloadId: $0, generation: 2) }),
            includeMetadata: true)

        #expect(await reconciler.lastTeardownRefusal() != nil)
        for (index, vmId) in vmIds.enumerated() {
            #expect(await store.metadata(for: vmId)?.hostname == "web-\(index)")
        }
    }

    @Test("An agent that cannot see its own workloads still records fresh metadata")
    func blindAgentStillRecordsMetadata() async {
        // The store is a projection of what the control plane said, not of what
        // this host holds, so the presence guard that stops all convergence
        // (STR-138) does not stop the guests' metadata from staying current.
        let store = MetadataStore()
        let actuator = BlindActuator()
        let reconciler = Reconciler(
            actuator: actuator, queue: SerialTaskQueue(), logger: Logger(label: "test"), metadataStore: store)
        let vmId = UUID()

        await reconciler.apply(
            DesiredStateMessage(vms: [
                Self.desired(vmId, generation: 3, metadata: Self.metadata(vmId, hostname: "web-1"))
            ]),
            includeMetadata: true)

        #expect(await store.metadata(for: vmId)?.hostname == "web-1")
        #expect(await reconciler.observedGeneration(for: vmId.uuidString) == 0)
    }

    /// An actuator whose durable manifest could not be read, so it cannot say
    /// what this host holds (STR-138).
    private actor BlindActuator: ReconcileActuator {
        func presenceIsComplete() -> Bool { false }
        func observedPresence() -> [String: VMPresence] { [:] }
        func adoptVM(_ item: ReconcileWorkItem) throws -> VMStatus { .running }
        func perform(_ step: ReconcileStep, item: ReconcileWorkItem) throws {}
        func convergenceDidChange() {}
    }
}
