import Foundation
import StratoShared

// MARK: - Observed presence

/// What this agent knows about one workload when a sync arrives.
public enum WorkloadPresence<Status: Equatable & Sendable>: Equatable, Sendable {
    /// Actively managed by a runtime/hypervisor service, with its last
    /// observed status.
    case managed(Status)
    /// Recorded in the manifest by a previous incarnation of the agent; its
    /// backing process may still be running but is not attached.
    case orphaned
    /// In the manifest, but in a form this build cannot route to a backend —
    /// an unrecognized hypervisor type, an undecodable spec (STR-138). Enough
    /// is known to say a workload exists under this id, which is enough to
    /// refuse to create it a second time; nothing more can be done to it here.
    case quarantined
}

extension WorkloadPresence {
    /// Whether this host is actively managing the workload — the only presence
    /// an edge nonce can be planned or adopted against (STR-151).
    public var isManaged: Bool {
        if case .managed = self { return true }
        return false
    }
}

extension WorkloadKind {
    /// Whether workloads of this kind carry edge nonces (STR-151). Volumes and
    /// snapshot artifacts are bytes: no run state, so no edges, so no record —
    /// and the planner must not owe them one, or it would emit an adoption item
    /// for them on every sync forever.
    var carriesEdgeNonces: Bool {
        switch self {
        case .vm, .sandbox: return true
        case .volume, .volumeSnapshot, .vmCheckpoint, .sandboxSnapshot: return false
        }
    }
}

public typealias VMPresence = WorkloadPresence<VMStatus>
public typealias SandboxPresence = WorkloadPresence<SandboxStatus>
public typealias VolumePresence = WorkloadPresence<ObservedVolumeFacts>
public typealias SnapshotPresence = WorkloadPresence<ObservedSnapshotArtifact>

/// What this agent can see about one snapshot artifact it holds (STR-150), and
/// the `ObservedStatus` the generic diff engine converges.
///
/// A struct rather than a status enum for `ObservedVolumeFacts`' reason,
/// sharpened: an artifact is frozen bytes, so it has no run state at all. The
/// only thing about it that can diverge from desire is *where it exists* — on
/// this host, and optionally in the control plane's object store.
///
/// Entries are always `.managed`: an artifact has no runtime session to lose,
/// so it is never orphaned and never re-adopted.
public struct ObservedSnapshotArtifact: Equatable, Sendable {
    public let kind: SnapshotArtifactKind
    public let parentId: UUID
    /// What the capture produced, as measured when it happened. Nil for an
    /// artifact the agent knows the identity of but has not finished writing.
    public let facts: ObservedSnapshotFacts?
    /// Whether this host has already streamed the artifact to its export slots.
    public let exported: Bool

    public init(
        kind: SnapshotArtifactKind,
        parentId: UUID,
        facts: ObservedSnapshotFacts? = nil,
        exported: Bool = false
    ) {
        self.kind = kind
        self.parentId = parentId
        self.facts = facts
        self.exported = exported
    }
}

/// What this agent can see about one volume it holds, and the `ObservedStatus`
/// the generic diff engine converges (STR-148).
///
/// A struct rather than a status enum because a volume has no run state: the
/// facts that can diverge from desire are where its bytes are, how big they
/// are, and what it is plugged into. `sizeBytes` is the *virtual* size the
/// backend last reported, nil when the agent has not probed it — a nil never
/// plans a resize, so an unprobeable volume is left alone rather than
/// repeatedly grown.
public struct ObservedVolumeFacts: Equatable, Sendable {
    public let attachment: DiskAttachment
    public let sizeBytes: Int64?
    /// Canonical uppercase UUID string of the VM this volume is attached to,
    /// from the agent's durable attachment record.
    public let attachedVMId: String?
    public let deviceName: String?

    public init(
        attachment: DiskAttachment,
        sizeBytes: Int64? = nil,
        attachedVMId: String? = nil,
        deviceName: String? = nil
    ) {
        self.attachment = attachment
        self.sizeBytes = sizeBytes
        self.attachedVMId = attachedVMId
        self.deviceName = deviceName
    }
}

