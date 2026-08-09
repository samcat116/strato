import Foundation
import Logging
import StratoShared
import Testing

@testable import StratoAgentCore

/// Reboot and restore as edge-nonces (ADR 0001 stage 9, STR-151).
///
/// These are the only steps the reconciler emits that are **not** idempotent at
/// the "already satisfied" level — re-driving one restarts a guest a second time
/// or rewinds it past writes it has made since. Everything below pins one of the
/// three rules that make it safe to plan them from a level-triggered sync:
///
/// * a nonce is applied only while it outranks a **durable** record;
/// * **no record is not zero** — it is adopted, never replayed;
/// * an edge is consumed by being *superseded* as much as by being performed.
@Suite("Edge nonces (STR-151)")
struct EdgeNonceReconciliationTests {
    private static let snapshotID = UUID()

    private static func vm(
        _ vmId: UUID,
        status: DesiredVMStatus = .running,
        generation: Int64 = 1,
        rebootGeneration: Int64? = nil,
        restoreGeneration: Int64? = nil
    ) -> DesiredVMState {
        DesiredVMState(
            vmId: vmId,
            hypervisorType: .qemu,
            spec: VMSpec(cpus: 1, memoryBytes: 1 << 30, boot: .disk(firmware: nil)),
            desiredStatus: status,
            generation: generation,
            rebootGeneration: rebootGeneration,
            restore: restoreGeneration.map {
                DesiredRestore(generation: $0, snapshotId: snapshotID)
            })
    }

    private static func plan(
        _ entry: DesiredVMState,
        present: VMPresence,
        applied: AppliedEdgeNonces?,
        lastApplied: Int64 = 0
    ) -> [ReconcileStep] {
        let id = entry.vmId.uuidString
        let plan = Reconciler.plan(
            desired: [entry],
            present: [id: present],
            lastApplied: [id: lastApplied],
            appliedEdges: applied.map { [id: $0] } ?? [:])
        return plan.items.first?.steps ?? []
    }

    // MARK: - The nonce comparison

    @Test("a reboot nonce above the record plans a restart")
    func rebootOutranksRecord() {
        let steps = Self.plan(
            Self.vm(UUID(), rebootGeneration: 3),
            present: .managed(.running),
            applied: AppliedEdgeNonces(reboot: 2))
        #expect(steps == [.reboot])
    }

    @Test("a reboot nonce the host has already applied plans nothing")
    func rebootAtRecordIsSatisfied() {
        // The level-triggered case: the same sync arrives again — from the
        // periodic re-fetch, a doorbell, or a replica that re-pushed — and must
        // not restart the guest a second time.
        let steps = Self.plan(
            Self.vm(UUID(), rebootGeneration: 3),
            present: .managed(.running),
            applied: AppliedEdgeNonces(reboot: 3))
        #expect(steps.isEmpty)
    }

    @Test("a record with no reboot yet is outranked by the first request")
    func firstRebootActsAgainstAnEmptyRecord() {
        // A *present* record whose `reboot` is nil is different from no record
        // at all: it says this host has converged the workload and the control
        // plane has simply never asked for a restart. The first request must
        // therefore act, or a VM created under v34 could never be rebooted.
        let steps = Self.plan(
            Self.vm(UUID(), rebootGeneration: 1),
            present: .managed(.running),
            applied: AppliedEdgeNonces())
        #expect(steps == [.reboot])
    }

    @Test("both nonces outranking plans reboot then restore")
    func bothEdgesPlanInOrder() {
        // Restoring last is what leaves the guest holding the checkpoint's
        // state; the other order would throw it away.
        let steps = Self.plan(
            Self.vm(UUID(), rebootGeneration: 2, restoreGeneration: 2),
            present: .managed(.running),
            applied: AppliedEdgeNonces(reboot: 1, restore: 1))
        #expect(steps == [.reboot, .restore])
    }

    // MARK: - No record is not zero

    /// The invariant the issue names: "a manifest-less re-registration must NOT
    /// replay reboots/restores."
    @Test("a workload with no durable record plans no edge at all")
    func missingRecordIsAdoptedNotReplayed() {
        let steps = Self.plan(
            Self.vm(UUID(), rebootGeneration: 7, restoreGeneration: 4),
            present: .managed(.running),
            applied: nil)
        #expect(steps.isEmpty)
    }

