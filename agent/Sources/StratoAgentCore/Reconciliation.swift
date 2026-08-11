import Foundation
import Logging
import StratoShared

// Reconciliation phase 2 (issue #260): the agent-side reconcile loop.
//
// `Reconciler.plan` is the pure diff engine: it compares the control plane's
// authoritative desired set against what is actually present on this host and
// yields per-workload work items. The `Reconciler` actor drives those items
// onto the shared `SerialTaskQueue` lanes and tracks per-workload generations
// so replayed or reordered syncs cannot roll state backward. All runtime side
// effects go through `ReconcileActuator`, implemented by the Agent — this file
// stays free of hypervisor SDKs so the whole engine is unit-testable.
//
// Issue #417 generalized the engine over `WorkloadKind`: the diff, generation
// guard, retry policy, and failure classification are shared between VMs and
// sandboxes (deliberately not forked — two copies would drift); only the step
// vocabulary and the actuator routing differ per kind.
//
// STR-52 hung one more job off the same sync: each VM's `InstanceMetadata` is
// projected onto the `MetadataStore` the guest-facing IMDS reads. It is not
// actuation — no work item carries it — because a VM already in its desired
// status plans no steps, and a metadata-only edit bumps no generation.
//
// STR-98 took omission out of the destructive path. A workload present here
// that a sync does not list is *held* and reported as unrecognized; it is torn
// down only when the control plane answers with an explicit tombstone (or an
// ordinary `.absent` entry). A blast-radius guard bounds how much of a host one
// sync's tombstones may remove.

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
    public let path: String
    public let format: DiskFormat
    public let sizeBytes: Int64?
    /// Canonical uppercase UUID string of the VM this volume is attached to,
    /// from the agent's durable attachment record.
    public let attachedVMId: String?
    public let deviceName: String?

    public init(
        path: String,
        format: DiskFormat,
        sizeBytes: Int64? = nil,
        attachedVMId: String? = nil,
        deviceName: String? = nil
    ) {
        self.path = path
        self.format = format
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
    /// boot volume is present, attached to `vmId`, and exactly the requested
    /// virtual size.
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
                "managed boot volume \(volumeId) for VM \(vmId) is \(observedSize) bytes; waiting for the requested \(requestedSize) bytes"
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
    /// Converge a *running* VM's vCPU/memory sizing on the desired spec
    /// (issue #568), or grow a volume to its desired size (STR-148). Sandboxes
    /// are not resizable in place.
    case resize
    /// Reconcile a managed QEMU VM's durable NIC set with its desired spec
    /// (STR-202). Creation already realizes the complete initial set.
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
    /// Entries are always `.managed`: a volume is a file, so there is no
    /// session to lose and nothing to re-adopt — the storage backend's
    /// directory listing is the whole truth.
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
}

/// Why a volume could not be converged (STR-148). Every case carries a
/// classification rather than being plain errors, because the difference
/// decides whether an operator ever sees them — and, for `blocked`, whether
/// acting on what they see achieves anything.
public enum VolumeConvergenceError: ClassifiableError, LocalizedError, Sendable {
    /// Something the agent cannot do however many times it is asked: a shrink,
    /// an unknown format, a host with no storage backend. Permanent, so the
    /// retry policy suppresses it and the control plane degrades the volume
    /// with the reason instead of waiting out a completion budget.
    case unsupported(String)
    /// Something this volume depends on has not converged yet — its clone
    /// source, or the VM it attaches to, either of which may be mid-flight in
    /// the very same sync. Classified as a dependency wait, so it burns no
    /// attempt, records no error, and simply retries on the next
    /// level-triggered sync.
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

/// Why a snapshot artifact could not be converged (STR-150). Same two
/// classifications as `VolumeConvergenceError`, and for the same reason: the
/// difference decides whether an operator ever sees it.
public enum SnapshotConvergenceError: ClassifiableError, LocalizedError, Sendable {
    /// Something this host cannot do however many times it is asked: export a
    /// family that has no off-node representation, or run a backend it does
    /// not have. Permanent, so the retry policy suppresses it and the control
    /// plane degrades the artifact with the reason instead of waiting out a
    /// completion budget.
    case unsupported(String)
    /// The artifact's *parent* has not converged yet — the volume or VM being
    /// captured may be mid-create in this very sync. A dependency wait: it
    /// burns no attempt, records no error, and retries on the next
    /// level-triggered sync.
    case sourceNotReady(String)