/// The boot-time dependency a VM has on its canonical managed root volume
/// (STR-242).
///
/// Volume and VM convergence use separate work items, so queue order alone is
/// not a proof that a successful volume step actually produced the bytes the VM
/// is about to open. This check is deliberately over the storage inventory the
/// agent just measured and its durable attachment record. A missing, unreadable,
/// undersized, or not-yet-attached root disk is a dependency wait: the periodic
/// level-triggered sync retries the boot after volume convergence changes, with
/// no new VM mutation and no attempt burned.
public enum VMBootVolumeDependency {
    /// Returns why `spec` is not safe to boot, or nil once its one canonical
    /// boot volume is present, attached to `vmId`, and at the admitted desired
    /// virtual size. The control plane normalizes a larger source image and
    /// reserves its excess before sending the new desired size, so equality is
    /// also the proof that materialized-size admission completed.
    public static func pendingReason(
        vmId: String,
        spec: VMSpec,
        desiredVolumes: [String: DesiredVolumeState],
        observedVolumes: [String: ObservedVolumeFacts]
    ) -> String? {
        let bootVolumes = spec.volumes.filter { $0.bootOrder == 0 }
        guard bootVolumes.count == 1, let bootVolume = bootVolumes.first else {
            return "VM \(vmId) does not have exactly one canonical managed boot volume"
        }

        let volumeId = bootVolume.volumeId.uuidString
        guard let desiredVolume = desiredVolumes[volumeId], desiredVolume.desiredStatus == .present else {
            return "managed boot volume \(volumeId) for VM \(vmId) has no present desired state"
        }
        let requestedSize = desiredVolume.sizeBytes
        guard let observed = observedVolumes[volumeId] else {
            return "managed boot volume \(volumeId) for VM \(vmId) is not present on this agent yet"
        }
        guard let observedSize = observed.sizeBytes else {
            return "managed boot volume \(volumeId) for VM \(vmId) has no readable virtual size yet"
        }
        guard observedSize == requestedSize else {
            return
                "managed boot volume \(volumeId) for VM \(vmId) is \(observedSize) bytes; waiting for the admitted \(requestedSize) bytes"
        }
        guard observed.attachedVMId == vmId, observed.deviceName == bootVolume.deviceName.rawValue else {
            return
                "managed boot volume \(volumeId) is not yet attached to VM \(vmId) as \(bootVolume.deviceName.rawValue)"
        }
        return nil
    }
}

/// The sizing a VM on this host is actually running with, as opposed to the
/// sizing its desired spec asks for. Only the dimensions that can move on a
/// live guest: the two hot-addable ones (issue #568) plus its balloon target
/// (issue #567 phase 2) — everything else in a spec still needs a recreate.
public struct VMSizing: Equatable, Sendable {
    public let cpus: Int
    public let memoryBytes: Int64
    /// The balloon target last applied to this VM, or nil when none has been
    /// (the balloon is deflated and the guest holds its whole grant).
    public let balloonTargetBytes: Int64?

    public init(cpus: Int, memoryBytes: Int64, balloonTargetBytes: Int64? = nil) {
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.balloonTargetBytes = balloonTargetBytes
    }

    /// Whether `spec` asks for a different size than this.
    public func differs(from spec: VMSpec) -> Bool {
        cpus != spec.cpus || memoryBytes != spec.memoryBytes
            || balloonTargetBytes != spec.balloonTargetBytes
    }
}

// MARK: - Work items

/// A single convergence action. Items are executed in order within one
/// `ReconcileWorkItem`; the steps after `.adopt` are recomputed from the
/// adopted workload's actual status, which is unknowable until the runtime
/// session is reconnected.
///
/// Sandboxes use a subset of the vocabulary (create/adopt/boot/shutdown/
/// delete): there is no pause/resume for sandboxes in v1, and the planner
/// never emits those steps for sandbox items.
public enum ReconcileStep: Equatable, Sendable {
    /// Materialize disks/rootfs and define the workload (ends "exists, not
    /// running").
    case create
    /// Reconnect an orphan's runtime session and move it back to managed.
    case adopt
    case boot
    case pause
    case resume
    /// Converge a VM's vCPU/memory sizing on the desired spec (issue #568), or
    /// grow a volume to its desired size (STR-148). A stopped QEMU VM also uses
    /// this step to persist a vCPU shrink before its next boot (STR-248).
    /// Sandboxes are not resizable in place.
    case resize
    /// Reconcile a managed QEMU VM's durable NIC set with its desired spec
    /// (STR-202), or replace a Firecracker VMM whose immutable MMDS interface
    /// allow-list changed (STR-67). Creation realizes either initial set.
    case reconfigureNetworks
    case shutdown
    /// Gracefully stop (best effort) and remove the workload from this host.
    case delete
    /// Present a volume to its desired VM (STR-148). Volume-only.
    case attach
    /// Remove a volume from the VM it is presented to (STR-148). Volume-only.
    case detach
    /// Stream a snapshot artifact to the export slots its desired entry names
    /// (STR-150). Snapshot-only, and idempotent at the "already satisfied"
    /// level like every other step: an artifact this host has already exported
    /// plans nothing.
    case export
    /// Restart a running VM in place (STR-151). VM-only, and the one step here
    /// that is not idempotent at the "already satisfied" level — a reboot is an
    /// *edge*, so re-driving it is a second disruption rather than a no-op.
    /// What makes it safe to plan from a level-triggered sync is the nonce, not
    /// the step: it is emitted only while the desired `rebootGeneration`
    /// outranks the one this host durably recorded.
    case reboot
    /// Load a checkpoint back over an existing workload (STR-151), guarded by
    /// its own nonce for `.reboot`'s reason and more sharply: re-driving a
    /// restore rewinds a guest that has been writing since the last one.
    case restore
}

