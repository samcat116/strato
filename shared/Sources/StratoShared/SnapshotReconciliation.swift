import Foundation

// MARK: - Snapshot artifacts as desired state (ADR 0001 stage 8, STR-150)
//
// The header this file replaces claimed a checkpoint "is an *action* rather
// than a state, so it cannot ride the level-triggered desired-state sync".
// That is true of the verb and false of the result. "Checkpoint this VM" is an
// action; **"checkpoint C exists for VM V" is a durable artifact** with an
// identity, a footprint, and a host — something an agent can enumerate, diff,
// and converge on exactly like a volume.
//
// So the three artifact families share one desired/observed pair rather than
// three. A volume snapshot (a qcow2 overlay), a VM checkpoint (a qcow2
// *internal* snapshot holding guest RAM), and a sandbox snapshot (a directory
// of Firecracker artifacts) differ only in which backend captures them and what
// metadata comes back; the identity, the generation guard, the absent/confirm
// dance, and the export placement fact are the same shape three times over. One
// `kind` discriminator keeps them one code path — the `resource_kind` rule from
// `CONTEXT.md`, applied to the wire.

/// Which artifact family a snapshot entry belongs to, and therefore which
/// backend on the agent captures and deletes it.
///
/// Decoded strictly, like `DesiredVMStatus` and for the same reason a volume's
/// status is: an unknown kind must fail rather than route an artifact to the
/// wrong backend, where "delete" would find nothing and quietly succeed.
public enum SnapshotArtifactKind: String, Codable, CaseIterable, Sendable {
    /// A disk-only point-in-time copy of one volume — an external qcow2 overlay
    /// written by the agent's storage backend. Parent: a volume.
    case volumeSnapshot = "VolumeSnapshot"
    /// Guest RAM + device state + disk contents at one instant, written by
    /// QEMU's `snapshot-save` job as an *internal* snapshot of the VM's own
    /// qcow2 disks. Parent: a VM.
    case vmCheckpoint = "VMCheckpoint"
    /// Firecracker guest memory + vmstate + a rootfs copy, in an agent-owned
    /// directory. Parent: a sandbox.
    case sandboxSnapshot = "SandboxSnapshot"

    /// This artifact family's own `WorkloadKind`, for the reconciler's
    /// generation bookkeeping and the tombstone/unrecognized round trip. The
    /// two enums are in bijection: `WorkloadKind` has to name every kind an
    /// agent can hold, and `SnapshotArtifactKind` has to be unable to name a
    /// live workload, so neither can absorb the other.
    public var workloadKind: WorkloadKind {
        switch self {
        case .volumeSnapshot: return .volumeSnapshot
        case .vmCheckpoint: return .vmCheckpoint
        case .sandboxSnapshot: return .sandboxSnapshot
        }
    }

    /// The workload kind of the resource this artifact hangs off, so the agent
    /// can name the lane the capture has to serialize against: capturing an
    /// artifact drives the parent's runtime, so it must not interleave with the
    /// parent's own convergence.
    public var parentKind: WorkloadKind {
        switch self {
        case .volumeSnapshot: return .volume
        case .vmCheckpoint: return .vm
        case .sandboxSnapshot: return .sandbox
        }
    }

    /// The artifact family a workload kind names, or nil for a live workload.
    public init?(_ workloadKind: WorkloadKind) {
        switch workloadKind {
        case .volumeSnapshot: self = .volumeSnapshot
        case .vmCheckpoint: self = .vmCheckpoint
        case .sandboxSnapshot: self = .sandboxSnapshot
        case .vm, .sandbox, .volume: return nil
        }
    }
}

/// The state the control plane wants one snapshot artifact's bytes to be in.
///
/// Two cases, like `DesiredVolumeStatus`: an artifact is frozen by
/// construction, so there is no run state to want and nothing between "exists"
/// and "gone". Decoded strictly for the volume reason, sharpened: misreading
/// this destroys the only copy of a point in time a user chose to keep.
public enum DesiredSnapshotStatus: String, Codable, CaseIterable, Sendable {
    case present = "Present"
    /// The artifact should not exist on the agent at all (deletion in
    /// progress). The control-plane row is removed only after an agent confirms
    /// absence by omitting the snapshot from its observed report.
    case absent = "Absent"
}