    @Test("adoption is what turns a missing record into a real one")
    func missingRecordIsWrittenOnConvergence() async {
        // Planning nothing is only half the answer: if the record stayed
        // missing, the *next* reboot would be dropped too and the VM could
        // never be restarted again. Convergence has to write one.
        let vmId = UUID()
        let actuator = MockEdgeActuator(presence: [vmId.uuidString: .managed(.running)])
        let reconciler = Reconciler(
            actuator: actuator, queue: SerialTaskQueue(), logger: Logger(label: "test"),
            metadataStore: MetadataStore())

        await reconciler.apply(
            DesiredStateMessage(vms: [Self.vm(vmId, generation: 5, rebootGeneration: 7)]))
        _ = await actuator.waitForRecord(vmId.uuidString)

        #expect(await actuator.performed.isEmpty)
        #expect(await actuator.nonces[vmId.uuidString] == AppliedEdgeNonces(reboot: 7))

        // And now the *next* request is actionable, which is the whole point.
        await reconciler.apply(
            DesiredStateMessage(vms: [Self.vm(vmId, generation: 6, rebootGeneration: 8)]))
        _ = await actuator.waitForPerformed(1)
        #expect(await actuator.performed.map(\.step) == [.reboot])
    }

    /// The upgrade window, and the reason the record cannot be written lazily.
    ///
    /// A host that upgrades into this build has a manifest full of entries with
    /// no nonce record. If adoption waited for an *item* — and a converged, idle
    /// VM produces none, because its generation is not moving — the record would
    /// stay absent until something finally bumped that generation. The thing
    /// that does is usually the user's own restart request, which the absent
    /// record then swallows while `conditions` report it converged: the guest
    /// never reboots and nothing anywhere says so.
    ///
    /// So a managed workload with no record produces an empty-step item on the
    /// very next sync, purely to write one.
    @Test("a converged idle VM adopts its record on the next sync, not on its next request")
    func idleWorkloadAdoptsWithoutWaitingForAGenerationBump() async {
        let vmId = UUID()
        let actuator = MockEdgeActuator(presence: [vmId.uuidString: .managed(.running)])
        let reconciler = Reconciler(
            actuator: actuator, queue: SerialTaskQueue(), logger: Logger(label: "test"),
            metadataStore: MetadataStore())

        // Sync 1: converged, nothing asked for, no record. The item exists only
        // to adopt — and adopts an *empty* record, since nothing was requested.
        let converged = Self.vm(vmId, generation: 4)
        await reconciler.apply(DesiredStateMessage(vms: [converged]))
        _ = await actuator.waitForRecord(vmId.uuidString, expecting: AppliedEdgeNonces())
        #expect(await actuator.nonces[vmId.uuidString] == AppliedEdgeNonces())
        #expect(await actuator.performed.isEmpty)

        // Sync 2, identical: nothing left to owe, so no repeat write.
        await reconciler.apply(DesiredStateMessage(vms: [converged]))
        #expect(await actuator.recorded.count == 1)

        // And the first restart the user asks for is *performed*, not swallowed.
        await reconciler.apply(
            DesiredStateMessage(vms: [Self.vm(vmId, generation: 5, rebootGeneration: 1)]))
        _ = await actuator.waitForPerformed(1)
        #expect(await actuator.performed.map(\.step) == [.reboot])
        #expect(await actuator.nonces[vmId.uuidString] == AppliedEdgeNonces(reboot: 1))
    }

    @Test("a volume never owes an edge record, so it plans no adoption item")
    func bytesOweNoRecord() {
        // The other half of the adoption rule: it is scoped to kinds that carry
        // edges. A volume has none, and nothing would ever write one, so owing a
        // record would make the planner emit an item for it on every sync
        // forever.
        let volumeId = UUID()
        let id = volumeId.uuidString
        let desired = DesiredVolumeState(
            volumeId: volumeId, desiredStatus: .present, generation: 2,
            sizeBytes: 1 << 30, format: "qcow2")
        let plan = Reconciler.planVolumes(
            desired: [desired],
            present: [id: .managed(ObservedVolumeFacts(path: "/v", format: .qcow2, sizeBytes: 1 << 30))],
            lastApplied: [id: 2])
        #expect(plan.items.isEmpty)
    }