/// Projects the v40 interface identity carried by a durable VM manifest.
/// A partial identity set is not authoritative: legacy manifests are hydrated
/// by MAC during reconciliation, and reporting their missing ids as an empty
/// applied set before that pass would make the control plane reap live NICs.
public enum AppliedNetworkInterfaceInventory {
    public static func ids(in networks: [NetworkSpec]) -> [UUID]? {
        var ids: [UUID] = []
        ids.reserveCapacity(networks.count)
        for network in networks {
            guard let id = network.interfaceId else { return nil }
            ids.append(id)
        }
        return ids
    }
}

/// Matches desired NICs to the agent's durable manifest without relying on
/// compact array positions. Stable ids win, legacy manifests hydrate by MAC,
/// and position is only a fallback when one side has no usable identity.
public struct VMNetworkInterfaceDiff: Equatable, Sendable {
    public let added: [Int]
    public let removed: [Int]

    public static func between(
        current: [NetworkSpec], desired: [NetworkSpec]
    ) -> VMNetworkInterfaceDiff {
        var unusedCurrent = Set(current.indices)
        var added: [Int] = []

        for desiredIndex in desired.indices {
            let candidate = desired[desiredIndex]
            let match = unusedCurrent.first { currentIndex in
                let existing = current[currentIndex]
                if let desiredID = candidate.interfaceId, let existingID = existing.interfaceId {
                    return desiredID == existingID
                }
                if let desiredMAC = candidate.macAddress, let existingMAC = existing.macAddress {
                    return desiredMAC.caseInsensitiveCompare(existingMAC) == .orderedSame
                }
                return desiredIndex == currentIndex
                    && (existing.interfaceId == nil && existing.macAddress == nil
                        || candidate.interfaceId == nil && candidate.macAddress == nil)
            }
            if let match {
                unusedCurrent.remove(match)
            } else {
                added.append(desiredIndex)
            }
        }

        return VMNetworkInterfaceDiff(
            added: added.sorted(), removed: unusedCurrent.sorted())
    }
}

// MARK: - Edge nonces (STR-151)

/// The edge nonces one workload's desired entry asks for (ADR 0001 stage 9,
/// STR-151). Kinds with no edges — volumes, snapshot artifacts — carry `.none`.
public struct DesiredEdges: Equatable, Sendable {
    public let rebootGeneration: Int64?
    public let restore: DesiredRestore?

    public static let none = DesiredEdges(rebootGeneration: nil, restore: nil)

    public init(rebootGeneration: Int64? = nil, restore: DesiredRestore? = nil) {
        self.rebootGeneration = rebootGeneration
        self.restore = restore
    }
}

/// The edge nonces this host has already applied for one workload, read from —
/// and written back to — the durable workload manifest.
///
/// **Nil is not zero, and the difference is the whole safety property.** A
/// `nil` *record* (no `AppliedEdgeNonces` at all for a workload) means this
/// agent has no memory of what it has applied: a manifest written by a build
/// that predates this field, or a workload it has never converged. Reading that
/// as "applied nothing" would make a re-registered agent replay every reboot and
/// restore in the workload's history — rewinding a live guest to a checkpoint
/// from weeks ago. So a missing record is *adopted*: the desired nonces are
/// written down as applied and nothing is performed.
///
/// A nil *member* inside a present record is different and does mean zero: the
/// control plane has never asked for that edge, so the first request outranks it.
public struct AppliedEdgeNonces: Codable, Equatable, Sendable {
    public let reboot: Int64?
    public let restore: Int64?

    public init(reboot: Int64? = nil, restore: Int64? = nil) {
        self.reboot = reboot
        self.restore = restore
    }

    /// The record left by converging a workload on `edges` — every edge that
    /// entry asks for, consumed.
    public init(applying edges: DesiredEdges) {
        self.reboot = edges.rebootGeneration
        self.restore = edges.restore?.generation
    }
}

