import Testing
import Foundation
@testable import StratoAgentCore
import StratoShared
import Logging

/// The invariants that make volumes safe as desired state (ADR 0001 stage 5,
/// STR-148).
///
/// Three of these exist to pin arguments the PR text makes rather than
/// behaviours anyone would think to write down: that a nil `volumes` field is
/// not an empty desired list, that a create strategy is consulted exactly once
/// in a volume's life, and that an attachment item holds two serial lanes.
@Suite("Volume reconciliation")
struct VolumeReconciliationTests {

    // MARK: - Fixtures

    private static func desired(
        _ volumeId: UUID,
        status: DesiredVolumeStatus = .present,
        generation: Int64 = 1,
        sizeBytes: Int64 = 10 << 30,
        format: String = "qcow2",
        source: DesiredVolumeSource? = nil,
        attachment: DesiredVolumeAttachment? = nil
    ) -> DesiredVolumeState {
        DesiredVolumeState(
            volumeId: volumeId,
            desiredStatus: status,
            generation: generation,
            sizeBytes: sizeBytes,
            format: format,
            source: source,
            attachment: attachment
        )
    }

    private static func facts(
        path: String = "/var/lib/strato/volumes/v/volume.qcow2",
        format: DiskFormat = .qcow2,
        sizeBytes: Int64? = 10 << 30,
        attachedVMId: String? = nil,
        deviceName: String? = nil
    ) -> ObservedVolumeFacts {
        ObservedVolumeFacts(
            path: path, format: format, sizeBytes: sizeBytes,
            attachedVMId: attachedVMId, deviceName: deviceName)
    }

    /// Actuator double that holds volumes and records the steps driven at them.
    private actor MockVolumeActuator: ReconcileActuator {
        var volumes: [String: VolumePresence]
        private(set) var performed: [(step: ReconcileStep, id: String)] = []
        private(set) var reportCount = 0
        /// False simulates an agent whose workload manifest is unreadable
        /// (STR-138).
        var presenceComplete = true

        init(volumes: [String: VolumePresence] = [:]) {
            self.volumes = volumes
        }

        /// Nil simulates a storage backend that cannot enumerate the store —
        /// as distinct from one that holds nothing.
        var inventoryReadable = true

        func setPresenceComplete(_ complete: Bool) { presenceComplete = complete }
        func setInventoryReadable(_ readable: Bool) { inventoryReadable = readable }
        func presenceIsComplete() -> Bool { presenceComplete }
        func observedPresence() -> [String: VMPresence] { [:] }
        func adoptVM(_ item: ReconcileWorkItem) throws -> VMStatus { .running }
        func observedVolumePresence() -> [String: VolumePresence]? {
            inventoryReadable ? volumes : nil
        }

        func perform(_ step: ReconcileStep, item: ReconcileWorkItem) throws {
            performed.append((step, item.id))
            guard let desired = item.desiredVolume else { return }
            switch step {
            case .create:
                volumes[item.id] = .managed(
                    ObservedVolumeFacts(
                        path: "/var/lib/strato/volumes/\(item.id)/volume.\(desired.format)",
                        format: DiskFormat(rawValue: desired.format) ?? .qcow2,
                        sizeBytes: desired.sizeBytes))
            case .resize:
                guard case .managed(let current)? = volumes[item.id] else { return }
                volumes[item.id] = .managed(
                    ObservedVolumeFacts(
                        path: current.path, format: current.format, sizeBytes: desired.sizeBytes,
                        attachedVMId: current.attachedVMId, deviceName: current.deviceName))
            case .attach:
                guard case .managed(let current)? = volumes[item.id],
                    let attachment = desired.attachment
                else { return }
                volumes[item.id] = .managed(
                    ObservedVolumeFacts(
                        path: current.path, format: current.format, sizeBytes: current.sizeBytes,
                        attachedVMId: attachment.vmId.uuidString, deviceName: attachment.deviceName))
            case .detach:
                guard case .managed(let current)? = volumes[item.id] else { return }
                volumes[item.id] = .managed(
                    ObservedVolumeFacts(
                        path: current.path, format: current.format, sizeBytes: current.sizeBytes))
            case .delete:
                volumes.removeValue(forKey: item.id)
            case .adopt, .boot, .pause, .resume, .shutdown:
                break
            }
        }

        func convergenceDidChange() { reportCount += 1 }
    }