    public var failureClassification: FailureClassification {
        switch self {
        case .unsupported: return .permanent
        case .sourceNotReady: return .waitingOnDependency
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unsupported(let reason), .sourceNotReady(let reason): return reason
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
        ObservedVolumeFacts(path: "", format: DiskFormat(rawValue: format) ?? .qcow2, sizeBytes: sizeBytes)
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

// MARK: - Reconciler

public actor Reconciler {
    /// Backoff after each transient failure at one generation. Once the fourth
    /// attempt fails, the reconciler keeps trying hourly until the workload
    /// converges or a newer generation replaces it.
    static func transientRetryDelay(afterAttempt attempt: Int) -> TimeInterval {
        switch attempt {
        case ...1: 60
        case 2: 5 * 60
        case 3: 15 * 60
        default: 60 * 60
        }
    }

    /// Identity of one workload across the reconciler's bookkeeping: ids only
    /// collide across kinds by UUID accident, but the kind is what routes
    /// actuation, so generations/failures/phases must never be shared between
    /// a VM and a sandbox that happen to reuse an id.
    private struct WorkloadRef: Hashable {
        let kind: WorkloadKind
        let id: String

        init(_ item: ReconcileWorkItem) {
            self.kind = item.kind
            self.id = item.id
        }

        init(kind: WorkloadKind, id: String) {
            self.kind = kind
            self.id = id
        }
    }

    private struct ConvergenceFailure {
        var generation: Int64
        var attempts: Int
        var lastError: String
        var classification: FailureClassification
        var retryNotBefore: Date?
        /// Whether the warning and process-local counter for a terminal
        /// permanent failure have already been emitted for this generation.
        var terminalSuppressionReported = false
        /// How many times a `blocked` item has now re-reported the same reason.
        ///
        /// Blocked items burn no attempt, so `attempts` cannot say how long one
        /// has been stuck — it reads 0 forever. This is what a periodic re-log
        /// counts, so an operator who starts tailing after the first refusal
        /// still learns, at error level, that a volume has been waiting hours
        /// on a guest nobody stopped.
        var blockedRepeats: Int = 0
    }

    private let actuator: any ReconcileActuator
    private let queue: SerialTaskQueue
    private let logger: Logger
    private let teardownGuard: TeardownGuard
    /// What this host's metadata service serves, projected from each sync's
    /// `DesiredVMState.metadata` (STR-52).
    private let metadataStore: MetadataStore
    /// Injectable wall clock for deterministic backoff tests.
    private let now: @Sendable () -> Date

    /// Last generation fully applied per workload. Rejects older syncs (the
    /// generation guard) and feeds `observed_generation` in reports.
    private var lastApplied: [WorkloadRef: Int64] = [:]
    /// Generation currently being converged per workload, so the periodic
    /// sync doesn't stack duplicate work behind a long-running item (e.g. a
    /// multi-GB image download).
    private var inFlight: [WorkloadRef: Int64] = [:]
    /// Human-readable current step per in-flight workload, surfaced as
    /// `convergencePhase` in observed reports.
    private var currentPhase: [WorkloadRef: String] = [:]
    private var failures: [WorkloadRef: ConvergenceFailure] = [:]
    /// Number of permanent failures that have suppressed their first retry.
    /// Process-local by design; it resets when the agent restarts.
    public private(set) var retryCapSuppressions = 0
    /// Workloads this host holds that the last sync neither listed nor
    /// tombstoned, re-derived wholesale on every sync and reported to the
    /// control plane until it decides what they are.
    private var unrecognized: [UnrecognizedWorkload] = []
    /// Set while the most recent sync's teardowns were refused by the
    /// blast-radius guard; cleared by the first sync that passes it.
    private var teardownRefusal: ObservedTeardownRefusal?

    /// `metadataStore` is passed in rather than owned, because the reconciler
    /// only writes it — the guest-facing listener reads the same instance. It
    /// is required rather than defaulted for exactly that reason: a reconciler
    /// handed its own private store would write metadata nobody can serve, and
    /// nothing about that failure is visible from either side.
    public init(
        actuator: any ReconcileActuator,
        queue: SerialTaskQueue,
        logger: Logger,
        teardownGuard: TeardownGuard = TeardownGuard(),
        metadataStore: MetadataStore,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.actuator = actuator
        self.queue = queue
        self.logger = logger
        self.teardownGuard = teardownGuard
        self.metadataStore = metadataStore
        self.now = now
    }

    // MARK: Report accessors

    public func observedGeneration(for id: String, kind: WorkloadKind = .vm) -> Int64 {
        lastApplied[WorkloadRef(kind: kind, id: id)] ?? 0
    }

    public func convergencePhase(for id: String, kind: WorkloadKind = .vm) -> String? {
        currentPhase[WorkloadRef(kind: kind, id: id)]
    }

    public func lastError(for id: String, kind: WorkloadKind = .vm) -> String? {
        failures[WorkloadRef(kind: kind, id: id)]?.lastError
    }

    /// The generation whose convergence produced `lastError(for:kind:)`.
    /// Reported alongside the error so the control plane can tell a failure
    /// of the *current* generation from a stale one still carried on
    /// heartbeats.
    public func failedGeneration(for id: String, kind: WorkloadKind = .vm) -> Int64? {
        failures[WorkloadRef(kind: kind, id: id)]?.generation
    }

    /// Workloads this host holds that the control plane has not accounted for
    /// (STR-98), for the observed-state report. The agent keeps running them
    /// meanwhile; only a tombstone in a later sync removes one.
    public func unrecognizedWorkloads() -> [UnrecognizedWorkload] {
        unrecognized
    }

    /// The blast-radius guard's refusal of the most recent sync's teardowns,
    /// if it tripped, for the observed-state report.
    public func lastTeardownRefusal() -> ObservedTeardownRefusal? {
        teardownRefusal
    }

    /// Workloads of `kind` currently converging that may not exist on their
    /// runtime yet (mid-create), so report assembly can still surface their
    /// progress.
    public func inFlightWorkloads(kind: WorkloadKind) -> [String: Int64] {
        var result: [String: Int64] = [:]
        for (ref, generation) in inFlight where ref.kind == kind {
            result[ref.id] = generation
        }
        return result
    }

    /// Workloads of `kind` whose last convergence attempt failed, with the
    /// failing generation and error. Report assembly includes these even when
    /// the workload has no runtime presence at all (e.g. a create that never
    /// got off the ground) — otherwise the control plane could never learn
    /// why and would wait out the operation's full completion budget.
    public func failedConvergences(kind: WorkloadKind) -> [String: (generation: Int64, error: String)] {
        var result: [String: (generation: Int64, error: String)] = [:]
        for (ref, failure) in failures where ref.kind == kind {
            result[ref.id] = (failure.generation, failure.lastError)
        }
        return result
    }

    // MARK: Applying a sync

    /// Diff a desired-state sync against reality and enqueue the work. Returns
    /// quickly — long convergence actions run on the per-workload lanes.
    ///
    /// Volume and snapshot desired lists are authoritative in the current wire
    /// schema. Local observations remain optional: a backend that cannot
    /// enumerate its store must skip that family rather than treating unknown
    /// presence as empty.
    public func apply(_ message: DesiredStateMessage) async {
        let tombstones = message.tombstones

        // Instance metadata is recorded before anything else this sync does,
        // and deliberately outside the presence guard below: the store is a
        // projection of what the control plane said, not of what this host
        // holds, so an agent that cannot enumerate its own workloads can still
        // serve their guests fresh metadata — which is the fail-static posture
        // the whole IMDS design rests on.
        //
        // It is not carried on a work item either. A VM already in its desired
        // status plans no steps at all, and an edit to what metadata carries
        // (a hostname, an SSH key) changes no realization and so bumps no
        // generation — so routing it through actuation would drop exactly the
        // edits the metadata service exists to deliver.
        await recordMetadata(message.vms)

        // An agent that cannot enumerate its own workloads converges nothing
        // (STR-138). Every item this sync could plan rests on the presence
        // snapshot being an account of the host: absence would read as
        // "create it", and a create against a workload that is in fact still
        // running opens a second writer on its disk image. Refusing to
        // converge is strictly safer than converging against a host we can't
        // see, and it is not silent — the report carries the condition and the
        // host advertises no capacity, so nothing new lands here either.
        //
        // Volumes fall under the same refusal even though their *presence*
        // comes from the storage backend rather than the manifest, and so is
        // readable while it is not (STR-148). Their attachments are not: the
        // agent's record of what is plugged into which VM rides the VM's
        // manifest entry, so a blind host would report every volume detached
        // and plan an attach for each one against a guest that already has it.
        guard await actuator.presenceIsComplete() else {
            logger.error(
                "Ignoring desired-state sync: this host's workloads are unknown, so nothing can be converged against them",
                metadata: [
                    "syncId": .string(message.syncId),
                    "desiredVMs": .stringConvertible(message.vms.count),
                ])
            // Nothing can be held against a host we cannot see, and last
            // sync's held set describes a reality we no longer observe.
            if !unrecognized.isEmpty {
                unrecognized = []
                await actuator.convergenceDidChange()
            }
            return
        }

        await actuator.prepareManagedVolumeInventory(
            from: message.vms, desiredVolumes: message.volumes)

        let presentVMs = await actuator.observedPresence()
        // The durable half of the reconciler's memory (STR-151). `lastApplied`
        // is in-process and resets with the agent, which is exactly right for a
        // generation — an idempotent state converges again for free — and
        // exactly wrong for an edge, which would replay. Read once per sync and
        // shared by both planners.
        let appliedEdges = await actuator.observedEdgeNonces()
        let vmPlan = Self.plan(
            desired: message.vms, present: presentVMs, lastApplied: appliedGenerations(kind: .vm),
            presentSizing: await actuator.observedSizing(), tombstones: tombstones,
            appliedEdges: appliedEdges,
            presentNetworks: await actuator.observedNetworkSpecs())
        var plan = ReconcilePlan(items: [], unrecognized: vmPlan.unrecognized)

        var volumePlan = ReconcilePlan()
        var presentVolumeCount = 0
        // Nil is the storage backend saying it cannot enumerate the store —
        // not that the store is empty. Planning against `[:]` would create
        // every desired volume afresh over bytes that are probably still there.
        if let presentVolumes = await actuator.observedVolumePresence() {
            presentVolumeCount = presentVolumes.count
            volumePlan = Self.planVolumes(
                desired: message.volumes, present: presentVolumes,
                lastApplied: appliedGenerations(kind: .volume), tombstones: tombstones)
            plan.unrecognized += volumePlan.unrecognized
        } else {
            logger.error(
                "Skipping the volume half of this sync: this host cannot enumerate its volume store",
                metadata: [
                    "syncId": .string(message.syncId),
                    "desiredVolumes": .stringConvertible(message.volumes.count),
                ])
        }

        var snapshotPlan = ReconcilePlan()
        var presentSnapshotCounts: [WorkloadKind: Int] = [:]
        // Nil is the record store saying it cannot enumerate what this host
        // holds — not that it holds nothing. Planning against `[:]` would
        // re-capture every desired artifact over bytes that are probably still
        // there.
        if let presentSnapshots = await actuator.observedSnapshotPresence() {
            for presence in presentSnapshots.values {
                guard case .managed(let artifact) = presence else { continue }
                presentSnapshotCounts[artifact.kind.workloadKind, default: 0] += 1
            }
            snapshotPlan = Self.planSnapshots(
                desired: message.snapshots, present: presentSnapshots,
                lastApplied: appliedSnapshotGenerations(), tombstones: tombstones)
            plan.unrecognized += snapshotPlan.unrecognized
        } else {
            logger.error(
                "Skipping the snapshot half of this sync: this host cannot enumerate the artifacts it holds",
                metadata: [
                    "syncId": .string(message.syncId),
                    "desiredSnapshots": .stringConvertible(message.snapshots.count),
                ])
        }

        var presentSandboxCount = 0
        var sandboxPlan = ReconcilePlan()
        do {
            let presentSandboxes = await actuator.observedSandboxPresence()
            presentSandboxCount = presentSandboxes.count
            sandboxPlan = Self.planSandboxes(
                desired: message.sandboxes, present: presentSandboxes,
                lastApplied: appliedGenerations(kind: .sandbox), tombstones: tombstones,
                appliedEdges: appliedEdges)
            plan.unrecognized += sandboxPlan.unrecognized
        }

        // Enqueue order matters even though multi-lane items already give
        // mutual exclusion: holding two lanes guarantees isolation, not
        // sequence. Volume data-plane work goes first so a volume exists before
        // a VM that references it is built. A newly created attached volume is
        // one item (`create`, then `attach`) that already holds the VM lane, so
        // it must join that first group too; otherwise its VM runs first and
        // cannot resolve the volume's local path. A resize of the boot volume
        // for a VM that is about to boot is data-plane work too, even though the
        // volume already carries an attachment and therefore holds the VM lane.
        // It must queue before that boot; putting it with attachment work lets
        // the boot win and makes the grow refuse itself against the now-running
        // guest (STR-242). Other attached resize work remains after VM items so
        // a shutdown requested in the same sync can run first. Remaining
        // attachment work goes there for the same reason: it queues behind that
        // VM's create/boot on the VM's own lane instead of racing it and burning
        // a dependency wait.
        //
        // Snapshot work goes last for the same reason volume attachment does:
        // a capture holds its parent's lane, so enqueuing it after the parent's
        // own items is what makes it queue *behind* that parent's create/boot
        // instead of racing it — and a checkpoint of a guest that is still
        // being built is not a checkpoint of anything.
        let bootingVMIDs = Set(
            vmPlan.items.lazy.filter { $0.steps.contains(.boot) }.map(\.id))
        let bootVolumeIDs = Set(
            message.vms.lazy
                .filter { bootingVMIDs.contains($0.vmId.uuidString) }
                .flatMap { $0.spec.volumes.lazy.filter { $0.bootOrder == 0 }.map(\.volumeId.uuidString) }
        )
        let (volumeData, volumeAttachment) = volumePlan.items.partitioned {
            $0.laneKeys.count == 1 || $0.steps.contains(.create)
                || ($0.steps.contains(.resize) && bootVolumeIDs.contains($0.id))
        }
        plan.items =
            volumeData + vmPlan.items + volumeAttachment + sandboxPlan.items + snapshotPlan.items

        // Wholesale replacement, including the sandbox half's absence when the
        // control plane doesn't speak sandbox sync: the report must describe
        // what *this* sync failed to account for, never an older one's leftovers.
        let heldChanged = unrecognized != plan.unrecognized
        unrecognized = plan.unrecognized
        var items = plan.items
        var population: [WorkloadKind: Int] = [
            .vm: presentVMs.count,
            .sandbox: presentSandboxCount,
            .volume: presentVolumeCount,
        ]
        population.merge(presentSnapshotCounts) { _, new in new }
        let refusalChanged = applyTeardownGuard(
            to: &items, syncId: message.syncId, present: population)

        logger.debug(
            "Applying desired-state sync",
            metadata: [
                "syncId": .string(message.syncId),
                "desiredVMs": .stringConvertible(message.vms.count),
                "presentVMs": .stringConvertible(presentVMs.count),
                "desiredSandboxes": .stringConvertible(message.sandboxes.count),
                "presentSandboxes": .stringConvertible(presentSandboxCount),
                "desiredVolumes": .stringConvertible(message.volumes.count),
                "presentVolumes": .stringConvertible(presentVolumeCount),
                "desiredSnapshots": .stringConvertible(message.snapshots.count),
                "presentSnapshots": .stringConvertible(presentSnapshotCounts.values.reduce(0, +)),
                "unrecognized": .stringConvertible(plan.unrecognized.count),
                "workItems": .stringConvertible(items.count),
            ])
        if !plan.unrecognized.isEmpty {
            logger.warning(
                "Holding workloads the control plane did not account for; awaiting its decision",
                metadata: [
                    "syncId": .string(message.syncId),
                    "count": .stringConvertible(plan.unrecognized.count),
                    "workloadIds": .string(
                        plan.unrecognized.map { "\($0.kind.rawValue):\($0.workloadId.uuidString)" }
                            .joined(separator: ",")),
                ])
        }

        var advancedWithoutWork = false
        for item in items {
            guard shouldExecute(item) else { continue }
            let ref = WorkloadRef(item)

            // Converged-but-newer-generation items (no steps) just advance the
            // applied generation; no need to occupy the workload lane. Their
            // edges are still consumed — an entry that planned no work is the
            // superseded case (a reboot the control plane has since stopped
            // wanting), and leaving the nonce unrecorded is what would fire it
            // weeks later.
            if item.steps.isEmpty {
                lastApplied[ref] = item.generation
                failures.removeValue(forKey: ref)
                if let edges = item.appliedEdges { await actuator.recordAppliedEdges(item, edges) }
                advancedWithoutWork = true
                continue
            }

            inFlight[ref] = item.generation
            currentPhase[ref] = "queued"
            await queue.enqueue(keys: item.laneKeys) { [weak self] in
                await self?.execute(item)
            }
        }

        // Generations that advanced with no runtime work still need a fresh
        // report, or the control plane would wait a full heartbeat interval to
        // learn `observed_generation` caught up (and to complete operations).
        // Newly held workloads and teardown refusals report immediately for the
        // same reason: the held set is one half of a round trip the control
        // plane can only finish once it has seen it.
        if advancedWithoutWork || heldChanged || refusalChanged {
            await actuator.convergenceDidChange()
        }
    }

    /// Drop a sync's tombstoned teardowns when they would take out more of the
    /// host than the guard allows, and record why. Returns whether the recorded
    /// refusal changed, so `apply` can report it right away.
    ///
    /// Everything else in the sync still converges: a guard that also stopped
    /// boots and creates would turn a suspicious teardown batch into a total
    /// convergence outage, which is the failure it exists to prevent.
    /// Evaluated **per kind**, against that kind's own population.
    ///
    /// A single mixed denominator silently dilutes the protection for the kind
    /// that matters most: a host with 4 VMs and 40 volumes would let all 4 VMs
    /// be torn down (`400 > 1100` is false) where the VM-only denominator
    /// refuses it (`400 > 100`). Volumes are cheap and numerous relative to
    /// guests, so the dilution gets worse exactly as hosts get denser. Each
    /// kind is bounded by its own count instead, which is also what the guard's
    /// percentage means to an operator reading it.
    private func applyTeardownGuard(
        to items: inout [ReconcileWorkItem], syncId: String, present: [WorkloadKind: Int]
    ) -> Bool {
        var refusedKinds: Set<WorkloadKind> = []
        var reasons: [String] = []
        var refusedTeardowns = 0
        var refusedPresent = 0

        for kind in WorkloadKind.allCases {
            let teardowns = items.filter { $0.isTombstone && $0.kind == kind }.count
            guard teardowns > 0 else { continue }
            let population = present[kind] ?? 0
            guard let reason = teardownGuard.refusal(teardowns: teardowns, present: population) else {
                continue
            }
            refusedKinds.insert(kind)
            reasons.append("\(kind.rawValue): \(reason)")
            refusedTeardowns += teardowns
            refusedPresent += population
        }

        let previous = teardownRefusal
        guard !refusedKinds.isEmpty else {
            teardownRefusal = nil
            return previous != nil
        }
        // Only the refused kinds lose their teardowns; a kind that passed its
        // own guard still converges, for the same reason the guard never stops
        // boots and creates.
        items.removeAll { $0.isTombstone && refusedKinds.contains($0.kind) }
        let reason = reasons.joined(separator: " ")
        let refusal = ObservedTeardownRefusal(
            syncId: syncId, requestedTeardowns: refusedTeardowns, presentWorkloads: refusedPresent,
            reason: reason)
        teardownRefusal = refusal
        logger.error(
            "Refusing this sync's workload teardowns; blast-radius guard tripped",
            metadata: [
                "syncId": .string(syncId),
                "kinds": .string(refusedKinds.map(\.rawValue).sorted().joined(separator: ",")),
                "requestedTeardowns": .stringConvertible(refusedTeardowns),
                "presentWorkloads": .stringConvertible(refusedPresent),
                "reason": .string(reason),
            ])
        return previous != refusal
    }

    /// Applied generations across all three artifact families in one map.
    /// `planSnapshots` partitions its *desired* list by kind but shares this,
    /// which is safe because ids are UUIDs: an id can only ever belong to one
    /// family, so no two families can read each other's entries.
    private func appliedSnapshotGenerations() -> [String: Int64] {
        var result: [String: Int64] = [:]
        for (ref, generation) in lastApplied where ref.kind.isSnapshotArtifact {
            result[ref.id] = generation
        }
        return result
    }

    /// Project this sync's per-VM metadata onto the store the guest-facing
    /// metadata service reads (STR-52).
    ///
    /// Two rules cover explicit absence and the current desired payload:
    ///
    /// * An entry that wants the VM **absent** withdraws its metadata.
    ///   Having nothing to serve is the safe state for a VM
    ///   leaving this host: the IMDS identifies its caller by source address,
    ///   and an address outlives the VM it was allocated to. This also covers
    ///   the VM that was already gone when the sync arrived, for which the
    ///   planner has no work to do and therefore no teardown to hook — and it
    ///   is why this withdrawal *leads* the VM off the host while the
    ///   tombstoned one trails it. The consequence is deliberate: a VM whose
    ///   delete keeps failing is still running with its metadata already gone,
    ///   which is the safe end of a trade whose other end serves a released
    ///   VM's SSH keys and user data to whoever next holds its address.
    /// * Otherwise the payload is applied as-is. Nil authoritatively withdraws
    ///   metadata for a VM that should remain present.
    ///
    /// Staleness is the store's own guard rather than `lastApplied`, which
    /// tracks convergence and so lags behind: a VM whose create keeps failing
    /// holds `lastApplied` still while generations advance, and every one of
    /// those syncs would look equally current to a guard reading it. A refused
    /// write is logged rather than swallowed — "the metadata the operator
    /// edited never took" is otherwise invisible in a service with no request
    /// log of its own.
    private func recordMetadata(_ desired: [DesiredVMState]) async {
        // Readiness first, and once for the whole sync rather than once per VM
        // (STR-56). A host that legitimately runs no VMs still becomes ready:
        // its listener must be able to answer "I do not serve that address"
        // rather than "I do not know anything yet", and looping over an empty
        // list would never say so.
        await metadataStore.markSyncApplied()
        for entry in desired {
            let outcome: MetadataWriteOutcome
            if entry.wantsAbsent {
                outcome = await metadataStore.withdraw(
                    entry.vmId, generation: entry.generation, because: .desiredAbsent)
            } else {
                outcome = await metadataStore.apply(entry.metadata, generation: entry.generation, for: entry.vmId)
            }
            guard case .stale(let recorded) = outcome else { continue }
            logger.debug(
                "Ignoring stale instance metadata; a newer sync is already recorded for this VM",
                metadata: [
                    "vmId": .string(entry.vmId.uuidString),
                    "generation": .stringConvertible(entry.generation),
                    "recordedGeneration": .stringConvertible(recorded),
                ])
        }

        // Arbitrate what was restored from disk against this authoritative
        // snapshot (STR-56). A VM deleted while this agent was down appears in
        // no sync at all — not even as `wantsAbsent` — so nothing above would
        // ever reach it, and the restored payload would stay servable for the
        // life of the host. Runs after the loop so this sync's own writes have
        // already cleared their records' provisional mark.
        let retired = await metadataStore.confirmRestored(namedBy: Set(desired.map(\.vmId)))
        guard !retired.isEmpty else { return }
        logger.info(
            "Retired restored instance metadata the control plane no longer knows about",
            metadata: [
                "count": .stringConvertible(retired.count),
                "vmIds": .string(retired.map(\.uuidString).joined(separator: ",")),
            ])
    }

    private func appliedGenerations(kind: WorkloadKind) -> [String: Int64] {
        var result: [String: Int64] = [:]
        for (ref, generation) in lastApplied where ref.kind == kind {
            result[ref.id] = generation
        }
        return result
    }

    private func shouldExecute(_ item: ReconcileWorkItem) -> Bool {
        let ref = WorkloadRef(item)
        if let running = inFlight[ref], running >= item.generation {
            // The same (or a newer) generation is already converging; the
            // level-triggered timer will pick up any residual drift afterward.
            return false
        }
        // Tombstoned teardowns bypass both terminal suppression and transient
        // backoff. Their control-plane row is already gone, so retaining the
        // stray until an hourly retry would unnecessarily prolong the leak.
        if var failure = failures[ref], !item.isTombstone,
            failure.generation == item.generation
        {
            let metadata: Logger.Metadata = [
                "kind": .string(item.kind.rawValue),
                "workloadId": .string(item.id),
                "generation": .stringConvertible(item.generation),
                "lastError": .string(failure.lastError),
            ]
            switch failure.classification {
            case .permanent:
                if !failure.terminalSuppressionReported {
                    failure.terminalSuppressionReported = true
                    failures[ref] = failure
                    retryCapSuppressions += 1
                    logger.warning(
                        "Suppressing convergence retry after a permanent failure",
                        metadata: metadata)
                }
                return false
            case .transient:
                if let retryNotBefore = failure.retryNotBefore, now() < retryNotBefore {
                    var backoffMetadata = metadata
                    backoffMetadata["retryNotBefore"] = .stringConvertible(retryNotBefore)
                    logger.debug(
                        "Skipping convergence retry during transient backoff",
                        metadata: backoffMetadata)
                    return false
                }
            case .blocked, .waitingOnDependency:
                break
            }
        }
        return true
    }

    /// Adopt an orphan and return the steps that remain after adoption, which
    /// depend on the orphan's actual state — unknowable before the runtime
    /// session is reconnected.
    private func adoptAndReplan(_ item: ReconcileWorkItem) async throws -> [ReconcileStep] {
        switch item.target {
        case .vm(let desired):
            let observed = try await actuator.adoptVM(item)
            return Self.statusSteps(desired: desired.desiredStatus, observed: observed)
        case .sandbox(let desired):
            let observed = try await actuator.adoptSandbox(item)
            return Self.sandboxStatusSteps(desired: desired.desiredStatus, observed: observed)
        case .volume, .snapshot:
            // Volumes and snapshot artifacts are files: there is no runtime
            // session to lose, so the planner never marks one orphaned and
            // never emits `.adopt`.
            return []
        case .tombstone:
            // The planner never emits `.adopt` for a tombstone (its single
            // step is `.delete`).
            return []
        }
    }

    private func execute(_ item: ReconcileWorkItem) async {
        let ref = WorkloadRef(item)
        do {
            var steps = item.steps
            var index = 0
            while index < steps.count {
                let step = steps[index]
                let phase = phaseDescription(step, kind: item.kind)
                currentPhase[ref] = phase
                if step == .adopt {
                    steps =
                        Array(steps[...index])
                        + (try await watched(phase, item) {
                            try await self.adoptAndReplan(item)
                        })
                } else {
                    try await watched(phase, item) {
                        try await self.actuator.perform(step, item: item)
                    }
                }
                index += 1
            }
            // A VM that just left this host takes its metadata with it
            // (STR-52). The `.absent` entries already withdrew theirs at sync
            // time; what this reaches is the tombstoned teardown, which has no
            // desired entry to carry a withdrawal. Doing it here rather than
            // when the tombstone is planned is what keeps a teardown the
            // blast-radius guard refused from silently blinding a VM this agent
            // deliberately kept running.
            //
            // Reading `.delete` as "the VM is gone" rests on it never sharing
            // an item with the steps that would put it back: every planner site
            // emits `[.delete]` alone, because there is no recreate flow. A
            // future one — say a resize that cannot happen in place planning
            // `delete` then `create` — must withdraw from the delete's own
            // completion instead, or it would blind a VM that is still here,
            // and the withdrawal's seal would hold until the generation moves.
            if item.kind == .vm, item.steps.contains(.delete), let vmId = UUID(uuidString: item.id) {
                await metadataStore.withdraw(vmId, generation: item.generation, because: .tornDown)
            }
            lastApplied[ref] = item.generation
            failures.removeValue(forKey: ref)
            // Every edge this entry asked for has now been applied — performed
            // if it was planned as a step, superseded if it was not. Recorded
            // only after the whole item succeeded, so a failed reboot retries
            // on the next sync instead of being silently swallowed.
            if let edges = item.appliedEdges { await actuator.recordAppliedEdges(item, edges) }
            logger.info(
                "Workload converged to desired state",
                metadata: [
                    "kind": .string(item.kind.rawValue),
                    "workloadId": .string(item.id),
                    "generation": .stringConvertible(item.generation),
                ])
        } catch {
            let classification = (error as? ClassifiableError)?.failureClassification ?? .transient

            // Waiting on another component (e.g. the site network controller
            // hasn't realized this workload's switch in the shared NB yet) is
            // not a failure: recording it would report `lastError` and fail
            // the pending operation on the control plane before the dependency
            // has a chance to land. Record nothing and burn no attempts — the
            // periodic level-triggered sync re-drives the item, and the
            // operation's completion budget backstops a dependency that never
            // arrives.
            if classification == .waitingOnDependency {
                logger.info(
                    "Workload convergence waiting on a dependency; will retry on the next sync",
                    metadata: [
                        "kind": .string(item.kind.rawValue),
                        "workloadId": .string(item.id),
                        "generation": .stringConvertible(item.generation),
                        "waitingOn": .string(error.localizedDescription),
                    ])
                if inFlight[ref] == item.generation {
                    inFlight.removeValue(forKey: ref)
                    currentPhase.removeValue(forKey: ref)
                }
                await actuator.convergenceDidChange()
                return
            }

            var failure =
                failures[ref]
                ?? ConvergenceFailure(
                    generation: item.generation,
                    attempts: 0,
                    lastError: "",
                    classification: classification,
                    retryNotBefore: nil)
            if failure.generation != item.generation {
                failure = ConvergenceFailure(
                    generation: item.generation,
                    attempts: 0,
                    lastError: "",
                    classification: classification,
                    retryNotBefore: nil)
            }
            // A blocked failure burns no attempt (STR-199). It is recorded like
            // any other — the reason names a remedy, and an operator who never
            // sees it cannot apply one — but the precondition it names clears
            // without anyone minting a new generation, so the cap must not be
            // what decides whether the remedy works. Consuming the budget here
            // is exactly how a grow refused against a running guest stayed
            // refused after the guest was stopped.
            if classification != .blocked {
                failure.attempts += 1
            }
            failure.classification = classification
            failure.terminalSuppressionReported = false
            if classification == .transient {
                failure.retryNotBefore = now().addingTimeInterval(
                    Self.transientRetryDelay(afterAttempt: failure.attempts))
            } else {
                failure.retryNotBefore = nil
            }
            let reason = error.localizedDescription
            // A blocked item is re-driven on every sync for as long as the
            // block holds, so an error line per sync would bury the failures
            // that are actually new. It logs on the transition and then every
            // `blockedRelogInterval` repeats after that — often enough that an
            // operator who starts tailing mid-block still sees it at error
            // level, rarely enough to stay readable. Everything else logs each
            // attempt. Transient failures are rate-limited by backoff rather
            // than terminated after a fixed budget.
            let repeating = classification == .blocked && failure.lastError == reason
            failure.blockedRepeats = repeating ? failure.blockedRepeats + 1 : 0
            failure.lastError = reason
            failures[ref] = failure
            var metadata: Logger.Metadata = [
                "kind": .string(item.kind.rawValue),
                "workloadId": .string(item.id),
                "generation": .stringConvertible(item.generation),
                "attempt": .stringConvertible(failure.attempts),
                "error": .string(reason),
            ]
            if classification == .blocked {
                // `attempt` reads 0 for these by design; this is the field that
                // says how long the block has held.
                metadata["blockedRepeats"] = .stringConvertible(failure.blockedRepeats)
            }
            let message = Self.failureLogMessage(classification)
            if repeating, failure.blockedRepeats % Self.blockedRelogInterval != 0 {
                logger.debug(message, metadata: metadata)
            } else {
                logger.error(message, metadata: metadata)
            }
        }
        // Only clear the marker this item owns: a newer-generation item may
        // already be queued behind this one (shouldExecute admits it and
        // apply() re-keyed the entry), and clearing unconditionally would both
        // re-admit duplicate work for that generation and hide a mid-create
        // workload from the observed-state report's in-flight section.
        if inFlight[ref] == item.generation {
            inFlight.removeValue(forKey: ref)
            currentPhase.removeValue(forKey: ref)
        }
        await actuator.convergenceDidChange()
    }

    /// How many repeats of an unchanged `blocked` reason pass between error
    /// lines. Roughly a quarter-hour at the full-refetch floor, sooner when
    /// desired state changes — the point is that a stuck volume keeps saying so
    /// rather than falling silent after its first refusal.
    static let blockedRelogInterval = 20

    /// What a failed convergence says in the log, by classification.
    private static func failureLogMessage(_ classification: FailureClassification) -> Logger.Message {
        switch classification {
        case .permanent:
            return "Workload convergence failed permanently; not retrying this generation (operator action required)"
        case .blocked:
            return "Workload convergence is blocked; retrying every sync until the block clears"
        case .transient, .waitingOnDependency:
            return "Workload convergence failed"
        }
    }

    /// How long a single step may run before the agent starts saying so, and
    /// how often it repeats afterwards. Set above the longest legitimate stage
    /// (a multi-GB image materialization) so a healthy slow create stays quiet.
    private static let watchdogIntervalSeconds = 300

    /// Run one convergence step with a watchdog that logs while it is still
    /// running.
    ///
    /// This does not cancel anything — a step that ignores cancellation would
    /// not stop anyway. It exists so a step that never returns is *visible*.
    /// In issue #516 a step hung indefinitely and the agent went silent: no
    /// timeout, no error, no log line, and the only evidence was the absence of
    /// later messages. A periodic "still running" line makes that self-evident
    /// in the log instead of requiring a thread dump to infer.
    private func watched<T: Sendable>(
        _ phase: String,
        _ item: ReconcileWorkItem,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let logger = self.logger
        let interval = Self.watchdogIntervalSeconds
        // Detached on purpose: a `Task {}` here would inherit this actor's
        // executor, so it could not report a step that wedges the actor —
        // precisely the case it exists for.
        let watchdog = Task.detached {
            var elapsed = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { return }
                elapsed += interval
                logger.warning(
                    "Reconcile step still running",
                    metadata: [
                        "kind": .string(item.kind.rawValue),
                        "workloadId": .string(item.id),
                        "generation": .stringConvertible(item.generation),
                        "phase": .string(phase),
                        "elapsedSeconds": .stringConvertible(elapsed),
                    ])
            }
        }
        defer { watchdog.cancel() }
        return try await operation()
    }

    private func phaseDescription(_ step: ReconcileStep, kind: WorkloadKind) -> String {
        switch step {
        // A snapshot's `.create` is a capture, and the phase string is what an
        // operator reads while it runs — "creating" would describe the wrong
        // thing entirely for a step that pauses a live guest.
        case .create: return kind.isSnapshotArtifact ? "capturing" : "creating"
        case .adopt: return "re-adopting"
        case .boot: return "booting"
        case .pause: return "pausing"
        case .resume: return "resuming"
        case .resize: return "resizing"
        case .reconfigureNetworks: return "reconfiguring network interfaces"
        case .shutdown: return "shutting down"
        case .delete: return "deleting"
        case .attach: return "attaching"
        case .detach: return "detaching"
        case .export: return "exporting"
        case .reboot: return "restarting"
        case .restore: return "restoring"
        }
    }

    // MARK: Pure diff engine

    /// Compute the VM convergence plan for one sync. Pure: no side effects,
    /// fully unit-testable.
    public static func plan(
        desired: [DesiredVMState],
        present: [String: VMPresence],
        lastApplied: [String: Int64],
        presentSizing: [String: VMSizing] = [:],
        tombstones: [DesiredWorkloadTombstone] = [],
        appliedEdges: [String: AppliedEdgeNonces] = [:],
        presentNetworks: [String: [NetworkSpec]] = [:]
    ) -> ReconcilePlan {
        var plan = planCore(
            desired: desired, tombstones: tombstones, present: present, lastApplied: lastApplied,
            appliedEdges: appliedEdges)
        addResizes(
            to: &plan.items, desired: desired, present: present, lastApplied: lastApplied,
            sizing: presentSizing, appliedEdges: appliedEdges)
        addNetworkChanges(
            to: &plan.items, desired: desired, present: present,
            presentNetworks: presentNetworks, appliedEdges: appliedEdges)
        return plan
    }

    private static func addNetworkChanges(
        to items: inout [ReconcileWorkItem],
        desired: [DesiredVMState],
        present: [String: VMPresence],
        presentNetworks: [String: [NetworkSpec]],
        appliedEdges: [String: AppliedEdgeNonces]
    ) {
        for entry in desired where !entry.wantsAbsent && entry.hypervisorType == .qemu {
            let id = entry.vmId.uuidString
            guard case .managed? = present[id],
                let observed = presentNetworks[id],
                observed != entry.spec.networks
            else { continue }

            if let index = items.firstIndex(where: { $0.kind == .vm && $0.id == id }) {
                guard !items[index].steps.contains(.create),
                    !items[index].steps.contains(.delete),
                    !items[index].steps.contains(.adopt)
                else { continue }
                var steps = items[index].steps
                if let shutdown = steps.firstIndex(of: .shutdown) {
                    steps.insert(.reconfigureNetworks, at: shutdown + 1)
                } else if let boot = steps.firstIndex(of: .boot) {
                    steps.insert(.reconfigureNetworks, at: boot)
                } else {
                    steps.insert(.reconfigureNetworks, at: 0)
                }
                items[index] = ReconcileWorkItem(
                    kind: .vm, id: id, generation: entry.generation, steps: steps,
                    target: entry.asTarget, appliedEdges: items[index].appliedEdges)
            } else {
                let steps: [ReconcileStep] = [.reconfigureNetworks]
                items.append(
                    ReconcileWorkItem(
                        kind: .vm, id: id, generation: entry.generation, steps: steps,
                        target: entry.asTarget,
                        appliedEdges: Self.edgesAfter(
                            entry.edges, applied: appliedEdges[id], planning: steps)))
            }
        }
    }

    /// Plans `.resize` for VMs that are already running the status the
    /// control plane wants but at a different size than its spec asks for
    /// (issue #568) — the declarative alternative to an imperative resize
    /// RPC: it survives dropped syncs by construction, since the next
    /// level-triggered sync re-derives the same diff.
    ///
    /// A VM with other steps planned is left alone: `.create` builds the
    /// process from the new spec wholesale, so resizing on top would be
    /// redundant at best. A VM that isn't running is left alone too — but "a
    /// stopped VM picks the new size up at its next boot" is only half the
    /// story, and the missing half is why the equal-generation rule below
    /// exists. `.boot` starts the definition **the host already holds**
    /// (`bootVM` takes no spec; only `.create` writes one), so a resized
    /// stopped VM comes up at the *old* size, `lastApplied` advances to the
    /// entry's generation, and the size is realized on the next sync by the
    /// drift-correcting `.resize` planned here — a second work item at a
    /// generation already applied.
    ///
    /// That second item is the only way this agent can report
    /// `observedGeneration` and `failedGeneration` at the same value (STR-191):
    /// a failing item never advances `lastApplied`, so the two coincide only
    /// when something *else* already applied that generation successfully.
    /// Nothing here compensates for it — `lastApplied` is honest and must stay
    /// honest. The control plane resolves the pair on read, by treating a
    /// failure at the current generation as not converged.
    private static func addResizes(
        to items: inout [ReconcileWorkItem],
        desired: [DesiredVMState],
        present: [String: VMPresence],
        lastApplied: [String: Int64],
        sizing: [String: VMSizing],
        appliedEdges: [String: AppliedEdgeNonces]
    ) {
        guard !sizing.isEmpty else { return }
        for entry in desired where !entry.wantsAbsent {
            let id = entry.vmId.uuidString
            guard case .managed(.running)? = present[id],
                entry.desiredStatus == .running,
                let observed = sizing[id],
                observed.differs(from: entry.spec)
            else { continue }
            // Same staleness rule as the core diff: an older sync must never
            // undo a newer one, and an equal generation is drift correction —
            // which is deliberately *not* "already done". See the note above
            // for what an equal-generation retry means to the control plane.
            if let applied = lastApplied[id], entry.generation < applied { continue }

            if let index = items.firstIndex(where: { $0.kind == .vm && $0.id == id }) {
                guard items[index].steps.isEmpty else { continue }
                // The item this replaces may exist *only* to write the edge
                // record (`planCore`'s adoption case), so carry that decision
                // over rather than losing it to a resize.
                items[index] = ReconcileWorkItem(
                    kind: .vm, id: id, generation: entry.generation, steps: [.resize],
                    target: entry.asTarget, appliedEdges: items[index].appliedEdges)
            } else {
                items.append(
                    ReconcileWorkItem(
                        kind: .vm, id: id, generation: entry.generation, steps: [.resize],
                        target: entry.asTarget,
                        appliedEdges: Self.edgesAfter(
                            entry.edges, applied: appliedEdges[id], planning: [.resize])))
            }
        }
    }

    /// Compute the volume convergence plan for one sync (STR-148). Same engine,
    /// same semantics as the VM `plan`.
    public static func planVolumes(
        desired: [DesiredVolumeState],
        present: [String: VolumePresence],
        lastApplied: [String: Int64],
        tombstones: [DesiredWorkloadTombstone] = []
    ) -> ReconcilePlan {
        planCore(desired: desired, tombstones: tombstones, present: present, lastApplied: lastApplied)
    }

    /// Compute the snapshot-artifact convergence plan for one sync (STR-150).
    ///
    /// The desired list is mixed-kind, so it is split by family and each slice
    /// runs through the same engine as VMs, sandboxes and volumes — including
    /// the staleness guard, the held set, and the tombstone round trip. An
    /// artifact whose presence is not `.managed` is dropped rather than planned:
    /// artifacts have no runtime session, so the record store only ever yields
    /// `.managed`, and inventing an orphan for one would plan an `.adopt` no
    /// backend can perform.
    public static func planSnapshots(
        desired: [DesiredSnapshotState],
        present: [String: SnapshotPresence],
        lastApplied: [String: Int64],
        tombstones: [DesiredWorkloadTombstone] = []
    ) -> ReconcilePlan {
        var plan = ReconcilePlan()
        for family in SnapshotArtifactKind.allCases {
            let familyDesired = desired.filter { $0.kind == family }
            let familyPresent = present.filter { _, presence in
                guard case .managed(let artifact) = presence else { return false }
                return artifact.kind == family
            }
            guard !familyDesired.isEmpty || !familyPresent.isEmpty else { continue }
            let familyPlan = planFamily(
                family, desired: familyDesired, present: familyPresent,
                lastApplied: lastApplied, tombstones: tombstones)
            plan.items += familyPlan.items
            plan.unrecognized += familyPlan.unrecognized
        }
        return plan
    }

    private static func planFamily(
        _ family: SnapshotArtifactKind,
        desired: [DesiredSnapshotState],
        present: [String: SnapshotPresence],
        lastApplied: [String: Int64],
        tombstones: [DesiredWorkloadTombstone]
    ) -> ReconcilePlan {
        func planned<F: SnapshotArtifactFamily>(_: F.Type) -> ReconcilePlan {
            planCore(
                desired: desired.map { FamilyScopedSnapshot<F>(entry: $0) },
                tombstones: tombstones, present: present, lastApplied: lastApplied)
        }
        switch family {
        case .volumeSnapshot: return planned(VolumeSnapshotFamily.self)
        case .vmCheckpoint: return planned(VMCheckpointFamily.self)
        case .sandboxSnapshot: return planned(SandboxSnapshotFamily.self)
        }
    }

    /// The steps that take an existing snapshot artifact from `observed` to
    /// `desired` (STR-150). Empty when it already matches.
    ///
    /// An artifact's bytes are immutable, so there is exactly one thing that can
    /// still be wrong about one that exists: whether the copy the control plane
    /// asked for exists too. Nothing here ever re-captures — that is the whole
    /// safety property of modelling a capture as a create *strategy*
    /// (`DesiredSnapshotCapture`), which is read only while the artifact is
    /// absent. Without it a replayed sync would checkpoint a running guest again
    /// over the point in time the user is holding.
    ///
    /// A desired export that this host has already satisfied plans nothing, and
    /// an export field that goes *away* plans nothing either: withdrawing an
    /// exported copy is the control plane's own object-store bookkeeping, not a
    /// teardown the agent can perform.
    public static func snapshotSteps(
        desired: DesiredSnapshotState, observed: ObservedSnapshotArtifact
    ) -> [ReconcileStep] {
        guard desired.export != nil, !observed.exported else { return [] }
        return [.export]
    }

    /// Compute the sandbox convergence plan for one sync. Same engine, same
    /// semantics as the VM `plan`. Named (not an overload) so the VM call
    /// sites' unqualified `.running`-style literals stay unambiguous.
    public static func planSandboxes(
        desired: [DesiredSandboxState],
        present: [String: SandboxPresence],
        lastApplied: [String: Int64],
        tombstones: [DesiredWorkloadTombstone] = [],
        appliedEdges: [String: AppliedEdgeNonces] = [:]
    ) -> ReconcilePlan {
        planCore(
            desired: desired, tombstones: tombstones, present: present, lastApplied: lastApplied,
            appliedEdges: appliedEdges)
    }

    /// The kind-neutral diff. Rules, identical for every workload kind:
    ///
    /// * Entries older than the last applied generation are dropped (replays
    ///   and reordered syncs cannot roll state backward). An *equal*
    ///   generation is still re-planned — that is drift correction: if the
    ///   workload regressed out of band, the same generation converges it
    ///   again.
    /// * A present workload the sync tombstones is deleted, at the tombstone's
    ///   generation and under the same staleness rule as any desired entry.
    /// * A present workload the sync neither lists nor tombstones is **held**
    ///   and reported as unrecognized (STR-98). It keeps running: omission is
    ///   the control plane failing to mention something, which is what a
    ///   restored database, a re-enrolled agent, or a scoping bug all look
    ///   like, and none of those is an instruction to destroy a guest.
    /// * Desired-and-satisfied workloads whose generation advanced yield an
    ///   empty-step item so the applied generation still catches up.
    private static func planCore<Desired: ReconcilableDesired>(
        desired: [Desired],
        tombstones: [DesiredWorkloadTombstone],
        present: [String: WorkloadPresence<Desired.ObservedStatus>],
        lastApplied: [String: Int64],
        appliedEdges: [String: AppliedEdgeNonces] = [:]
    ) -> ReconcilePlan {
        var items: [ReconcileWorkItem] = []
        var desiredIds = Set<String>()
        let kind = Desired.workloadKind
        let tombstonesById = Dictionary(
            tombstones.lazy.filter { $0.kind == kind }.map { ($0.workloadId.uuidString, $0) },
            uniquingKeysWith: { first, second in first.generation >= second.generation ? first : second }
        )

        for entry in desired {
            let id = entry.workloadId.uuidString
            desiredIds.insert(id)

            if let applied = lastApplied[id], entry.generation < applied {
                continue  // stale: an older sync must never undo a newer one
            }

            let presence = present[id]
            let steps: [ReconcileStep]
            switch presence {
            case .managed(let observed):
                if entry.wantsAbsent {
                    steps = [.delete]
                } else {
                    // Edges are planned only here, on a workload this host is
                    // actually managing, and only after the status steps. An
                    // orphan's state is unknown until it is re-adopted, and a
                    // workload that does not exist yet is about to be built
                    // from scratch — a boot supersedes a reboot, and a
                    // checkpoint of a VM that was never here cannot be here
                    // either.
                    let status = entry.convergenceSteps(from: observed)
                    steps =
                        status
                        + edgeSteps(
                            entry.edges, applied: appliedEdges[id], after: status,
                            wantsRunning: entry.wantsRunning)
                }
            case .orphaned:
                // Deleting an orphan also goes through adopt-first so the
                // surviving runtime process is actually torn down; the
                // actuator falls back to manifest-only removal if the
                // session cannot be reconnected.
                steps = entry.wantsAbsent ? [.delete] : [.adopt]
            case .quarantined:
                // Nothing routes here — not a create (it exists), not a
                // delete (there is no backend to ask), not an adopt. The
                // generation is deliberately not recorded either: this agent
                // has not converged the entry and must not claim it has, so a
                // build that *can* route it picks the work up where it is.
                continue
            case nil:
                if entry.wantsAbsent {
                    steps = []  // already absent; just record the generation
                } else {
                    steps = [.create] + entry.convergenceSteps(from: entry.statusAfterCreate)
                }
            }

            // What this item will have applied for the workload's edges once it
            // finishes — nil when there is nothing to record. Computed here,
            // where the entry's nonces, the existing record and the steps
            // actually planned are all in hand.
            let itemEdges: AppliedEdgeNonces? =
                kind.carriesEdgeNonces && !steps.contains(.adopt) && !steps.contains(.delete)
                ? Self.edgesAfter(entry.edges, applied: appliedEdges[id], planning: steps)
                : nil

            // Nothing to do and nothing to record — skip entirely.
            //
            // "Nothing to record" is not the same as "no work", and that
            // distinction is what closes a window this stage would otherwise
            // leave open for the life of a workload. A host whose manifest
            // predates the nonce record adopts on its first *item*; without the
            // second clause a converged, idle VM never produces one, so the
            // record stays absent until something else bumps its generation —
            // and the thing that finally does is usually the very restart the
            // absent record then swallows. Emitting the empty-step item instead
            // costs one manifest write per workload, once, and makes the
            // adoption window exactly one sync (STR-151).
            let owesEdgeRecord =
                presence?.isManaged == true && kind.carriesEdgeNonces && appliedEdges[id] == nil
            if steps.isEmpty, let applied = lastApplied[id], applied >= entry.generation,
                !owesEdgeRecord
            {
                continue
            }
            items.append(
                ReconcileWorkItem(
                    kind: kind, id: id, generation: entry.generation, steps: steps,
                    target: entry.asTarget, appliedEdges: itemEdges))
        }

        // Everything on this host the sync did not list: torn down only where
        // the control plane said so explicitly, held and reported otherwise.
        var unrecognized: [UnrecognizedWorkload] = []
        for (id, presence) in present where !desiredIds.contains(id) {
            let applied = lastApplied[id] ?? 0
            if presence == .quarantined {
                // Reported, never torn down — not even under a tombstone. A
                // teardown needs a backend to perform it, and the whole reason
                // this entry is quarantined is that this build cannot name
                // one. Reporting it is what lets an operator see that the host
                // is holding something no agent here can act on.
                guard let workloadId = UUID(uuidString: id) else { continue }
                unrecognized.append(
                    UnrecognizedWorkload(
                        kind: kind, workloadId: workloadId, observedGeneration: applied,
                        status: "quarantined"))
                continue
            }
            guard let tombstone = tombstonesById[id] else {
                // Held. A workload whose id isn't a UUID cannot be named on
                // the wire, so it can never be reported — and therefore never
                // authorized for teardown either, which is the safe end of
                // that trade.
                guard let workloadId = UUID(uuidString: id) else { continue }
                let status: String
                switch presence {
                case .managed(let observed): status = Desired.describe(observed)
                case .orphaned: status = "orphaned"
                case .quarantined: status = "quarantined"
                }
                unrecognized.append(
                    UnrecognizedWorkload(
                        kind: kind,
                        workloadId: workloadId,
                        observedGeneration: applied,
                        status: status))
                continue
            }
            // Same staleness rule as a desired entry: a replayed tombstone
            // must not undo a newer sync that re-adopted the workload.
            guard tombstone.generation >= applied else { continue }
            items.append(
                ReconcileWorkItem(
                    kind: kind, id: id, generation: tombstone.generation, steps: [.delete],
                    target: .tombstone(tombstone)))
        }

        // Tombstones for workloads this host does not have need no work: the
        // control plane retires them once the agent stops reporting the id.

        return ReconcilePlan(
            items: items, unrecognized: unrecognized.sorted { $0.workloadId.uuidString < $1.workloadId.uuidString })
    }

    /// The steps for the edge nonces a desired entry carries (ADR 0001 stage 9,
    /// STR-151), appended after the status steps.
    ///
    /// Three rules, and each of them is a safety property rather than a
    /// convenience:
    ///
    /// * **No record, no edge.** A nil `applied` means this host has no memory
    ///   of what it has applied for the workload — a manifest from a build that
    ///   predates the field, or a workload it has never converged. Reading that
    ///   as zero would make a re-registered agent replay every reboot and
    ///   restore in the workload's history, rewinding a live guest to a
    ///   checkpoint from weeks ago. The record is written instead, unperformed,
    ///   by the first item the workload produces — which `planCore` makes sure
    ///   is the very next sync rather than whenever its generation happens to
    ///   move next, so the adoption window is one sync and not the life of an
    ///   idle VM.
    /// * **A boot supersedes a reboot**, and so does anything that leaves the
    ///   workload stopped. A guest built from scratch this sync is at least as
    ///   restarted as a reboot would make it, and rebooting a VM the control
    ///   plane wants shut down is not a smaller version of anything the user
    ///   asked for. Superseded is not deferred: the nonce is consumed either
    ///   way (see `edgesAfter`), or a stop-then-start weeks later would surprise
    ///   the guest with an ancient reboot.
    /// * **Nothing supersedes a restore — it waits.** A boot does not, because
    ///   loading a checkpoint needs a process to load it into: `[.boot,
    ///   .restore]` is the correct sequence for a stopped VM, and it is what
    ///   makes "restore after an agent restart" work with no extra message. Nor
    ///   does a stop, for the same reason read the other way — a restore is
    ///   about *state*, not power, so a power decision cannot answer it. It
    ///   stays outstanding until the workload is next wanted running.
    ///
    /// Both steps are emitted together when both nonces outrank, reboot first:
    /// restoring last is what leaves the guest in the state the checkpoint
    /// holds.
    static func edgeSteps(
        _ edges: DesiredEdges,
        applied: AppliedEdgeNonces?,
        after statusSteps: [ReconcileStep],
        wantsRunning: Bool
    ) -> [ReconcileStep] {
        guard let applied else { return [] }
        var steps: [ReconcileStep] = []
        if wantsRunning, let wanted = edges.rebootGeneration, wanted > (applied.reboot ?? 0),
            !statusSteps.contains(.boot)
        {
            steps.append(.reboot)
        }
        // A restore is guarded by `wantsRunning` too, but *only* as a wait: see
        // `edgesAfter`, which does not consume a restore it did not plan.
        if wantsRunning, let restore = edges.restore, restore.generation > (applied.restore ?? 0) {
            steps.append(.restore)
        }
        return steps
    }

    /// What the host will have applied once an item planning `steps` completes.
    ///
    /// This is where "superseded" and "deferred" are told apart, and the two
    /// edges answer differently — which is the point, because they are different
    /// kinds of intent:
    ///
    /// * **A reboot is always consumed.** Whatever the sync planned, the request
    ///   has been answered: performed if `.reboot` was planned, superseded
    ///   otherwise (by a boot that restarts the guest more thoroughly, or by a
    ///   desired status that wants it stopped, where rebooting is not a smaller
    ///   version of anything the user asked for). Leaving it outstanding is what
    ///   would surprise a guest with an ancient restart the next time it starts.
    /// * **A restore is consumed only when it is performed.** A restore is about
    ///   *state*, not power — which is exactly why a `.boot` does not supersede
    ///   one — so a stop landing between the request and the next sync cannot
    ///   answer it either. It waits instead, and lands as `[.boot, .restore]`
    ///   whenever the workload is next wanted running. Consuming it there would
    ///   silently discard a data-integrity request the API had already reported
    ///   converged.
    ///
    /// The one case that consumes everything is **adoption** (`applied == nil`):
    /// a host with no record cannot tell a request made a moment ago from one
    /// made months ago, so it writes down what the entry asks for and performs
    /// none of it. That asymmetry is the no-replay invariant; see
    /// `AppliedEdgeNonces`.
    static func edgesAfter(
        _ edges: DesiredEdges, applied: AppliedEdgeNonces?, planning steps: [ReconcileStep]
    ) -> AppliedEdgeNonces {
        guard let applied else { return AppliedEdgeNonces(applying: edges) }
        return AppliedEdgeNonces(
            reboot: edges.rebootGeneration ?? applied.reboot,
            restore: steps.contains(.restore) ? edges.restore?.generation : applied.restore)
    }

    /// The steps that take a VM from `observed` to `desired`. Empty when the
    /// observed status already satisfies the goal.
    public static func statusSteps(desired: DesiredVMStatus, observed: VMStatus) -> [ReconcileStep] {
        if desired.isSatisfied(by: observed) {
            return []
        }
        switch desired {
        case .running:
            return observed == .paused ? [.resume] : [.boot]
        case .paused:
            switch observed {
            case .running:
                return [.pause]
            case .created, .shutdown:
                return [.boot, .pause]
            default:
                return [.pause]
            }
        case .shutdown:
            return [.shutdown]
        case .absent:
            return [.delete]
        }
    }

    /// The steps that take a sandbox from `observed` to `desired`. Empty when
    /// the observed status already satisfies the goal — including `.exited`
    /// for both `.running` and `.stopped` (see
    /// `DesiredSandboxStatus.isSatisfied(by:)`): phase 1 has no restart
    /// policy, so a finished one-shot workload is never relaunched. Named
    /// (not an overload of `statusSteps`) for the same ambiguity reason as
    /// `planSandboxes`.
    /// The steps that take an existing volume from `observed` to `desired`
    /// (STR-148). Empty when it already matches.
    ///
    /// At most one step is ever planned, and the order below is the reason:
    /// a grow must land before the attachment *moves* (the resize path wants
    /// the volume detached), and an attachment that is merely *wrong* has to be
    /// unplugged before it can be re-plugged elsewhere. The next
    /// level-triggered sync plans the following step, which is exactly how the
    /// VM planner sequences a boot behind a create.
    ///
    /// A desired *removal* of the attachment is the one inversion, and it
    /// inverts because the detach is what makes the grow possible (STR-199) —
    /// see the clause below.
    ///
    /// A shrink and a format change are deliberately *not* steps. Neither is
    /// something the agent can converge — one destroys data, the other is a
    /// conversion the control plane never asks for — so they surface as
    /// permanent failures from the actuator rather than as work that silently
    /// never completes.
    public static func volumeSteps(desired: DesiredVolumeState, observed: ObservedVolumeFacts) -> [ReconcileStep] {
        // Unplug before growing when the attachment is being *removed*, not
        // moved. The agent refuses to grow an image a guest may still hold
        // open and names two remedies — stop the guest, or detach — and with
        // the grow planned first only the *first* of them could ever run: the
        // refused resize was the only step planned, so the detach that would
        // lift the refusal was never reached and the volume retried a doomed
        // grow on every sync. Growing first still holds for an attachment that
        // is merely moving, where the resize is the thing that has to land
        // before the slot changes underneath it.
        if desired.attachment == nil, observed.attachedVMId != nil {
            return [.detach]
        }
        if let size = observed.sizeBytes, desired.sizeBytes > size {
            return [.resize]
        }
        // Detachment is decided on `attachedVMId` alone, before the slot is
        // compared. Pairing the two in one equality check let a volume with no
        // desired attachment but a stale `deviceName` fall through to `.attach`
        // with nothing to attach to — which the actuator answers with a
        // *permanent* failure, degrading a volume whose only problem was a
        // leftover field.
        guard let attachment = desired.attachment else {
            // Detached and desired detached — the clause above already handled
            // the case where it is still plugged in.
            return unconfirmedSizeSteps(observed)
        }
        if observed.attachedVMId == attachment.vmId.uuidString,
            observed.deviceName == attachment.deviceName.rawValue
        {
            return unconfirmedSizeSteps(observed)
        }
        // Attached to the wrong VM or in the wrong slot: unplug first, and let
        // the next sync plan the attach against the observation that follows.
        if observed.attachedVMId != nil {
            return [.detach]
        }
        return [.attach]
    }

    /// What to do about a volume whose size the agent could not read, once
    /// every other difference is settled.
    ///
    /// A nil `sizeBytes` used to plan nothing at all. That was right about never
    /// growing on a guess and wrong about what planning nothing *means*: the
    /// item is still emitted whenever the generation is newer, and an item that
    /// runs no steps records its generation as applied. So a resize whose
    /// current size was never successfully read reported as converged — the
    /// exact "a grow that never happened reads as one that did" failure STR-199
    /// exists to remove, surviving on the probe-failure path.
    ///
    /// Planning `.resize` hands the question to the actuator, which refuses it
    /// as `blocked` naming the unreadable image rather than growing anything,
    /// so the generation stays unapplied and every sync retries until the probe
    /// works. It sits *last* on purpose: an unreadable size must not starve the
    /// attach and detach work above it, which needs no size at all.
    private static func unconfirmedSizeSteps(_ observed: ObservedVolumeFacts) -> [ReconcileStep] {
        observed.sizeBytes == nil ? [.resize] : []
    }

    public static func sandboxStatusSteps(desired: DesiredSandboxStatus, observed: SandboxStatus) -> [ReconcileStep] {
        if desired.isSatisfied(by: observed) {
            return []
        }
        switch desired {
        case .running:
            return [.boot]
        case .stopped:
            return [.shutdown]
        case .absent:
            return [.delete]
        }
    }
}
