import Foundation
import Logging
import StratoShared
import Testing

@testable import StratoAgentCore

/// The agent-side snapshot convergence engine (ADR 0001 stage 8, STR-150).
///
/// Three properties carry most of the weight here and each is pinned
/// separately:
///
/// * **A capture never re-runs.** It is a create strategy, planned only while
///   the artifact is absent from the host, which is what makes it safe for a
///   level-triggered sync to carry an instruction that pauses a live guest.
/// * **Silence is not an instruction.** A nil `snapshots` field, and a record
///   store that cannot be read, both skip the snapshot half rather than
///   planning against an empty desired set.
/// * **A capture holds its parent's lane**, so it can never interleave with
///   that parent's own convergence.
@Suite("Snapshot artifact reconciliation (STR-150)")
struct SnapshotReconciliationTests {

    /// A minimal actuator that records the steps it was asked to run and keeps
    /// an in-memory artifact inventory.
    private actor MockSnapshotActuator: ReconcileActuator {
        var artifacts: [String: SnapshotPresence]
        var inventoryReadable = true
        var presenceComplete = true
        var performed: [(ReconcileStep, String)] = []
        var reportCount = 0

        init(artifacts: [String: SnapshotPresence] = [:]) {
            self.artifacts = artifacts
        }

        func setInventoryReadable(_ readable: Bool) { inventoryReadable = readable }
        func setPresenceComplete(_ complete: Bool) { presenceComplete = complete }

        func presenceIsComplete() -> Bool { presenceComplete }
        func observedPresence() -> [String: VMPresence] { [:] }
        func observedSizing() -> [String: VMSizing] { [:] }
        func observedNetworkSpecs() -> [String: [NetworkSpec]] { [:] }
        func adoptVM(_ item: ReconcileWorkItem) throws -> VMStatus { .running }
        func observedSandboxPresence() -> [String: SandboxPresence] { [:] }
        func adoptSandbox(_ item: ReconcileWorkItem) throws -> SandboxStatus {
            throw UnsupportedTestActuation.sandbox
        }
        func observedVolumePresence() -> [String: VolumePresence]? { [:] }
        func observedSnapshotPresence() -> [String: SnapshotPresence]? {
            inventoryReadable ? artifacts : nil
        }
        func observedEdgeNonces() -> [String: AppliedEdgeNonces] { [:] }
        func recordAppliedEdges(_ item: ReconcileWorkItem, _ nonces: AppliedEdgeNonces) {}

        func perform(_ step: ReconcileStep, item: ReconcileWorkItem) throws {
            performed.append((step, item.id))
            guard let desired = item.desiredSnapshot else {
                // A tombstoned teardown carries no desired entry; the record is
                // the only thing that says what it was.
                if step == .delete { artifacts.removeValue(forKey: item.id) }
                return
            }
            switch step {
            case .create:
                artifacts[item.id] = .managed(
                    ObservedSnapshotArtifact(
                        kind: desired.kind, parentId: desired.parentId,
                        facts: ObservedSnapshotFacts(sizeBytes: 1024)))
            case .export:
                guard case .managed(let current)? = artifacts[item.id] else { return }
                artifacts[item.id] = .managed(
                    ObservedSnapshotArtifact(
                        kind: current.kind, parentId: current.parentId, facts: current.facts,
                        exported: true))
            case .delete:
                artifacts.removeValue(forKey: item.id)
            case .adopt, .boot, .pause, .resume, .shutdown, .resize, .attach, .detach,
                .reboot, .restore, .reconfigureNetworks:
                break
            }
        }

        func convergenceDidChange() { reportCount += 1 }
    }

    private static func reconciler(_ actuator: MockSnapshotActuator) -> Reconciler {
        Reconciler(
            actuator: actuator, queue: SerialTaskQueue(), logger: Logger(label: "test"),
            metadataStore: MetadataStore())
    }

    private static func sync(
        _ snapshots: [DesiredSnapshotState],
        tombstones: [DesiredWorkloadTombstone] = []
    ) -> DesiredStateMessage {
        DesiredStateMessage(syncId: "s", vms: [], tombstones: tombstones, snapshots: snapshots)
    }