/// How an artifact that does not exist yet gets captured: a create *strategy*,
/// not an operation — `DesiredVolumeSource` applied to snapshots.
///
/// Consulted **only while the artifact is absent from the host**. An artifact
/// that already exists ignores this field forever, which is what makes a
/// replayed or re-driven sync unable to re-capture over a checkpoint the user
/// is holding — and what makes "pause the guest to take it" safe to express
/// declaratively at all.
public struct DesiredSnapshotCapture: Codable, Sendable, Equatable {
    /// Sandbox artifacts only: whether the guest resumes after the capture or
    /// stays stopped (checkpoint-and-stop). Nil for the other kinds and from
    /// senders that omit it, which reads as `.resume`.
    ///
    /// This is a capture parameter rather than a status because it describes
    /// *how the bytes are taken*, not what the sandbox should be doing
    /// afterwards. The sandbox's own `DesiredSandboxState.desiredStatus` still
    /// carries that, written in the same transaction — so a sync replayed after
    /// the artifact exists converges the sandbox from its own entry and never
    /// re-reads this one.
    public let sandboxMode: SandboxSnapshotMode?

    /// Volume artifacts only: the VM the control plane believes holds the
    /// volume, so the agent can refuse rather than write a snapshot that is not
    /// point-in-time (issue #747). Nil for a detached volume.
    public let attachedVMId: UUID?

    public init(sandboxMode: SandboxSnapshotMode? = nil, attachedVMId: UUID? = nil) {
        self.sandboxMode = sandboxMode
        self.attachedVMId = attachedVMId
    }

    public static func sandbox(_ mode: SandboxSnapshotMode) -> DesiredSnapshotCapture {
        DesiredSnapshotCapture(sandboxMode: mode)
    }
}

/// "This artifact should also exist in the control plane's object store."
///
/// The placement half of snapshot mobility (issue #428), stated as a fact about
/// where the snapshot exists rather than as an order to move bytes. The agent
/// converges it by streaming each artifact to its upload slot and then reporting
/// `ObservedSnapshotState.exported`; the transfer underneath stays a transport
/// concern (`SnapshotArtifactTransfer`), exactly as console and exec streams do.
///
/// Idempotent by construction: each PUT replaces the object at its deterministic
/// key, so a re-driven sync after a lost report converges on the same bytes
/// instead of duplicating them. Nil means the control plane wants no exported
/// copy — never "delete the one you made", which is the control plane's own
/// object-store bookkeeping to undo.
public struct DesiredSnapshotExport: Codable, Sendable, Equatable {
    /// One upload slot per artifact of the archive. Control-plane-relative
    /// paths presented with the agent's SVID over mTLS, so — like image
    /// downloads since v13 — nothing here expires and the entry is safe to sit
    /// in a sync indefinitely.
    public let uploads: [SandboxSnapshotArtifactUploadTarget]

    public init(uploads: [SandboxSnapshotArtifactUploadTarget]) {
        self.uploads = uploads
    }
}