/// The control-plane instruction driving a work item, tagged by workload kind.
///
/// Every item has one: there is no "the control plane said nothing about this"
/// case. Teardown of a workload no row describes arrives as an explicit
/// `.tombstone` (STR-98), not as an absence.
public enum ReconcileTarget: Sendable {
    case vm(DesiredVMState)
    case sandbox(DesiredSandboxState)
    case volume(DesiredVolumeState)
    /// A snapshot artifact of any family — the entry's own `kind` routes the
    /// capture or delete to a backend (STR-150).
    case snapshot(DesiredSnapshotState)
    /// Confirmed teardown of a workload the control plane has no row for.
    case tombstone(DesiredWorkloadTombstone)
}

/// The planned convergence for one workload out of one sync.
public struct ReconcileWorkItem: Sendable {
    public let kind: WorkloadKind
    /// Canonical (uppercase) UUID string, matching the manifest keys.
    public let id: String
    /// The desired-state generation this item converges toward — a tombstone's
    /// generation for a confirmed teardown, otherwise the desired entry's.
    public let generation: Int64
    public let steps: [ReconcileStep]
    /// What the control plane asked for.
    public let target: ReconcileTarget
    /// What this host will have applied for the workload's edges once this item
    /// completes (STR-151), or nil when there is nothing to record.
    ///
    /// Decided by the *planner*, which is the only place that knows all three
    /// inputs — the entry's nonces, the existing record, and which edges it
    /// actually planned — and carried here so the actuator only has to persist
    /// it. Nil for a volume or artifact (no edges), for an item that adopted an
    /// orphan (its state was unknown until the runtime reconnected, so its edges
    /// belong to the next sync) and for one that deleted the workload (there is
    /// no entry left to record against).
    public let appliedEdges: AppliedEdgeNonces?

    /// The VM desired entry, when this is a VM-kind item driven by one.
    public var desired: DesiredVMState? {
        if case .vm(let entry) = target { return entry }
        return nil
    }

    /// The sandbox desired entry, when this is a sandbox-kind item driven by
    /// one.
    public var desiredSandbox: DesiredSandboxState? {
        if case .sandbox(let entry) = target { return entry }
        return nil
    }

    /// The volume desired entry, when this is a volume-kind item driven by one.
    public var desiredVolume: DesiredVolumeState? {
        if case .volume(let entry) = target { return entry }
        return nil
    }

    /// The snapshot desired entry, when this item is driven by one (STR-150).
    public var desiredSnapshot: DesiredSnapshotState? {
        if case .snapshot(let entry) = target { return entry }
        return nil
    }

    /// Whether this item is a confirmed teardown of a workload with no
    /// control-plane row. These are the only items the blast-radius guard
    /// counts, and the only ones exempt from retry suppression and backoff.
    public var isTombstone: Bool {
        if case .tombstone = target { return true }
        return false
    }

    /// Every serial lane this item must hold while it runs. VM items key on
    /// the bare VM id, so two items can never interleave operations on one VM;
    /// sandbox and volume items get their own namespaces ("sandbox/" and
    /// "volume/" cannot collide with a UUID string).
    ///
    /// A volume item that carries an attachment also holds the *VM's* lane,
    /// because realizing it drives that VM's hypervisor session. A clone create
    /// additionally holds its source volume lane and, when the source is
    /// attached, its source VM lane. That prevents source mutation or a later
    /// VM start from interleaving with the copy.
    ///
    /// A snapshot item holds its own lane plus its **parent's**, for the same
    /// reason (STR-150): capturing a checkpoint pauses the guest and drives the
    /// parent's hypervisor session, so it must never interleave with that
    /// parent's own convergence — a capture racing a delete would checkpoint a
    /// VM out from under its teardown.
    public var laneKeys: [String] {
        switch kind {
        case .vm: return [id]
        case .sandbox: return ["sandbox/" + id]
        case .volume:
            var keys = ["volume/" + id]
            if let sourceVolumeId = desiredVolume?.source?.sourceVolumeId?.uuidString {
                keys.append(Self.lane(kind: .volume, id: sourceVolumeId))
            }
            if let sourceVMId = desiredVolume?.source?.sourceVMId?.uuidString {
                keys.append(sourceVMId)
            }
            if let attachedVMId = desiredVolume?.attachment?.vmId.uuidString {
                keys.append(attachedVMId)
            }
            var unique: [String] = []
            for key in keys where !unique.contains(key) { unique.append(key) }
            return unique
        case .volumeSnapshot, .vmCheckpoint, .sandboxSnapshot:
            let own = "snapshot/" + id
            guard let entry = desiredSnapshot else { return [own] }
            return [own, Self.lane(kind: entry.kind.parentKind, id: entry.parentId.uuidString)]
        }
    }