    @Test("an orphan defers its edges to the sync after adoption")
    func orphanDefersEdges() async {
        // An orphan's real state is unknown until its runtime session is
        // reconnected, so no edge is planned for it — and, critically, the
        // record is *not* written either. Writing it would consume a pending
        // restore without performing it.
        let vmId = UUID()
        let actuator = MockEdgeActuator(presence: [vmId.uuidString: .orphaned])
        await actuator.setNonces([vmId.uuidString: AppliedEdgeNonces(restore: 1)])
        let reconciler = Reconciler(
            actuator: actuator, queue: SerialTaskQueue(), logger: Logger(label: "test"),
            metadataStore: MetadataStore())

        await reconciler.apply(
            DesiredStateMessage(vms: [Self.vm(vmId, generation: 3, restoreGeneration: 2)]))
        _ = await actuator.waitForPerformed(1)

        #expect(await actuator.performed.map(\.step) == [.adopt])
        #expect(await actuator.nonces[vmId.uuidString] == AppliedEdgeNonces(restore: 1))

        // The workload is managed now, so the same sync converges the edge.
        await reconciler.apply(
            DesiredStateMessage(vms: [Self.vm(vmId, generation: 3, restoreGeneration: 2)]))
        _ = await actuator.waitForPerformed(2)
        #expect(await actuator.performed.map(\.step) == [.adopt, .restore])
    }

    // MARK: - Supersession

    @Test("a boot supersedes a reboot but not a restore")
    func bootSupersedesRebootOnly() {
        // A guest built from scratch this sync is at least as restarted as a
        // reboot would make it. A checkpoint, by contrast, needs a process to
        // load into — `[.boot, .restore]` is what makes "restore after an agent
        // restart" work with no extra message.
        let steps = Self.plan(
            Self.vm(UUID(), rebootGeneration: 2, restoreGeneration: 2),
            present: .managed(.shutdown),
            applied: AppliedEdgeNonces())
        #expect(steps == [.boot, .restore])
    }

    @Test("a VM the control plane wants stopped plans no edge")
    func stoppingPlansNoEdge() {
        let steps = Self.plan(
            Self.vm(UUID(), status: .shutdown, rebootGeneration: 5, restoreGeneration: 5),
            present: .managed(.shutdown),
            applied: AppliedEdgeNonces())
        #expect(steps.isEmpty)
    }

    /// The asymmetry the two edges are held to, and the reason for it: a stop is
    /// a *power* decision, so it can answer a reboot but not a restore.
    ///
    /// The same premise already says a `.boot` cannot supersede a restore (a
    /// checkpoint needs a process to load into); read the other way it says a
    /// stop cannot either. Consuming one here would silently discard a
    /// data-integrity request the API had already reported converged, so the
    /// restore waits and lands as `[.boot, .restore]` when the VM is next wanted
    /// running.
    @Test("a stop consumes a pending reboot but only defers a pending restore")
    func stopConsumesRebootAndDefersRestore() {
        let edges = DesiredEdges(
            rebootGeneration: 5,
            restore: DesiredRestore(generation: 5, snapshotId: Self.snapshotID))
        let after = Reconciler.edgesAfter(
            edges, applied: AppliedEdgeNonces(), planning: [.shutdown])
        #expect(after.reboot == 5)
        #expect(after.restore == nil)
    }