/// One snapshot artifact's authoritative desired state (ADR 0001 stage 8,
/// STR-150). Level-triggered, generation-guarded, safe to drop or replay —
/// `DesiredVolumeState` semantics exactly.
///
/// There is deliberately no path and no size. The agent owns artifact layout
/// and is the only party that can measure what it wrote, so both travel the
/// other way, on the observed report.
public struct DesiredSnapshotState: Codable, Sendable {
    public let snapshotId: UUID
    public let kind: SnapshotArtifactKind
    /// The resource the artifact was captured from — a volume, VM, or sandbox
    /// id per `kind.parentKind`. Carried because the agent derives the
    /// artifact's location from (parent, snapshot) exactly as it did at
    /// capture: that is what lets a delete clean up a capture whose report was
    /// lost, and it is why nothing here needs a path.
    public let parentId: UUID
    public let desiredStatus: DesiredSnapshotStatus
    /// Monotonic per-artifact counter, bumped on every desired change. The
    /// agent records the generation it last applied and rejects older ones, so
    /// replayed or reordered syncs cannot roll an artifact backward.
    public let generation: Int64
    /// How to capture the artifact if it is not here yet. Nil means the
    /// defaults for `kind`.
    public let capture: DesiredSnapshotCapture?
    /// Volume artifacts only: the backend coordinates that own the snapshot.
    /// This travels independently of the parent volume entry because a Ceph
    /// snapshot remains deletable from any configured client agent after the
    /// parent volume has moved off this host. Nil for VM/sandbox artifacts and
    /// for pre-v54 senders.
    public let volumeStorage: DesiredVolumeStorage?
    /// Where a copy of the artifact should also exist, if anywhere.
    public let export: DesiredSnapshotExport?

    public init(
        snapshotId: UUID,
        kind: SnapshotArtifactKind,
        parentId: UUID,
        desiredStatus: DesiredSnapshotStatus,
        generation: Int64,
        capture: DesiredSnapshotCapture? = nil,
        volumeStorage: DesiredVolumeStorage? = nil,
        export: DesiredSnapshotExport? = nil
    ) {
        self.snapshotId = snapshotId
        self.kind = kind
        self.parentId = parentId
        self.desiredStatus = desiredStatus
        self.generation = generation
        self.capture = capture
        self.volumeStorage = volumeStorage
        self.export = export
    }
}

/// What one capture actually produced, as measured by the agent that wrote it.
///
/// This is where the metadata that used to ride `VMCheckpointStatusResponse`
/// and `SandboxSnapshotStatusResponse` lives now. Moving it onto the observed
/// report is not just relocation: an RPC response is delivered once and lost if
/// the socket drops mid-flight, which is why both old paths had to treat a
/// missing report as a protocol error and mark the row `.error` for a
/// checkpoint that in fact existed. A report is re-sent on every heartbeat, so
/// the same facts arrive again until the control plane has them.
///
/// Every field is optional and every consumer treats a nil as "unknown, not
/// zero" — a footprint the agent could not measure must never silently become a
/// free one in quota accounting.
public struct ObservedSnapshotFacts: Codable, Sendable, Equatable {
    /// Total on-disk footprint this artifact adds, **as measured at capture**.
    /// For a VM checkpoint that is the machine state alone: the disks it lives
    /// inside are already charged as volume storage (STR-181 made that true),
    /// and an internal snapshot does not copy them.
    ///
    /// Final for the two families that are finished when they are written. For a
    /// volume snapshot it is an empty overlay's header and `currentSizeBytes` is
    /// the figure to read instead.
    public let sizeBytes: Int64?
    /// The footprint re-measured at *report* time, for an artifact that keeps
    /// growing after capture (STR-181).
    ///
    /// Today that is only a volume snapshot's overlay, which starts as an empty
    /// qcow2 and grows toward its parent's size as the volume is written.
    /// `sizeBytes` is what the agent measured *at* capture and is frozen there —
    /// for an overlay it is the header, which is why the control plane ignored
    /// it. This one is re-read on every report for actual-footprint visibility;
    /// the storage quota separately keeps the parent-sized bound reserved.
    ///
    /// Nil for every other kind, and from any agent that does not re-measure —
    /// which is what makes the field readable without a version gate. Nil is
    /// "unknown", never zero.
    public let currentSizeBytes: Int64?
    /// Where the agent put it, when the artifact is a file or directory the
    /// agent names. Nil for a VM checkpoint, which lives inside disks it does
    /// not get to name.
    public let storagePath: String?
    /// Host CPU architecture the capture was taken on. Every kind records it:
    /// no snapshot of machine state restores across architectures.
    public let architecture: CPUArchitecture?

    // VM checkpoints (issue #564).

    /// The version of the QEMU that took the checkpoint. A restore needs a
    /// compatible (in practice: identical) build and machine type.
    public let qemuVersion: String?

    // Sandbox snapshots (issues #426, #427, #428).