    /// The lane a workload of `kind` runs on. Kept beside `laneKeys` so a
    /// snapshot naming its parent's lane cannot spell it differently from the
    /// parent itself.
    static func lane(kind: WorkloadKind, id: String) -> String {
        switch kind {
        case .vm: return id
        case .sandbox: return "sandbox/" + id
        case .volume: return "volume/" + id
        case .volumeSnapshot, .vmCheckpoint, .sandboxSnapshot: return "snapshot/" + id
        }
    }

    public init(
        kind: WorkloadKind,
        id: String,
        generation: Int64,
        steps: [ReconcileStep],
        target: ReconcileTarget,
        appliedEdges: AppliedEdgeNonces? = nil
    ) {
        self.kind = kind
        self.id = id
        self.generation = generation
        self.steps = steps
        self.target = target
        self.appliedEdges = appliedEdges
    }
}

// MARK: - Plan output

/// What one sync diffs to: the work to run, plus the workloads this host holds
/// that the sync did not account for (STR-98).
///
/// The second half used to be the first half's `.delete` items. Splitting them
/// is the whole point: the reconciler converges what the control plane asked
/// for and *reports* what it did not mention, instead of reading silence as an
/// instruction.
public struct ReconcilePlan: Sendable {
    public var items: [ReconcileWorkItem]
    public var unrecognized: [UnrecognizedWorkload]

    public init(items: [ReconcileWorkItem] = [], unrecognized: [UnrecognizedWorkload] = []) {
        self.items = items
        self.unrecognized = unrecognized
    }
}

extension Array {
    /// Split into (elements satisfying `predicate`, the rest), preserving order
    /// in both halves.
    func partitioned(_ predicate: (Element) -> Bool) -> ([Element], [Element]) {
        var matching: [Element] = []
        var rest: [Element] = []
        for element in self {
            if predicate(element) {
                matching.append(element)
            } else {
                rest.append(element)
            }
        }
        return (matching, rest)
    }
}

// MARK: - Blast-radius guard

/// How much of a host one sync may tear down (STR-98 phase 2) — defense in
/// depth for the tombstone path itself.
///
/// A legitimate host drain is a rare, operator-initiated event and can afford
/// the override flag; a bug or a stale database cannot afford the fleet. The
/// guard trips only when *both* halves are exceeded, so a small host losing its
/// two stray workloads is unremarkable while a host losing all forty is not.
///
/// Applied per workload *kind*, against that kind's own population — see
/// `Reconciler.applyTeardownGuard`. One pooled denominator would let a
/// volume-dense host's volume count dilute the bound protecting its guests.
///
/// Scoped to tombstoned teardowns on purpose. An explicit `.absent` entry is a
/// per-workload API decision with a `ResourceOperation` row and an audit trail
/// behind it — capping those would refuse an ordinary "delete these twelve
/// VMs" and push operators into leaving the override on permanently, which
/// would disarm the guard for the machine-driven path it exists to bound.
public struct TeardownGuard: Sendable, Equatable {
    public static let defaultMinimumWorkloads = 3
    public static let defaultPercentOfPresent = 25

    /// Absolute floor: this many tombstoned teardowns in one sync are always
    /// allowed, whatever the percentage says.
    public let minimumWorkloads: Int
    /// Percentage of the host's present workloads above which a teardown batch
    /// is refused.
    public let percentOfPresent: Int
    /// Operator override, for a real drain.
    public let allowBulkTeardown: Bool

    public init(
        minimumWorkloads: Int = defaultMinimumWorkloads,
        percentOfPresent: Int = defaultPercentOfPresent,
        allowBulkTeardown: Bool = false
    ) {
        self.minimumWorkloads = max(0, minimumWorkloads)
        self.percentOfPresent = max(0, percentOfPresent)
        self.allowBulkTeardown = allowBulkTeardown
    }

    /// Why this batch is refused, or nil to let it through.
    public func refusal(teardowns: Int, present: Int) -> String? {
        guard !allowBulkTeardown, teardowns > minimumWorkloads else { return nil }
        guard teardowns * 100 > present * percentOfPresent else { return nil }
        return
            "refusing to tear down \(teardowns) of \(present) workloads on this host in one sync: "
            + "more than \(minimumWorkloads) and more than \(percentOfPresent)% of what is present. "
            + "Set allow_bulk_teardown in the agent config to override for a deliberate drain."
    }
}

// MARK: - Actuator