    private static func reconciler(_ actuator: MockVolumeActuator) -> Reconciler {
        Reconciler(actuator: actuator, queue: SerialTaskQueue(), logger: Logger(label: "test"))
    }

    private static func sync(
        volumes: [DesiredVolumeState]?, tombstones: [DesiredWorkloadTombstone] = []
    ) -> DesiredStateMessage {
        DesiredStateMessage(vms: [], tombstones: tombstones, volumes: volumes)
    }

    // MARK: - The diff

    @Test("A volume the host does not hold is created")
    func absentVolumeIsCreated() {
        let id = UUID()
        let plan = Reconciler.planVolumes(
            desired: [Self.desired(id)], present: [:], lastApplied: [:])
        #expect(plan.items.count == 1)
        #expect(plan.items[0].kind == .volume)
        #expect(plan.items[0].steps == [.create])
    }

    @Test("A volume that already matches plans nothing")
    func matchingVolumePlansNothing() {
        let id = UUID()
        let plan = Reconciler.planVolumes(
            desired: [Self.desired(id)],
            present: [id.uuidString: .managed(Self.facts())],
            lastApplied: [id.uuidString: 1])
        #expect(plan.items.isEmpty)
    }

    @Test("A volume smaller than its desired size is grown")
    func undersizedVolumeIsResized() {
        let id = UUID()
        let plan = Reconciler.planVolumes(
            desired: [Self.desired(id, sizeBytes: 20 << 30)],
            present: [id.uuidString: .managed(Self.facts(sizeBytes: 10 << 30))],
            lastApplied: [id.uuidString: 1])
        #expect(plan.items.first?.steps == [.resize])
    }

    /// A size the agent could not probe plans nothing, rather than a resize on
    /// a guess: leaving an unreadable volume alone beats growing it repeatedly.
    @Test("An unprobeable size plans no resize")
    func unknownSizePlansNoResize() {
        let id = UUID()
        let plan = Reconciler.planVolumes(
            desired: [Self.desired(id, sizeBytes: 20 << 30)],
            present: [id.uuidString: .managed(Self.facts(sizeBytes: nil))],
            lastApplied: [id.uuidString: 1])
        #expect(plan.items.isEmpty)
    }

    @Test("A volume whose desired attachment is unrealized is attached")
    func detachedVolumeIsAttached() {
        let id = UUID()
        let vmId = UUID()
        let plan = Reconciler.planVolumes(
            desired: [
                Self.desired(
                    id, attachment: DesiredVolumeAttachment(vmId: vmId, deviceName: "disk1"))
            ],
            present: [id.uuidString: .managed(Self.facts())],
            lastApplied: [id.uuidString: 1])
        #expect(plan.items.first?.steps == [.attach])
    }

    /// Moving an attachment is two syncs, not one: the volume is unplugged
    /// first, and the next level-triggered sync plans the attach against the
    /// observation that follows.
    @Test("A volume attached to the wrong VM is detached first")
    func misattachedVolumeIsDetachedFirst() {
        let id = UUID()
        let wanted = UUID()
        let actual = UUID()
        let plan = Reconciler.planVolumes(
            desired: [
                Self.desired(
                    id, attachment: DesiredVolumeAttachment(vmId: wanted, deviceName: "disk1"))
            ],
            present: [
                id.uuidString: .managed(
                    Self.facts(attachedVMId: actual.uuidString, deviceName: "disk1"))
            ],
            lastApplied: [id.uuidString: 1])
        #expect(plan.items.first?.steps == [.detach])
    }

    @Test("An absent desired volume the host still holds is deleted")
    func absentDesiredVolumeIsDeleted() {
        let id = UUID()
        let plan = Reconciler.planVolumes(
            desired: [Self.desired(id, status: .absent, generation: 2)],
            present: [id.uuidString: .managed(Self.facts())],
            lastApplied: [id.uuidString: 1])
        #expect(plan.items.first?.steps == [.delete])
    }

    /// The generation guard, inherited wholesale from the shared diff engine.
    @Test("A stale volume entry is dropped")
    func staleVolumeEntryIsDropped() {
        let id = UUID()
        let plan = Reconciler.planVolumes(
            desired: [Self.desired(id, status: .absent, generation: 1)],
            present: [id.uuidString: .managed(Self.facts())],
            lastApplied: [id.uuidString: 5])
        #expect(plan.items.isEmpty)
    }