    private static func entry(
        _ id: UUID,
        kind: SnapshotArtifactKind = .vmCheckpoint,
        parent: UUID = UUID(),
        status: DesiredSnapshotStatus = .present,
        generation: Int64 = 1,
        volumeStorage: DesiredVolumeStorage? = nil,
        export: DesiredSnapshotExport? = nil
    ) -> DesiredSnapshotState {
        DesiredSnapshotState(
            snapshotId: id, kind: kind, parentId: parent, desiredStatus: status,
            generation: generation, volumeStorage: volumeStorage, export: export)
    }

    private static func present(
        _ kind: SnapshotArtifactKind, parent: UUID = UUID(), exported: Bool = false
    ) -> SnapshotPresence {
        .managed(
            ObservedSnapshotArtifact(
                kind: kind, parentId: parent, facts: ObservedSnapshotFacts(sizeBytes: 1024),
                exported: exported))
    }

    // MARK: - Capture

    @Test("An absent artifact is captured")
    func absentArtifactIsCaptured() async {
        let id = UUID()
        let actuator = MockSnapshotActuator()
        let reconciler = Self.reconciler(actuator)

        await reconciler.apply(Self.sync([Self.entry(id)]))
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))

        let performed = await actuator.performed
        #expect(performed.map(\.0) == [.create])
        #expect(performed.first?.1 == id.uuidString)
    }

    /// The safety property the whole conversion rests on. A capture is a
    /// *create strategy*: it is planned only while the artifact is absent, so a
    /// replayed or re-driven sync cannot checkpoint a running guest a second
    /// time over the point in time the user is holding.
    @Test("An artifact that already exists is never re-captured")
    func presentArtifactIsNotRecaptured() async {
        let id = UUID()
        let actuator = MockSnapshotActuator(artifacts: [id.uuidString: Self.present(.vmCheckpoint)])
        let reconciler = Self.reconciler(actuator)

        // Same generation (drift correction) and a newer one both re-plan the
        // entry; neither may produce a capture.
        await reconciler.apply(Self.sync([Self.entry(id, generation: 1)]))
        await reconciler.apply(Self.sync([Self.entry(id, generation: 9)]))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await actuator.performed.isEmpty)
    }

    // MARK: - Export

    @Test("A desired export is converged once, then never again")
    func exportConvergesOnce() async {
        let id = UUID()
        let export = DesiredSnapshotExport(uploads: [
            SandboxSnapshotArtifactUploadTarget(kind: .memory, uploadURL: "/api/memory")
        ])
        let actuator = MockSnapshotActuator(
            artifacts: [id.uuidString: Self.present(.sandboxSnapshot)])
        let reconciler = Self.reconciler(actuator)

        await reconciler.apply(
            Self.sync([Self.entry(id, kind: .sandboxSnapshot, generation: 2, export: export)]))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await actuator.performed.map(\.0) == [.export])

        // Re-driven at a newer generation: the artifact is already exported, so
        // the diff is empty and no archive is re-uploaded.
        await reconciler.apply(
            Self.sync([Self.entry(id, kind: .sandboxSnapshot, generation: 3, export: export)]))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await actuator.performed.map(\.0) == [.export])
    }

    /// Withdrawing an export is the control plane's own object-store
    /// bookkeeping, not a teardown the agent can perform — so an entry that
    /// stops asking for one plans nothing rather than trying to un-export.
    @Test("Dropping the export field plans no work")
    func withdrawnExportPlansNothing() async {
        let id = UUID()
        let actuator = MockSnapshotActuator(
            artifacts: [id.uuidString: Self.present(.sandboxSnapshot, exported: true)])
        let reconciler = Self.reconciler(actuator)

        await reconciler.apply(
            Self.sync([Self.entry(id, kind: .sandboxSnapshot, generation: 4)]))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await actuator.performed.isEmpty)
    }

    // MARK: - Deletion

    @Test("An absent desired status deletes the artifact")
    func absentDesiredStatusDeletes() async {
        let id = UUID()
        let actuator = MockSnapshotActuator(artifacts: [id.uuidString: Self.present(.volumeSnapshot)])
        let reconciler = Self.reconciler(actuator)

        await reconciler.apply(
            Self.sync([Self.entry(id, kind: .volumeSnapshot, status: .absent, generation: 2)]))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await actuator.performed.map(\.0) == [.delete])
        #expect(await actuator.artifacts[id.uuidString] == nil)
    }

    @Test("A replacement Ceph client deletes a snapshot without a local record")
    func absentCephSnapshotWithoutRecordStillDeletes() async {
        let id = UUID()
        let clusterId = UUID()
        let credentialId = UUID()
        let storage = DesiredVolumeStorage.ceph(
            CephVolumeStorage(
                clusterId: clusterId, fsid: UUID().uuidString, pool: "volumes",
                namespace: "project-a", clientName: "client.strato-project-a",
                monEndpoints: ["v2:mon.example:3300"], credentialId: credentialId,
                keyring: "[client.strato-project-a]\nkey = secret", messengerMode: .secure))
        let actuator = MockSnapshotActuator()
        let reconciler = Self.reconciler(actuator)

        await reconciler.apply(
            Self.sync([
                Self.entry(
                    id, kind: .volumeSnapshot, status: .absent, generation: 2,
                    volumeStorage: storage)
            ]))

        // The item is visible as in-flight before the delete has completed;
        // report assembly therefore emits present=false progress instead of
        // prematurely confirming deletion by omission.
        var sawInFlight = false
        for _ in 0..<50 {
            if await reconciler.inFlightWorkloads(kind: .volumeSnapshot)[id.uuidString] == 2 {
                sawInFlight = true
                break
            }
            await Task.yield()
        }
        try? await Task.sleep(for: .milliseconds(50))

        let performedSteps = await actuator.performed.map(\.0)
        #expect(sawInFlight || performedSteps == [.delete])
        #expect(performedSteps == [.delete])
        #expect(await reconciler.observedGeneration(for: id.uuidString, kind: .volumeSnapshot) == 2)
    }

    @Test("A missing local snapshot remains already absent")
    func absentLocalSnapshotWithoutRecordDoesNotDelete() async {
        let id = UUID()
        let actuator = MockSnapshotActuator()
        let reconciler = Self.reconciler(actuator)

        await reconciler.apply(
            Self.sync([
                Self.entry(
                    id, kind: .volumeSnapshot, status: .absent, generation: 2,
                    volumeStorage: .local)
            ]))
        try? await Task.sleep(for: .milliseconds(20))

        #expect(await actuator.performed.isEmpty)
        #expect(await reconciler.observedGeneration(for: id.uuidString, kind: .volumeSnapshot) == 2)
    }

    /// STR-98's contract, inherited whole: an artifact the sync does not list is
    /// *held* and reported, never destroyed on silence.
    @Test("An unlisted artifact is held and reported, not deleted")
    func unlistedArtifactIsHeld() async {
        let id = UUID()
        let actuator = MockSnapshotActuator(artifacts: [id.uuidString: Self.present(.vmCheckpoint)])
        let reconciler = Self.reconciler(actuator)

        await reconciler.apply(Self.sync([]))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await actuator.performed.isEmpty)
        let held = await reconciler.unrecognizedWorkloads()
        #expect(held.map(\.workloadId) == [id])
        #expect(held.first?.kind == .vmCheckpoint)
    }

    @Test("A tombstone authorizes the teardown the silence did not")
    func tombstoneAuthorizesTeardown() async {
        let id = UUID()
        let actuator = MockSnapshotActuator(artifacts: [id.uuidString: Self.present(.vmCheckpoint)])
        let reconciler = Self.reconciler(actuator)

        await reconciler.apply(
            Self.sync(
                [],
                tombstones: [
                    DesiredWorkloadTombstone(kind: .vmCheckpoint, workloadId: id, generation: 5)
                ]))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await actuator.performed.map(\.0) == [.delete])
        #expect(await actuator.artifacts[id.uuidString] == nil)
    }

    // MARK: - Unknown local inventory

    /// An inventory the agent cannot read is
    /// "I don't know", not "there is nothing here". Planning against `[:]` would
    /// re-capture every desired artifact, checkpointing live guests over ones
    /// already on disk.
    @Test("An unreadable record store skips the snapshot half")
    func unreadableInventorySkipsTheHalf() async {
        let id = UUID()
        let actuator = MockSnapshotActuator()
        await actuator.setInventoryReadable(false)
        let reconciler = Self.reconciler(actuator)

        await reconciler.apply(Self.sync([Self.entry(id)]))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await actuator.performed.isEmpty)
    }

    @Test("A blind host converges no snapshot work either")
    func incompletePresenceSkipsEverything() async {
        let actuator = MockSnapshotActuator()
        await actuator.setPresenceComplete(false)
        let reconciler = Self.reconciler(actuator)

        await reconciler.apply(Self.sync([Self.entry(UUID())]))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await actuator.performed.isEmpty)
    }

    // MARK: - Lanes and ordering

    /// Capturing a checkpoint pauses the guest and drives the parent's
    /// hypervisor session, so the item must hold the parent's lane too — a
    /// capture racing a delete would checkpoint a VM out from under its
    /// teardown.
    @Test("A snapshot item holds its own lane and its parent's")
    func laneKeysIncludeParent() {
        let snapshotId = UUID()
        let vmId = UUID()
        let vmItem = ReconcileWorkItem(
            kind: .vmCheckpoint, id: snapshotId.uuidString, generation: 1, steps: [.create],
            target: .snapshot(Self.entry(snapshotId, kind: .vmCheckpoint, parent: vmId)))
        #expect(vmItem.laneKeys == ["snapshot/" + snapshotId.uuidString, vmId.uuidString])

        let sandboxId = UUID()
        let sandboxItem = ReconcileWorkItem(
            kind: .sandboxSnapshot, id: snapshotId.uuidString, generation: 1, steps: [.create],
            target: .snapshot(
                Self.entry(snapshotId, kind: .sandboxSnapshot, parent: sandboxId)))
        #expect(
            sandboxItem.laneKeys == ["snapshot/" + snapshotId.uuidString, "sandbox/" + sandboxId.uuidString])

        let volumeId = UUID()
        let volumeItem = ReconcileWorkItem(
            kind: .volumeSnapshot, id: snapshotId.uuidString, generation: 1, steps: [.create],
            target: .snapshot(Self.entry(snapshotId, kind: .volumeSnapshot, parent: volumeId)))
        #expect(
            volumeItem.laneKeys == ["snapshot/" + snapshotId.uuidString, "volume/" + volumeId.uuidString])
    }

    /// The desired list is mixed-kind; each family is planned in its own
    /// namespace, so an id in one can never be read as stale against another's
    /// applied generation.
    @Test("A mixed-kind list plans every family")
    func mixedKindListPlansEveryFamily() async {
        let volumeSnapshot = UUID()
        let checkpoint = UUID()
        let sandboxSnapshot = UUID()
        let actuator = MockSnapshotActuator()
        let reconciler = Self.reconciler(actuator)

        await reconciler.apply(
            Self.sync([
                Self.entry(volumeSnapshot, kind: .volumeSnapshot),
                Self.entry(checkpoint, kind: .vmCheckpoint),
                Self.entry(sandboxSnapshot, kind: .sandboxSnapshot),
            ]))
        try? await Task.sleep(for: .milliseconds(80))

        let captured = Set(await actuator.performed.filter { $0.0 == .create }.map(\.1))
        #expect(
            captured == Set([volumeSnapshot, checkpoint, sandboxSnapshot].map(\.uuidString)))
    }

    // MARK: - Steps

    @Test("An existing artifact with no export desire plans nothing")
    func satisfiedArtifactPlansNothing() {
        let steps = Reconciler.snapshotSteps(
            desired: Self.entry(UUID()),
            observed: ObservedSnapshotArtifact(kind: .vmCheckpoint, parentId: UUID()))
        #expect(steps.isEmpty)
    }

    @Test("An existing artifact with an unmet export plans the export")
    func unexportedArtifactPlansExport() {
        let steps = Reconciler.snapshotSteps(
            desired: Self.entry(
                UUID(), kind: .sandboxSnapshot,
                export: DesiredSnapshotExport(uploads: [])),
            observed: ObservedSnapshotArtifact(kind: .sandboxSnapshot, parentId: UUID()))
        #expect(steps == [.export])
    }
}