/// Runtime side effects the reconciler needs, implemented by the Agent, which
/// routes VM items to the hypervisor driver registry and sandbox items to the
/// sandbox runtime. Every method must be idempotent at the "already satisfied"
/// level — e.g. creating a workload that exists is a no-op — because
/// level-triggered syncs will re-drive any step whose effect was not yet
/// observed.
public protocol ReconcileActuator: Sendable {
    /// Whether the presence snapshots below are a complete account of this
    /// host (STR-138).
    ///
    /// False means the agent cannot enumerate its own workloads — its durable
    /// manifest could not be read — so an id's absence from `observedPresence`
    /// means "unknown", not "not here". The reconciler converges nothing at
    /// all in that state: creating a workload it cannot rule out already
    /// running would point a second hypervisor process at a live disk image.
    func presenceIsComplete() async -> Bool
    /// Snapshot of every VM present on this host (managed + orphaned).
    func observedPresence() async -> [String: VMPresence]
    /// The sizing each managed VM is actually running with, so the planner
    /// can spot a spec whose vCPU/memory changed under a running VM
    /// (issue #568).
    func observedSizing() async -> [String: VMSizing]
    /// Network specs durably recorded in each managed VM manifest.
    func observedNetworkSpecs() async -> [String: [NetworkSpec]]
    /// Exact immutable MMDS interface allow-list recorded for each managed
    /// Firecracker VM. This includes the per-VM metadata kill switch, which is
    /// not represented by `NetworkSpec` and may change without a VM generation
    /// bump.
    func observedFirecrackerMMDSInterfaces() async -> [String: [String]]
    /// Re-adopt an orphaned VM and return its observed status, so the
    /// reconciler can plan the remaining convergence steps toward the desired
    /// status.
    func adoptVM(_ item: ReconcileWorkItem) async throws -> VMStatus
    /// Snapshot of every sandbox present on this host (managed + orphaned).
    func observedSandboxPresence() async -> [String: SandboxPresence]
    /// Re-adopt an orphaned sandbox and return its observed status.
    func adoptSandbox(_ item: ReconcileWorkItem) async throws -> SandboxStatus
    /// Snapshot of every volume whose data this host holds (STR-148), or nil
    /// when the agent cannot enumerate the store at all.
    ///
    /// Entries are always `.managed`: the storage backend's inventory is the
    /// authority for durable volume data, so there is no hypervisor session to
    /// lose and nothing to re-adopt.
    ///
    /// The Optional is the volume counterpart of `presenceIsComplete` and
    /// exists for the same reason: an empty inventory is *authoritative* to
    /// everything downstream, so a host that cannot read its store must be able
    /// to say so rather than claim it holds nothing. Nil skips the volume half
    /// of the plan and makes the observed report carry `volumes: nil`, which
    /// the control plane already reads as "no opinion".
    func observedVolumePresence() async -> [String: VolumePresence]?
    /// Before volume presence is sampled, adopt any historical VM-side path
    /// that now arrives with a required managed volume identity. This is the
    /// host-state half of the STR-231 database cutover: it must run before the
    /// planner could mistake old bytes for an absent volume and materialize a
    /// fresh image over the guest's history.
    func prepareManagedVolumeInventory(
        from desiredVMs: [DesiredVMState], desiredVolumes: [DesiredVolumeState]
    ) async
    /// Snapshot of every snapshot artifact this host holds (STR-150), across
    /// all three families, or nil when the agent cannot enumerate them.
    ///
    /// Nil is the snapshot counterpart of `presenceIsComplete` and carries the
    /// same instruction: an empty inventory is *authoritative* downstream —
    /// omission from a full list is how the control plane confirms a
    /// checkpoint's bytes are gone and reaps its row — so a host that cannot
    /// read its record file must be able to say it does not know, rather than
    /// claim it holds nothing.
    func observedSnapshotPresence() async -> [String: SnapshotPresence]?
    /// The edge nonces this host has already applied, per workload id (STR-151),
    /// from its durable manifest.
    ///
    /// One map across VMs and sandboxes, like `appliedSnapshotGenerations`
    /// shares one across the three artifact families and for the same reason:
    /// ids are control-plane-minted UUIDs, so one can only ever belong to one
    /// workload, and no kind can read another's record.
    ///
    /// A workload missing from this map has *no record*, which is emphatically
    /// not "has applied nothing" — see `AppliedEdgeNonces`.
    func observedEdgeNonces() async -> [String: AppliedEdgeNonces]
    /// Durably record the edge nonces `item` has applied (STR-151), as its
    /// `appliedEdges` decided at plan time.
    ///
    /// Called once per converged item, including one that planned no work,
    /// because **an edge can be consumed by being superseded as much as by being
    /// performed**: a VM that was asked to reboot and then asked to stop should
    /// end up stopped, not stopped-and-then-surprised-by-a-reboot the next time
    /// it starts. Which edges that covers is not this method's decision — the
    /// planner already made it, and a restore it chose to defer is absent from
    /// `nonces` rather than silently swallowed here.
    ///
    /// Must be cheap when nothing changed: it runs for every converged workload
    /// of every sync.
    func recordAppliedEdges(_ item: ReconcileWorkItem, _ nonces: AppliedEdgeNonces) async
    /// Execute one non-adopt step; `item.kind` selects the runtime.
    func perform(_ step: ReconcileStep, item: ReconcileWorkItem) async throws
    /// Called after every work item finishes (success or failure) so the agent
    /// can push a fresh `ObservedStateReport` to the control plane.
    func convergenceDidChange() async
}

