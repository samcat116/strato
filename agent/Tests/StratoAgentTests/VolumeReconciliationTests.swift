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

        /// When set, every `.resize` is refused with it — the shape of the
        /// agent's guard against growing an image a running guest holds open
        /// (STR-199).
        var resizeFailure: Error?

        func setPresenceComplete(_ complete: Bool) { presenceComplete = complete }
        func setInventoryReadable(_ readable: Bool) { inventoryReadable = readable }
        func setResizeFailure(_ error: Error?) { resizeFailure = error }

        func waitForReports(_ count: Int, timeoutMillis: Int = 5000) async -> Int {
            var waited = 0
            while reportCount < count && waited < timeoutMillis {
                try? await Task.sleep(nanoseconds: 5_000_000)
                waited += 5
            }
            return reportCount
        }
        func presenceIsComplete() -> Bool { presenceComplete }
        func observedPresence() -> [String: VMPresence] { [:] }
        func observedSizing() -> [String: VMSizing] { [:] }
        func observedNetworkSpecs() -> [String: [NetworkSpec]] { [:] }
        func adoptVM(_ item: ReconcileWorkItem) throws -> VMStatus { .running }
        func observedSandboxPresence() -> [String: SandboxPresence] { [:] }
        func adoptSandbox(_ item: ReconcileWorkItem) throws -> SandboxStatus {
            throw UnsupportedTestActuation.sandbox
        }
        func observedVolumePresence() -> [String: VolumePresence]? {
            inventoryReadable ? volumes : nil
        }
        func observedSnapshotPresence() -> [String: SnapshotPresence]? { [:] }
        func observedEdgeNonces() -> [String: AppliedEdgeNonces] { [:] }
        func recordAppliedEdges(_ item: ReconcileWorkItem, _ nonces: AppliedEdgeNonces) {}

        func perform(_ step: ReconcileStep, item: ReconcileWorkItem) throws {
            performed.append((step, item.id))
            if step == .resize, let resizeFailure { throw resizeFailure }
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
                        attachedVMId: attachment.vmId.uuidString, deviceName: attachment.deviceName.rawValue))
            case .detach:
                guard case .managed(let current)? = volumes[item.id] else { return }
                volumes[item.id] = .managed(
                    ObservedVolumeFacts(
                        path: current.path, format: current.format, sizeBytes: current.sizeBytes))
            case .delete:
                volumes.removeValue(forKey: item.id)
            case .adopt, .boot, .pause, .resume, .shutdown, .export, .reboot, .restore,
                .reconfigureNetworks:
                break
            }
        }

        func convergenceDidChange() { reportCount += 1 }
    }

    private static func reconciler(_ actuator: MockVolumeActuator) -> Reconciler {
        Reconciler(
            actuator: actuator, queue: SerialTaskQueue(), logger: Logger(label: "test"),
            metadataStore: MetadataStore())
    }

    private static func sync(
        volumes: [DesiredVolumeState], tombstones: [DesiredWorkloadTombstone] = []
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

    /// A size the agent could not probe never grows anything on a guess — but
    /// it must not pass *silently* either. Planning nothing let the item run
    /// with no steps, and an empty run records its generation as applied, so a
    /// resize whose current size was never read reported as converged
    /// (STR-199). It plans `.resize`, which the actuator refuses as blocked.
    @Test("An unprobeable size plans a resize the actuator will refuse")
    func unknownSizePlansARefusableResize() {
        let id = UUID()
        let plan = Reconciler.planVolumes(
            desired: [Self.desired(id, generation: 2, sizeBytes: 20 << 30)],
            present: [id.uuidString: .managed(Self.facts(sizeBytes: nil))],
            lastApplied: [id.uuidString: 1])
        #expect(plan.items.first?.steps == [.resize])
    }

    /// The same rule with nothing outstanding: an unreadable size is unreadable
    /// whether or not anyone asked for a new one, because "it already matches"
    /// is exactly the claim the agent cannot make.
    @Test("An unprobeable size is not reported as a matching size")
    func unknownSizeIsNotTreatedAsMatching() {
        let id = UUID()
        let plan = Reconciler.planVolumes(
            desired: [Self.desired(id, generation: 2)],
            present: [id.uuidString: .managed(Self.facts(sizeBytes: nil))],
            lastApplied: [id.uuidString: 1])
        #expect(plan.items.first?.steps == [.resize])
    }

    /// An unreadable size must not starve the attachment work above it, which
    /// needs no size at all.
    @Test("An unprobeable size still lets an attach be planned")
    func unknownSizeDoesNotStarveAttach() {
        let id = UUID()
        let vmId = UUID()
        let plan = Reconciler.planVolumes(
            desired: [
                Self.desired(
                    id, attachment: DesiredVolumeAttachment(vmId: vmId, deviceName: .disk(1)))
            ],
            present: [id.uuidString: .managed(Self.facts(sizeBytes: nil))],
            lastApplied: [id.uuidString: 1])
        #expect(plan.items.first?.steps == [.attach])
    }

    /// The other half of STR-199's remedy. The grow guard tells an operator to
    /// stop the guest *or detach*, and with `.resize` planned ahead of a desired
    /// removal only the first of those could ever run: the refused resize was
    /// the only step planned, so the detach that would lift the refusal was
    /// never reached. A removal outranks a pending grow for that reason.
    @Test("A desired detach is planned ahead of a pending grow")
    func desiredDetachOutranksAPendingGrow() {
        let id = UUID()
        let vmId = UUID()
        let plan = Reconciler.planVolumes(
            desired: [Self.desired(id, generation: 2, sizeBytes: 20 << 30, attachment: nil)],
            present: [
                id.uuidString: .managed(
                    Self.facts(
                        sizeBytes: 10 << 30, attachedVMId: vmId.uuidString, deviceName: "disk1"))
            ],
            lastApplied: [id.uuidString: 1])
        #expect(plan.items.first?.steps == [.detach])
    }

    /// An attachment that is *moving* keeps the original order: the grow lands
    /// before the slot changes underneath it.
    @Test("A grow still precedes an attachment that is only moving")
    func growStillPrecedesAMovingAttachment() {
        let id = UUID()
        let wanted = UUID()
        let actual = UUID()
        let plan = Reconciler.planVolumes(
            desired: [
                Self.desired(
                    id, generation: 2, sizeBytes: 20 << 30,
                    attachment: DesiredVolumeAttachment(vmId: wanted, deviceName: .disk(1)))
            ],
            present: [
                id.uuidString: .managed(
                    Self.facts(
                        sizeBytes: 10 << 30, attachedVMId: actual.uuidString, deviceName: "disk1"))
            ],
            lastApplied: [id.uuidString: 1])
        #expect(plan.items.first?.steps == [.resize])
    }

    @Test("A volume whose desired attachment is unrealized is attached")
    func detachedVolumeIsAttached() {
        let id = UUID()
        let vmId = UUID()
        let plan = Reconciler.planVolumes(
            desired: [
                Self.desired(
                    id, attachment: DesiredVolumeAttachment(vmId: vmId, deviceName: .disk(1)))
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
                    id, attachment: DesiredVolumeAttachment(vmId: wanted, deviceName: .disk(1)))
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
            Self.sync(volumes: [Self.desired(id, generation: 7, source: .clone(from: sourceId))]))
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
            Self.sync(volumes: [Self.desired(id, source: .clone(from: UUID()))]))
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
        // A refusal whose remedy is "stop the guest" is neither: an operator
        // has to see it, and doing what it says has to work (STR-199).
        #expect(VolumeConvergenceError.blocked("guest is running").failureClassification == .blocked)
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
                Self.desired(id, attachment: DesiredVolumeAttachment(vmId: vmId, deviceName: .disk(1)))))
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

    /// A new boot volume carries both `.create` and `.attach` in one item. It
    /// therefore holds the VM lane even though its first step is data-plane
    /// materialization. Queueing solely by lane count would put that item after
    /// the VM, whose create cannot resolve the volume's local path yet.
    @Test("A new attached boot volume is materialized before its VM")
    func newBootVolumePrecedesVMCreate() async {
        let volumeId = UUID()
        let vmId = UUID()
        let bootVolume = VolumeSpec(
            volumeId: volumeId,
            deviceName: .disk(0),
            storagePath: nil,
            readonly: false,
            bootOrder: 0)
        let vm = DesiredVMState(
            vmId: vmId,
            hypervisorType: .qemu,
            spec: VMSpec(
                cpus: 1,
                memoryBytes: 1 << 30,
                boot: .disk(firmware: nil),
                volumes: [bootVolume]),
            desiredStatus: .running,
            generation: 1)
        let volume = Self.desired(
            volumeId,
            attachment: DesiredVolumeAttachment(vmId: vmId, deviceName: .disk(0)))
        let actuator = MockVolumeActuator()
        let reconciler = Self.reconciler(actuator)

        await reconciler.apply(DesiredStateMessage(vms: [vm], volumes: [volume]))
        _ = await actuator.waitForReports(2)

        let performed = await actuator.performed
        #expect(performed.map(\.step) == [.create, .attach, .create, .boot])
        #expect(
            performed.map(\.id)
                == [volumeId.uuidString, volumeId.uuidString, vmId.uuidString, vmId.uuidString])
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

        await reconciler.apply(Self.sync(volumes: [Self.desired(id)]))
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

        await reconciler.apply(Self.sync(volumes: [Self.desired(id)]))
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
            actuator: actuator, queue: SerialTaskQueue(), logger: Logger(label: "test"),
            metadataStore: MetadataStore())

        let sync = DesiredStateMessage(
            vms: [],
            tombstones: vmIds.map { DesiredWorkloadTombstone(kind: .vm, workloadId: $0, generation: 1) },
            volumes: [])
        await reconciler.apply(sync)
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
            actuator: actuator, queue: SerialTaskQueue(), logger: Logger(label: "test"),
            metadataStore: MetadataStore())

        let sync = DesiredStateMessage(
            vms: [],
            tombstones: vmIds.map { DesiredWorkloadTombstone(kind: .vm, workloadId: $0, generation: 1) }
                + [DesiredWorkloadTombstone(kind: .volume, workloadId: doomedVolume, generation: 1)],
            volumes: [])
        await reconciler.apply(sync)
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

        func presenceIsComplete() -> Bool { true }
        func observedPresence() -> [String: VMPresence] { vms }
        func observedSizing() -> [String: VMSizing] { [:] }
        func observedNetworkSpecs() -> [String: [NetworkSpec]] { [:] }
        func observedVolumePresence() -> [String: VolumePresence]? { volumes }
        func adoptVM(_ item: ReconcileWorkItem) throws -> VMStatus { .running }
        func observedSandboxPresence() -> [String: SandboxPresence] { [:] }
        func adoptSandbox(_ item: ReconcileWorkItem) throws -> SandboxStatus {
            throw UnsupportedTestActuation.sandbox
        }
        func observedSnapshotPresence() -> [String: SnapshotPresence]? { [:] }
        func observedEdgeNonces() -> [String: AppliedEdgeNonces] { [:] }
        func recordAppliedEdges(_ item: ReconcileWorkItem, _ nonces: AppliedEdgeNonces) {}
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

        await reconciler.apply(Self.sync(volumes: [Self.desired(id)]))
        try? await Task.sleep(for: .milliseconds(100))

        #expect(await actuator.performed.map(\.step) == [.create])
        #expect(await reconciler.observedGeneration(for: id.uuidString, kind: .volume) == 1)
        #expect(await reconciler.lastError(for: id.uuidString, kind: .volume) == nil)
    }

    /// The regression behind STR-199. The guard refusing to grow a volume whose
    /// guest is still running names a remedy — stop it, or detach — and while
    /// the refusal was classified permanent, applying that remedy did nothing:
    /// permanent-failure suppression had already engaged, so no
    /// later sync re-drove the grow and the volume sat short of a size nothing
    /// had withdrawn until someone asked for a *different* one.
    @Test("A blocked grow is retried on every sync and converges when the block clears")
    func blockedResizeRetriesUntilTheBlockClears() async {
        let id = UUID()
        let actuator = MockVolumeActuator(
            volumes: [id.uuidString: .managed(Self.facts(sizeBytes: 1 << 30))])
        await actuator.setResizeFailure(
            VolumeConvergenceError.blocked(
                "refusing to grow volume \(id): it is attached to VM x, which is not confirmed "
                    + "shut down, and this agent has no online grow path"))
        let reconciler = Self.reconciler(actuator)
        let message = Self.sync(volumes: [Self.desired(id, generation: 3, sizeBytes: 3 << 30)])

        // Every sync re-drives the refused grow without backoff.
        let rounds = 6
        for round in 1...rounds {
            await reconciler.apply(message)
            _ = await actuator.waitForReports(round)
        }
        #expect(await actuator.performed.map(\.step) == Array(repeating: .resize, count: rounds))
        // And unlike a dependency wait, the reason is reported every time — the
        // thing that lifts this block is a person, and a person who is never
        // told cannot lift it.
        let blockedError = await reconciler.lastError(for: id.uuidString, kind: .volume)
        #expect(blockedError?.contains("not confirmed shut down") == true)
        #expect(await reconciler.observedGeneration(for: id.uuidString, kind: .volume) == 0)

        // The operator stops the guest. The *same* generation converges — the
        // point being that nobody had to re-ask for the size.
        await actuator.setResizeFailure(nil)
        await reconciler.apply(message)
        _ = await actuator.waitForReports(rounds + 1)

        #expect(await reconciler.observedGeneration(for: id.uuidString, kind: .volume) == 3)
        #expect(await reconciler.lastError(for: id.uuidString, kind: .volume) == nil)
    }

    /// The other half of the same rule: a block burning no attempt must not
    /// make every *other* failure unbounded too.
    @Test("A permanent resize failure still stops at the first attempt")
    func permanentResizeStillCapsImmediately() async {
        let id = UUID()
        let actuator = MockVolumeActuator(
            volumes: [id.uuidString: .managed(Self.facts(sizeBytes: 1 << 30))])
        await actuator.setResizeFailure(VolumeConvergenceError.unsupported("no storage backend"))
        let reconciler = Self.reconciler(actuator)
        let message = Self.sync(volumes: [Self.desired(id, generation: 3, sizeBytes: 3 << 30)])

        for _ in 1...5 {
            await reconciler.apply(message)
            _ = await actuator.waitForReports(1)
        }
        try? await Task.sleep(for: .milliseconds(100))

        #expect(await actuator.performed.count == 1)
    }

    /// Generations are namespaced by kind, so a VM and a volume that happen to
    /// share a UUID never share bookkeeping.
    @Test("Volume generations are tracked separately from VM generations")
    func generationsAreNamespacedByKind() async {
        let id = UUID()
        let actuator = MockVolumeActuator()
        let reconciler = Self.reconciler(actuator)

        await reconciler.apply(
            Self.sync(volumes: [Self.desired(id, generation: 3)]))
        try? await Task.sleep(for: .milliseconds(100))

        #expect(await reconciler.observedGeneration(for: id.uuidString, kind: .volume) == 3)
        #expect(await reconciler.observedGeneration(for: id.uuidString, kind: .vm) == 0)
    }
}