    /// `vmm_version` of the Firecracker that took the snapshot.
    public let firecrackerVersion: String?
    /// Version advertised by the guest frozen into this checkpoint. Nil is a
    /// legacy/unknown artifact retained only so it can be inventoried and
    /// deleted; restore and fork require the exact current version.
    public let guestControlProtocolVersion: Int?
    /// Version of the fork-safe artifact layout, or nil for legacy/unjailed
    /// checkpoints that remain eligible for in-place restore only.
    public let forkLayoutVersion: Int?
    /// Firecracker CPU template the checkpointed guest booted with. Nil means
    /// no template: the snapshot only restores on hosts with an identical CPU
    /// model.
    public let cpuTemplate: String?

    public init(
        sizeBytes: Int64? = nil,
        currentSizeBytes: Int64? = nil,
        storagePath: String? = nil,
        architecture: CPUArchitecture? = nil,
        qemuVersion: String? = nil,
        firecrackerVersion: String? = nil,
        guestControlProtocolVersion: Int? = nil,
        forkLayoutVersion: Int? = nil,
        cpuTemplate: String? = nil
    ) {
        self.sizeBytes = sizeBytes
        self.currentSizeBytes = currentSizeBytes
        self.storagePath = storagePath
        self.architecture = architecture
        self.qemuVersion = qemuVersion
        self.firecrackerVersion = firecrackerVersion
        self.guestControlProtocolVersion = guestControlProtocolVersion
        self.forkLayoutVersion = forkLayoutVersion
        self.cpuTemplate = cpuTemplate
    }
}

/// One snapshot artifact's state as actually observed on an agent (STR-150).
/// The convergence metadata matches `ObservedVMState` — see the doc comments
/// there.
public struct ObservedSnapshotState: Codable, Sendable {
    public let snapshotId: UUID
    public let kind: SnapshotArtifactKind
    public let parentId: UUID
    /// Whether the artifact's bytes exist on this host. A `false` entry is one
    /// the agent is listing because it is mid-capture or failed with nothing
    /// written — the mirror of the VM report's in-flight section. *Absence from
    /// the list* is what confirms a deletion; `present: false` explicitly does
    /// not.
    public let present: Bool
    /// Whether this host has finished streaming the artifact to the export
    /// slots the sync asked for. False when no export was desired, when it has
    /// not finished, and when the copy was made by some other host — the
    /// control plane's own upload records are what say an exported copy is
    /// *complete*; this only says this agent believes it did its half.
    public let exported: Bool
    /// What the capture produced. Nil until the artifact exists.
    public let facts: ObservedSnapshotFacts?
    /// The desired-state generation this observation reflects (0 if none yet).
    public let observedGeneration: Int64
    /// Human-readable convergence stage ("capturing", "exporting", ...) while
    /// the agent is still working toward a newer generation. Progress only.
    public let convergencePhase: String?
    /// The most recent convergence failure, if the last attempt failed.
    public let lastError: String?
    /// The generation whose convergence produced `lastError` (see
    /// `ObservedVMState.failedGeneration` for why the control plane needs it).
    public let failedGeneration: Int64?
    /// Retry semantics for `lastError`; see
    /// `ObservedVMState.failureClassification`.
    public let failureClassification: ObservedFailureClassification?

    public init(
        snapshotId: UUID,
        kind: SnapshotArtifactKind,
        parentId: UUID,
        present: Bool,
        exported: Bool = false,
        facts: ObservedSnapshotFacts? = nil,
        observedGeneration: Int64,
        convergencePhase: String? = nil,
        lastError: String? = nil,
        failedGeneration: Int64? = nil,
        failureClassification: ObservedFailureClassification? = nil
    ) {
        self.snapshotId = snapshotId
        self.kind = kind
        self.parentId = parentId
        self.present = present
        self.exported = exported
        self.facts = facts
        self.observedGeneration = observedGeneration
        self.convergencePhase = convergencePhase
        self.lastError = lastError
        self.failedGeneration = failedGeneration
        self.failureClassification = failureClassification
    }
}