    @Test("a deferred restore lands on the sync that starts the VM again")
    func deferredRestoreLandsOnTheNextStart() async {
        let vmId = UUID()
        let actuator = MockEdgeActuator(presence: [vmId.uuidString: .managed(.running)])
        await actuator.setNonces([vmId.uuidString: AppliedEdgeNonces()])
        let reconciler = Reconciler(
            actuator: actuator, queue: SerialTaskQueue(), logger: Logger(label: "test"),
            metadataStore: MetadataStore())

        // A stop lands between the restore request and this sync.
        await reconciler.apply(
            DesiredStateMessage(
                vms: [
                    Self.vm(vmId, status: .shutdown, generation: 3, restoreGeneration: 2)
                ]))
        _ = await actuator.waitForPerformed(1)
        #expect(await actuator.performed.map(\.step) == [.shutdown])
        // Outstanding, not swallowed.
        #expect(await actuator.nonces[vmId.uuidString] == AppliedEdgeNonces())

        // Start it again: the checkpoint is loaded into the fresh process.
        await reconciler.apply(
            DesiredStateMessage(vms: [Self.vm(vmId, generation: 4, restoreGeneration: 2)]))
        _ = await actuator.waitForPerformed(3)
        #expect(await actuator.performed.map(\.step) == [.shutdown, .boot, .restore])
        #expect(await actuator.nonces[vmId.uuidString] == AppliedEdgeNonces(restore: 2))
    }

    @Test("a superseded reboot is still consumed, so it cannot fire later")
    func supersededRebootIsRecorded() async {
        // The failure this guards: stop a VM with a reboot outstanding, start it
        // weeks later, and be surprised by an ancient restart. The item plans no
        // work at all here, which is exactly the case that has to record.
        let vmId = UUID()
        let actuator = MockEdgeActuator(presence: [vmId.uuidString: .managed(.shutdown)])
        await actuator.setNonces([vmId.uuidString: AppliedEdgeNonces()])
        let reconciler = Reconciler(
            actuator: actuator, queue: SerialTaskQueue(), logger: Logger(label: "test"),
            metadataStore: MetadataStore())

        await reconciler.apply(
            DesiredStateMessage(
                vms: [Self.vm(vmId, status: .shutdown, generation: 2, rebootGeneration: 5)]))
        _ = await actuator.waitForRecord(vmId.uuidString, expecting: AppliedEdgeNonces(reboot: 5))

        #expect(await actuator.performed.isEmpty)
        #expect(await actuator.nonces[vmId.uuidString] == AppliedEdgeNonces(reboot: 5))
    }

    @Test("a deleted workload records nothing")
    func deleteRecordsNothing() async {
        let vmId = UUID()
        let actuator = MockEdgeActuator(presence: [vmId.uuidString: .managed(.running)])
        await actuator.setNonces([vmId.uuidString: AppliedEdgeNonces(reboot: 1)])
        let reconciler = Reconciler(
            actuator: actuator, queue: SerialTaskQueue(), logger: Logger(label: "test"),
            metadataStore: MetadataStore())

        await reconciler.apply(
            DesiredStateMessage(
                vms: [Self.vm(vmId, status: .absent, generation: 2, rebootGeneration: 5)]))
        _ = await actuator.waitForPerformed(1)

        #expect(await actuator.performed.map(\.step) == [.delete])
        // Untouched: there is no manifest entry left to record against.
        #expect(await actuator.nonces[vmId.uuidString] == AppliedEdgeNonces(reboot: 1))
    }

    // MARK: - Failure

    @Test("a failed reboot is not recorded, so the next sync retries it")
    func failedEdgeIsNotConsumed() async {
        let vmId = UUID()
        let actuator = MockEdgeActuator(presence: [vmId.uuidString: .managed(.running)])
        await actuator.setNonces([vmId.uuidString: AppliedEdgeNonces()])
        await actuator.setFailure(TestFailure())
        let reconciler = Reconciler(
            actuator: actuator, queue: SerialTaskQueue(), logger: Logger(label: "test"),
            metadataStore: MetadataStore())

        await reconciler.apply(
            DesiredStateMessage(vms: [Self.vm(vmId, generation: 2, rebootGeneration: 1)]))
        _ = await actuator.waitForPerformed(1)

        #expect(await actuator.nonces[vmId.uuidString] == AppliedEdgeNonces())
        #expect(await reconciler.lastError(for: vmId.uuidString) != nil)
    }

    // MARK: - Sandboxes