    @Test("A volume the sync neither lists nor tombstones is held and reported")
    func unlistedVolumeIsHeld() {
        let id = UUID()
        let plan = Reconciler.planVolumes(
            desired: [], present: [id.uuidString: .managed(Self.facts())], lastApplied: [:])
        #expect(plan.items.isEmpty)
        #expect(plan.unrecognized.count == 1)
        #expect(plan.unrecognized[0].kind == .volume)
        #expect(plan.unrecognized[0].workloadId == id)
    }

    @Test("A tombstoned volume is torn down")
    func tombstonedVolumeIsDeleted() {
        let id = UUID()
        let plan = Reconciler.planVolumes(
            desired: [],
            present: [id.uuidString: .managed(Self.facts())],
            lastApplied: [:],
            tombstones: [DesiredWorkloadTombstone(kind: .volume, workloadId: id, generation: 1)])
        #expect(plan.items.first?.steps == [.delete])
        #expect(plan.items.first?.isTombstone == true)
        #expect(plan.unrecognized.isEmpty)
    }

    // MARK: - Create strategies

    /// The `restoreFrom` invariant applied to clones: a create strategy is read
    /// only when the volume is *absent*, so a replayed or re-driven sync can
    /// never re-clone over live data.
    @Test("A clone source is ignored once the volume exists")
    func cloneSourceIsIgnoredForAnExistingVolume() async {
        let id = UUID()
        let sourceId = UUID()
        let actuator = MockVolumeActuator(volumes: [id.uuidString: .managed(Self.facts())])
        let reconciler = Self.reconciler(actuator)

        await reconciler.apply(
            Self.sync(volumes: [Self.desired(id, generation: 7, source: .clone(from: sourceId))]),
            includeVolumes: true)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await actuator.performed.isEmpty)
        #expect(await reconciler.observedGeneration(for: id.uuidString, kind: .volume) == 7)
    }

    @Test("A clone source drives the create of a volume the host lacks")
    func cloneSourceDrivesCreate() async {
        let id = UUID()
        let actuator = MockVolumeActuator()
        let reconciler = Self.reconciler(actuator)

        await reconciler.apply(
            Self.sync(volumes: [Self.desired(id, source: .clone(from: UUID()))]),
            includeVolumes: true)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await actuator.performed.map(\.step) == [.create])
    }

    // MARK: - Permanent vs transient failures

    @Test("A shrink and an unknown format are permanent, a missing dependency is not")
    func failureClassifications() {
        #expect(VolumeConvergenceError.unsupported("shrink").failureClassification == .permanent)
        #expect(
            VolumeConvergenceError.sourceNotReady("vm not here").failureClassification
                == .waitingOnDependency)
    }

    // MARK: - Lanes

    /// An attachment item holds the volume's lane *and* the VM's, reproducing
    /// what `MessageEnvelope.serializationKeys` gave the imperative
    /// `volume_attach` frame. Without the VM lane, a hot-plug could race that
    /// VM's own create or delete.
    @Test("An attachment item holds both the volume and the VM lane")
    func attachmentItemHoldsTwoLanes() {
        let id = UUID()
        let vmId = UUID()
        let item = ReconcileWorkItem(
            kind: .volume, id: id.uuidString, generation: 1, steps: [.attach],
            target: .volume(
                Self.desired(id, attachment: DesiredVolumeAttachment(vmId: vmId, deviceName: "disk1"))))
        #expect(item.laneKeys == ["volume/" + id.uuidString, vmId.uuidString])
    }

    @Test("A data-plane item holds only the volume lane")
    func dataPlaneItemHoldsOneLane() {
        let id = UUID()
        let item = ReconcileWorkItem(
            kind: .volume, id: id.uuidString, generation: 1, steps: [.create],
            target: .volume(Self.desired(id)))
        #expect(item.laneKeys == ["volume/" + id.uuidString])
    }

    // MARK: - The asymmetric-absence guard

    /// The headline safety property of the whole conversion. A control plane
    /// that says nothing about volumes — one below wire v31, or one mid-rollback
    /// — must leave every volume on the host exactly where it is. Planning
    /// against an empty desired list instead would report all of them as
    /// unaccounted for and invite a future reading of that silence as teardown.
    @Test("A sync with no volumes field touches nothing and reports nothing")
    func nilVolumesFieldIsNotAnEmptyDesiredList() async {
        let id = UUID()
        let actuator = MockVolumeActuator(volumes: [id.uuidString: .managed(Self.facts())])
        let reconciler = Self.reconciler(actuator)

        await reconciler.apply(Self.sync(volumes: nil), includeVolumes: true)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await actuator.performed.isEmpty)
        #expect(await actuator.volumes.count == 1)
        #expect(await reconciler.unrecognizedWorkloads().isEmpty)
    }

    /// The version gate is belt to the field's braces: even a payload that
    /// *does* carry volumes is ignored when the sender is too old to have meant
    /// it, matching how the sandbox half is gated.
    @Test("A pre-v31 sender's volumes are ignored even when present")
    func versionGateSuppressesTheVolumeHalf() async {
        let id = UUID()
        let actuator = MockVolumeActuator(volumes: [id.uuidString: .managed(Self.facts())])
        let reconciler = Self.reconciler(actuator)

        await reconciler.apply(
            Self.sync(volumes: [Self.desired(id, status: .absent, generation: 9)]),
            includeVolumes: false)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await actuator.performed.isEmpty)
        #expect(await actuator.volumes.count == 1)
    }

    /// An agent that cannot read its own workload manifest converges no volumes
    /// either (STR-138 ∩ STR-148), even though the storage backend can still
    /// enumerate them: the *attachment* half of a volume's observation rides
    /// the VM manifest, so a blind host would report every volume detached and
    /// plan an attach against a guest that already has it.
    @Test("A blind host converges no volumes")
    func blindHostConvergesNoVolumes() async {
        let id = UUID()
        let actuator = MockVolumeActuator()
        await actuator.setPresenceComplete(false)
        let reconciler = Self.reconciler(actuator)

        await reconciler.apply(Self.sync(volumes: [Self.desired(id)]), includeVolumes: true)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await actuator.performed.isEmpty)
    }

    /// The counterpart to the nil-`volumes`-field test, on the agent's own
    /// side: a host that cannot *read* its volume store must not report an
    /// empty inventory, because an empty inventory is authoritative — it would
    /// make this sync plan a create for every volume the control plane wants
    /// here, over bytes that are almost certainly still on disk.
    @Test("A host that cannot enumerate its volume store converges nothing")
    func unreadableStoreConvergesNothing() async {
        let id = UUID()
        let actuator = MockVolumeActuator()
        await actuator.setInventoryReadable(false)
        let reconciler = Self.reconciler(actuator)

        await reconciler.apply(Self.sync(volumes: [Self.desired(id)]), includeVolumes: true)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await actuator.performed.isEmpty)
        #expect(await reconciler.unrecognizedWorkloads().isEmpty)
    }

    /// A volume with no desired attachment but a leftover observed slot must
    /// plan nothing, not an `.attach` with nothing to attach to — which the
    /// actuator answers with a *permanent* failure.
    @Test("A detached volume with a stale device name plans nothing")
    func staleDeviceNameWithNoDesiredAttachmentPlansNothing() {
        let observed = Self.facts(attachedVMId: nil, deviceName: "disk1")
        #expect(Reconciler.volumeSteps(desired: Self.desired(UUID()), observed: observed).isEmpty)
    }

    @Test("A volume attached with no desired attachment is detached")
    func unwantedAttachmentIsDetached() {
        let observed = Self.facts(attachedVMId: UUID().uuidString, deviceName: "disk1")
        #expect(Reconciler.volumeSteps(desired: Self.desired(UUID()), observed: observed) == [.detach])
    }

    // MARK: - The blast-radius guard is per kind

    /// One pooled denominator would let a volume-dense host's volume count
    /// dilute the bound protecting its guests: 4 VMs among 40 volumes would
    /// pass at `400 > 1100` where the VM-only denominator refuses at
    /// `400 > 100`.
    @Test("Volumes do not dilute the teardown guard protecting VMs")
    func teardownGuardIsEvaluatedPerKind() async {
        let vmIds = (0..<4).map { _ in UUID() }
        let volumeIds = (0..<40).map { _ in UUID() }

        let actuator = MockGuardActuator(
            vms: Dictionary(uniqueKeysWithValues: vmIds.map { ($0.uuidString, VMPresence.managed(.running)) }),
            volumes: Dictionary(
                uniqueKeysWithValues: volumeIds.map { ($0.uuidString, VolumePresence.managed(Self.facts())) }))
        let reconciler = Reconciler(
            actuator: actuator, queue: SerialTaskQueue(), logger: Logger(label: "test"))

        let sync = DesiredStateMessage(
            vms: [],
            tombstones: vmIds.map { DesiredWorkloadTombstone(kind: .vm, workloadId: $0, generation: 1) },
            volumes: [])
        await reconciler.apply(sync, includeVolumes: true)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await actuator.performed.isEmpty)
        let refusal = await reconciler.lastTeardownRefusal()
        #expect(refusal != nil)
        #expect(refusal?.requestedTeardowns == 4)
        // The denominator is the VM population, not the whole host.
        #expect(refusal?.presentWorkloads == 4)
    }

    /// A kind that passes its own guard still converges, for the same reason
    /// the guard never stops boots and creates.
    @Test("A refused kind does not block a kind that passed")
    func onlyTheRefusedKindLosesItsTeardowns() async {
        let vmIds = (0..<4).map { _ in UUID() }
        let volumeIds = (0..<40).map { _ in UUID() }
        let doomedVolume = volumeIds[0]

        let actuator = MockGuardActuator(
            vms: Dictionary(uniqueKeysWithValues: vmIds.map { ($0.uuidString, VMPresence.managed(.running)) }),
            volumes: Dictionary(
                uniqueKeysWithValues: volumeIds.map { ($0.uuidString, VolumePresence.managed(Self.facts())) }))
        let reconciler = Reconciler(
            actuator: actuator, queue: SerialTaskQueue(), logger: Logger(label: "test"))

        let sync = DesiredStateMessage(
            vms: [],
            tombstones: vmIds.map { DesiredWorkloadTombstone(kind: .vm, workloadId: $0, generation: 1) }
                + [DesiredWorkloadTombstone(kind: .volume, workloadId: doomedVolume, generation: 1)],
            volumes: [])
        await reconciler.apply(sync, includeVolumes: true)
        try? await Task.sleep(for: .milliseconds(50))

        // One volume out of forty is well inside the guard; the four VMs are not.
        let performed = await actuator.performed
        #expect(performed.map(\.id) == [doomedVolume.uuidString])
    }

    /// Actuator double that holds both VMs and volumes, for the guard's
    /// per-kind denominators.
    private actor MockGuardActuator: ReconcileActuator {
        var vms: [String: VMPresence]
        var volumes: [String: VolumePresence]
        private(set) var performed: [(step: ReconcileStep, id: String)] = []

        init(vms: [String: VMPresence], volumes: [String: VolumePresence]) {
            self.vms = vms
            self.volumes = volumes
        }

        func observedPresence() -> [String: VMPresence] { vms }
        func observedVolumePresence() -> [String: VolumePresence]? { volumes }
        func adoptVM(_ item: ReconcileWorkItem) throws -> VMStatus { .running }
        func perform(_ step: ReconcileStep, item: ReconcileWorkItem) throws {
            performed.append((step, item.id))
        }
        func convergenceDidChange() {}
    }

    // MARK: - End to end through the actor

    @Test("A create converges and advances the applied generation")
    func createConverges() async {
        let id = UUID()
        let actuator = MockVolumeActuator()
        let reconciler = Self.reconciler(actuator)

        await reconciler.apply(Self.sync(volumes: [Self.desired(id)]), includeVolumes: true)
        try? await Task.sleep(for: .milliseconds(100))

        #expect(await actuator.performed.map(\.step) == [.create])
        #expect(await reconciler.observedGeneration(for: id.uuidString, kind: .volume) == 1)
        #expect(await reconciler.lastError(for: id.uuidString, kind: .volume) == nil)
    }

    /// Generations are namespaced by kind, so a VM and a volume that happen to
    /// share a UUID never share bookkeeping.
    @Test("Volume generations are tracked separately from VM generations")
    func generationsAreNamespacedByKind() async {
        let id = UUID()
        let actuator = MockVolumeActuator()
        let reconciler = Self.reconciler(actuator)

        await reconciler.apply(
            Self.sync(volumes: [Self.desired(id, generation: 3)]), includeVolumes: true)
        try? await Task.sleep(for: .milliseconds(100))

        #expect(await reconciler.observedGeneration(for: id.uuidString, kind: .volume) == 3)
        #expect(await reconciler.observedGeneration(for: id.uuidString, kind: .vm) == 0)
    }
}