extension ReconcileActuator {
    public func prepareManagedVolumeInventory(
        from _: [DesiredVMState], desiredVolumes _: [DesiredVolumeState]
    ) async {}

    public func observedFirecrackerMMDSInterfaces() async -> [String: [String]] { [:] }
}

/// Why a desired resource could not converge. Every case carries a
/// classification because it decides whether the agent retries, waits for a
/// dependency, or reports a terminal error to the control plane.
public enum ConvergenceError: ClassifiableError, LocalizedError, Sendable {
    /// Something the agent cannot do however many times it is asked: a shrink,
    /// an unknown format, a host with no storage backend. Permanent, so the
    /// retry policy suppresses it and the control plane degrades the volume
    /// with the reason instead of waiting out a completion budget.
    case unsupported(String)
    /// Another resource or topology dependency has not converged yet.
    case sourceNotReady(String)
    /// Refused by a precondition nobody has to mint a new generation to clear:
    /// a grow against a volume whose guest is still running (STR-199). Reported
    /// like `unsupported` — the reason names what to do — but retried on every
    /// sync, so doing it converges the size that was already asked for.
    case blocked(String)

    public var failureClassification: FailureClassification {
        switch self {
        case .unsupported: return .permanent
        case .sourceNotReady: return .waitingOnDependency
        case .blocked: return .blocked
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unsupported(let reason), .sourceNotReady(let reason), .blocked(let reason): return reason
        }
    }
}

// MARK: - Desired-state adapters

/// What the generic diff engine needs from a per-kind desired-state DTO. The
/// engine itself never mentions VMs or sandboxes — these adapters keep one
/// copy of the generation/orphan/full-list logic across kinds.
protocol ReconcilableDesired: Sendable {
    associatedtype ObservedStatus: Equatable & Sendable
    static var workloadKind: WorkloadKind { get }
    /// The observed status a completed `.create` step leaves the workload in,
    /// from which the remaining convergence steps are planned. An instance
    /// requirement, not a static one, because for some kinds it depends on the
    /// entry: a created volume's facts are the size and format *this* entry
    /// asked for.
    var statusAfterCreate: ObservedStatus { get }
    var workloadId: UUID { get }
    var generation: Int64 { get }
    /// True when the entry asks for the workload to not exist on this host.
    var wantsAbsent: Bool { get }
    /// Whether an absent local observation still requires a backend delete.
    /// Most workloads are host-owned, so no observation means there is
    /// nothing left to delete. Shared storage is different: an RBD snapshot
    /// can exist in Ceph while this replacement client has no local record.
    var requiresDeleteWhenUnobserved: Bool { get }
    /// Steps converging `observed` toward this entry's desired status; empty
    /// when the observation already satisfies it.
    func convergenceSteps(from observed: ObservedStatus) -> [ReconcileStep]
    var asTarget: ReconcileTarget { get }
    /// The edge nonces this entry asks for (STR-151); `.none` for kinds that
    /// have no edges, which is what keeps the planner from emitting one for
    /// them.
    var edges: DesiredEdges { get }
    /// Whether this entry wants the workload running. Edges only make sense on
    /// a workload that is meant to be up — both of them end with a live guest —
    /// so an entry that wants it stopped *supersedes* them rather than
    /// deferring them (STR-151).
    var wantsRunning: Bool { get }
    /// The observed status as a wire-friendly string, for the diagnostic half
    /// of an `UnrecognizedWorkload` report.
    static func describe(_ observed: ObservedStatus) -> String
}

extension ReconcilableDesired {
    /// A volume's or an artifact's bytes have no edges to apply, and no run
    /// state to apply them in.
    var edges: DesiredEdges { .none }
    var wantsRunning: Bool { false }
    var requiresDeleteWhenUnobserved: Bool { false }
}

extension DesiredVMState: ReconcilableDesired {
    static var workloadKind: WorkloadKind { .vm }
    var statusAfterCreate: VMStatus { .created }
    var workloadId: UUID { vmId }
    var wantsAbsent: Bool { desiredStatus == .absent }
    func convergenceSteps(from observed: VMStatus) -> [ReconcileStep] {
        Reconciler.statusSteps(desired: desiredStatus, observed: observed)
    }
    var asTarget: ReconcileTarget { .vm(self) }
    var edges: DesiredEdges { DesiredEdges(rebootGeneration: rebootGeneration, restore: restore) }
    var wantsRunning: Bool { desiredStatus == .running }
    static func describe(_ observed: VMStatus) -> String { observed.rawValue }
}