    @Test("a sandbox restore nonce plans a restore against its own record")
    func sandboxRestore() {
        let sandboxId = UUID()
        let entry = DesiredSandboxState(
            sandboxId: sandboxId,
            spec: SandboxSpec(image: "alpine:3", cpus: 1, memoryBytes: 1 << 28),
            desiredStatus: .running,
            generation: 3,
            restore: DesiredRestore(generation: 2, snapshotId: Self.snapshotID))
        let id = sandboxId.uuidString

        let planned = Reconciler.planSandboxes(
            desired: [entry], present: [id: .managed(.running)], lastApplied: [id: 0],
            appliedEdges: [id: AppliedEdgeNonces(restore: 1)])
        #expect(planned.items.first?.steps == [.restore])

        // Same entry, record already caught up: nothing to do.
        let converged = Reconciler.planSandboxes(
            desired: [entry], present: [id: .managed(.running)], lastApplied: [id: 3],
            appliedEdges: [id: AppliedEdgeNonces(restore: 2)])
        #expect(converged.items.isEmpty)
    }
}

private struct TestFailure: Error {}

/// A minimal actuator that models the durable nonce record and nothing else.
private actor MockEdgeActuator: ReconcileActuator {
    var presence: [String: VMPresence]
    var sandboxes: [String: SandboxPresence] = [:]
    private(set) var nonces: [String: AppliedEdgeNonces] = [:]
    private(set) var recorded: [String] = []
    private(set) var performed: [(step: ReconcileStep, id: String)] = []
    private var failWith: (any Error)?

    init(presence: [String: VMPresence]) {
        self.presence = presence
    }

    func setNonces(_ nonces: [String: AppliedEdgeNonces]) { self.nonces = nonces }
    func setFailure(_ error: (any Error)?) { failWith = error }

    func presenceIsComplete() -> Bool { true }
    func observedPresence() -> [String: VMPresence] { presence }
    func observedSizing() -> [String: VMSizing] { [:] }
    func observedNetworkSpecs() -> [String: [NetworkSpec]] { [:] }
    func observedSandboxPresence() -> [String: SandboxPresence] { sandboxes }
    func observedVolumePresence() -> [String: VolumePresence]? { [:] }
    func observedSnapshotPresence() -> [String: SnapshotPresence]? { [:] }
    func observedEdgeNonces() -> [String: AppliedEdgeNonces] { nonces }

    func recordAppliedEdges(_ item: ReconcileWorkItem, _ applied: AppliedEdgeNonces) {
        nonces[item.id] = applied
        recorded.append(item.id)
    }

    func adoptVM(_ item: ReconcileWorkItem) throws -> VMStatus {
        performed.append((.adopt, item.id))
        presence[item.id] = .managed(.running)
        return .running
    }

    func adoptSandbox(_ item: ReconcileWorkItem) throws -> SandboxStatus {
        throw UnsupportedTestActuation.sandbox
    }

    /// Mirrors the hypervisor closely enough that a multi-sync test sees the
    /// state its previous sync produced — which is what a deferred edge is
    /// about.
    func perform(_ step: ReconcileStep, item: ReconcileWorkItem) throws {
        if let failWith { throw failWith }
        performed.append((step, item.id))
        switch step {
        case .create: presence[item.id] = .managed(.created)
        case .boot, .resume, .reboot, .restore: presence[item.id] = .managed(.running)
        case .pause: presence[item.id] = .managed(.paused)
        case .shutdown: presence[item.id] = .managed(.shutdown)
        case .delete: presence.removeValue(forKey: item.id)
        case .adopt, .resize, .attach, .detach, .export, .reconfigureNetworks: break
        }
    }

    func convergenceDidChange() {}

    func waitForPerformed(_ count: Int, timeoutMillis: Int = 5000) async -> Int {
        var waited = 0
        while performed.count < count && waited < timeoutMillis {
            try? await Task.sleep(nanoseconds: 5_000_000)
            waited += 5
        }
        return performed.count
    }

    /// Convergence that plans no work records synchronously inside `apply`, but
    /// the work-item path records on a lane; wait for either.
    func waitForRecord(
        _ id: String, expecting: AppliedEdgeNonces? = nil, timeoutMillis: Int = 5000
    ) async -> AppliedEdgeNonces? {
        var waited = 0
        while waited < timeoutMillis {
            if let current = nonces[id], expecting == nil || current == expecting {
                return current
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
            waited += 5
        }
        return nonces[id]
    }
}