extension DesiredSandboxState: ReconcilableDesired {
    static var workloadKind: WorkloadKind { .sandbox }
    var statusAfterCreate: SandboxStatus { .stopped }
    var workloadId: UUID { sandboxId }
    var wantsAbsent: Bool { desiredStatus == .absent }
    func convergenceSteps(from observed: SandboxStatus) -> [ReconcileStep] {
        Reconciler.sandboxStatusSteps(desired: desiredStatus, observed: observed)
    }
    var asTarget: ReconcileTarget { .sandbox(self) }
    // A sandbox has no reboot nonce: `POST .../restart` is expressed as a fresh
    // desired-running generation, not as an edge (see `SandboxController`).
    var edges: DesiredEdges { DesiredEdges(restore: restore) }
    var wantsRunning: Bool { desiredStatus == .running }
    static func describe(_ observed: SandboxStatus) -> String { observed.rawValue }
}

extension DesiredVolumeState: ReconcilableDesired {
    static var workloadKind: WorkloadKind { .volume }
    var workloadId: UUID { volumeId }
    var wantsAbsent: Bool { desiredStatus == .absent }
    var asTarget: ReconcileTarget { .volume(self) }

    /// A freshly created volume has the size and format this entry asked for
    /// and is attached to nothing, so the only step that can remain after a
    /// `.create` is the attach.
    var statusAfterCreate: ObservedVolumeFacts {
        ObservedVolumeFacts(
            attachment: .file(path: "", format: DiskFormat(rawValue: format) ?? .qcow2),
            sizeBytes: sizeBytes)
    }

    func convergenceSteps(from observed: ObservedVolumeFacts) -> [ReconcileStep] {
        Reconciler.volumeSteps(desired: self, observed: observed)
    }

    static func describe(_ observed: ObservedVolumeFacts) -> String {
        observed.attachedVMId.map { "attached to \($0)" } ?? "detached"
    }
}

// MARK: Snapshot artifacts (STR-150)

/// One artifact family as a *type*.
///
/// The diff engine is generic over a desired-state DTO and reads its
/// `WorkloadKind` statically — one kind per desired list — because that kind
/// namespaces generations, failures, tombstones and the held set. Snapshot
/// artifacts arrive as one mixed list of three kinds, so the list is partitioned
/// by kind and each slice is planned through this phantom parameter. The
/// alternative — making the kind an instance property — would have meant
/// teaching `planCore` to bucket *present* entries by kind too, which it cannot
/// do for an `.orphaned` presence that carries no status. Three empty enums
/// keep the engine untouched.
protocol SnapshotArtifactFamily: Sendable {
    static var artifactKind: SnapshotArtifactKind { get }
}

enum VolumeSnapshotFamily: SnapshotArtifactFamily {
    static var artifactKind: SnapshotArtifactKind { .volumeSnapshot }
}

enum VMCheckpointFamily: SnapshotArtifactFamily {
    static var artifactKind: SnapshotArtifactKind { .vmCheckpoint }
}

enum SandboxSnapshotFamily: SnapshotArtifactFamily {
    static var artifactKind: SnapshotArtifactKind { .sandboxSnapshot }
}

/// A desired snapshot entry viewed as one family's, so `planCore` can plan it.
struct FamilyScopedSnapshot<Family: SnapshotArtifactFamily>: ReconcilableDesired {
    let entry: DesiredSnapshotState

    static var workloadKind: WorkloadKind { Family.artifactKind.workloadKind }
    var workloadId: UUID { entry.snapshotId }
    var generation: Int64 { entry.generation }
    var wantsAbsent: Bool { entry.desiredStatus == .absent }
    var requiresDeleteWhenUnobserved: Bool {
        guard wantsAbsent, Family.artifactKind == .volumeSnapshot,
            case .ceph = entry.volumeStorage
        else { return false }
        return true
    }
    var asTarget: ReconcileTarget { .snapshot(entry) }

    /// A freshly captured artifact exists on this host and nowhere else, so the
    /// only step that can remain after a `.create` is the export.
    var statusAfterCreate: ObservedSnapshotArtifact {
        ObservedSnapshotArtifact(kind: entry.kind, parentId: entry.parentId, exported: false)
    }

    func convergenceSteps(from observed: ObservedSnapshotArtifact) -> [ReconcileStep] {
        Reconciler.snapshotSteps(desired: entry, observed: observed)
    }

    static func describe(_ observed: ObservedSnapshotArtifact) -> String {
        observed.exported ? "present, exported" : "present"
    }
}
