import Foundation
import SwiftProtobuf

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
public typealias SnapshotArtifactKind = Strato_Agent_V1_SnapshotArtifactKind
extension Strato_Agent_V1_SnapshotArtifactKind: Codable {
    /// A disk-only point-in-time copy of one volume — an external qcow2 overlay
    /// written by the agent's storage backend. Parent: a volume.

    /// Guest RAM + device state + disk contents at one instant, written by
    /// QEMU's `snapshot-save` job as an *internal* snapshot of the VM's own
    /// qcow2 disks. Parent: a VM.

    /// Firecracker guest memory + vmstate + a rootfs copy, in an agent-owned
    /// directory. Parent: a sandbox.

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
        case .unspecified, .UNRECOGNIZED: return .unspecified
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
        case .unspecified, .UNRECOGNIZED: return .unspecified
        }
    }

    /// The artifact family a workload kind names, or nil for a live workload.
    public init?(_ workloadKind: WorkloadKind) {
        switch workloadKind {
        case .volumeSnapshot: self = .volumeSnapshot
        case .vmCheckpoint: self = .vmCheckpoint
        case .sandboxSnapshot: self = .sandboxSnapshot
        case .vm, .sandbox, .volume, .unspecified, .UNRECOGNIZED: return nil
        }
    }

    public var protocolValue: String {
        switch self {
        case .volumeSnapshot: return "VolumeSnapshot"
        case .vmCheckpoint: return "VMCheckpoint"
        case .sandboxSnapshot: return "SandboxSnapshot"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "VolumeSnapshot": self = .volumeSnapshot
        case "VMCheckpoint": self = .vmCheckpoint
        case "SandboxSnapshot": self = .sandboxSnapshot
        default: return nil
        }
    }

    public static var knownCases: [Self] { [.volumeSnapshot, .vmCheckpoint, .sandboxSnapshot] }

    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = Self(rawValue: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown enum value")
        }
        self = value
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        guard !protocolValue.isEmpty else {
            throw EncodingError.invalidValue(
                self, .init(codingPath: encoder.codingPath, debugDescription: "Unknown enum value"))
        }
        var container = encoder.singleValueContainer()
        try container.encode(protocolValue)
    }
}

/// The state the control plane wants one snapshot artifact's bytes to be in.
///
/// Two cases, like `DesiredVolumeStatus`: an artifact is frozen by
/// construction, so there is no run state to want and nothing between "exists"
/// and "gone". Decoded strictly for the volume reason, sharpened: misreading
/// this destroys the only copy of a point in time a user chose to keep.
public typealias DesiredSnapshotStatus = Strato_Agent_V1_DesiredSnapshotStatus
extension Strato_Agent_V1_DesiredSnapshotStatus: Codable {

    /// The artifact should not exist on the agent at all (deletion in
    /// progress). The control-plane row is removed only after an agent confirms
    /// absence by omitting the snapshot from its observed report.

    public var protocolValue: String {
        switch self {
        case .present: return "Present"
        case .absent: return "Absent"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "Present": self = .present
        case "Absent": self = .absent
        default: return nil
        }
    }

    public static var knownCases: [Self] { [.present, .absent] }

    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = Self(rawValue: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown enum value")
        }
        self = value
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        guard !protocolValue.isEmpty else {
            throw EncodingError.invalidValue(
                self, .init(codingPath: encoder.codingPath, debugDescription: "Unknown enum value"))
        }
        var container = encoder.singleValueContainer()
        try container.encode(protocolValue)
    }
}

/// How an artifact that does not exist yet gets captured: a create *strategy*,
/// not an operation — `DesiredVolumeSource` applied to snapshots.
///
/// Consulted **only while the artifact is absent from the host**. An artifact
/// that already exists ignores this field forever, which is what makes a
/// replayed or re-driven sync unable to re-capture over a checkpoint the user
/// is holding — and what makes "pause the guest to take it" safe to express
/// declaratively at all.
public typealias DesiredSnapshotCapture = Strato_Agent_V1_DesiredSnapshotCapture
extension Strato_Agent_V1_DesiredSnapshotCapture: Codable {
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

    /// Volume artifacts only: the VM the control plane believes holds the
    /// volume, so the agent can refuse rather than write a snapshot that is not
    /// point-in-time (issue #747). Nil for a detached volume.

    public init(sandboxMode: SandboxSnapshotMode? = nil, attachedVMId: UUID? = nil) {
        self.init()
        self._jsonSandboxMode = sandboxMode
        self._jsonAttachedVMId = attachedVMId
    }

    private enum CodingKeys: String, CodingKey { case sandboxMode; case attachedVMId }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonSandboxMode = try container.decodeIfPresent(SandboxSnapshotMode.self, forKey: .sandboxMode)
        self._jsonAttachedVMId = try container.decodeIfPresent(UUID.self, forKey: .attachedVMId)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(_jsonSandboxMode, forKey: .sandboxMode)
        try container.encodeIfPresent(_jsonAttachedVMId, forKey: .attachedVMId)
    }

    var _jsonSandboxMode: SandboxSnapshotMode? {
        get { hasSandboxMode ? (sandboxMode) : nil }
        set { if let value = newValue { sandboxMode = value } else { clearSandboxMode() } }
    }
    var _jsonAttachedVMId: UUID? {
        get {
            hasAttachedVmID
                ? (UUID(uuidString: attachedVmID) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))) : nil
        }
        set { if let value = newValue { attachedVmID = value.uuidString } else { clearAttachedVmID() } }
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
public typealias DesiredSnapshotExport = Strato_Agent_V1_DesiredSnapshotExport
extension Strato_Agent_V1_DesiredSnapshotExport: Codable {
    /// One upload slot per artifact of the archive. Control-plane-relative
    /// paths presented with the agent's SVID over mTLS, so — like image
    /// downloads since v13 — nothing here expires and the entry is safe to sit
    /// in a sync indefinitely.

    public init(uploads: [SandboxSnapshotArtifactUploadTarget]) {
        self.init()
        self._jsonUploads = uploads
    }

    private enum CodingKeys: String, CodingKey { case uploads }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonUploads = try container.decode([SandboxSnapshotArtifactUploadTarget].self, forKey: .uploads)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonUploads, forKey: .uploads)
    }

    var _jsonUploads: [SandboxSnapshotArtifactUploadTarget] {
        get { uploads.values }
        set {
            let value = newValue;
            uploads = Strato_Agent_V1_DesiredSnapshotExportUploadsSection.with { $0.values = value }
        }
    }
}

/// One snapshot artifact's authoritative desired state (ADR 0001 stage 8,
/// STR-150). Level-triggered, generation-guarded, safe to drop or replay —
/// `DesiredVolumeState` semantics exactly.
///
/// There is deliberately no path and no size. The agent owns artifact layout
/// and is the only party that can measure what it wrote, so both travel the
/// other way, on the observed report.
public typealias DesiredSnapshotState = Strato_Agent_V1_DesiredSnapshotState
extension Strato_Agent_V1_DesiredSnapshotState: Codable {
    /// The resource the artifact was captured from — a volume, VM, or sandbox
    /// id per `kind.parentKind`. Carried because the agent derives the
    /// artifact's location from (parent, snapshot) exactly as it did at
    /// capture: that is what lets a delete clean up a capture whose report was
    /// lost, and it is why nothing here needs a path.
    /// Monotonic per-artifact counter, bumped on every desired change. The
    /// agent records the generation it last applied and rejects older ones, so
    /// replayed or reordered syncs cannot roll an artifact backward.
    /// How to capture the artifact if it is not here yet. Nil means the
    /// defaults for `kind`.
    /// Volume artifacts only: the backend coordinates that own the snapshot.
    /// This travels independently of the parent volume entry because a Ceph
    /// snapshot remains deletable from any configured client agent after the
    /// parent volume has moved off this host. Nil for VM/sandbox artifacts and
    /// for pre-v54 senders.
    /// Where a copy of the artifact should also exist, if anywhere.

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
        self.init()
        self._jsonSnapshotId = snapshotId
        self._jsonKind = kind
        self._jsonParentId = parentId
        self._jsonDesiredStatus = desiredStatus
        self._jsonGeneration = generation
        self._jsonCapture = capture
        self._jsonVolumeStorage = volumeStorage
        self._jsonExport = export
    }

    private enum CodingKeys: String, CodingKey {
        case snapshotId; case kind; case parentId; case desiredStatus; case generation; case capture;
        case volumeStorage; case export
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonSnapshotId = try container.decode(UUID.self, forKey: .snapshotId)
        self._jsonKind = try container.decode(SnapshotArtifactKind.self, forKey: .kind)
        self._jsonParentId = try container.decode(UUID.self, forKey: .parentId)
        self._jsonDesiredStatus = try container.decode(DesiredSnapshotStatus.self, forKey: .desiredStatus)
        self._jsonGeneration = try container.decode(Int64.self, forKey: .generation)
        self._jsonCapture = try container.decodeIfPresent(DesiredSnapshotCapture.self, forKey: .capture)
        self._jsonVolumeStorage = try container.decodeIfPresent(DesiredVolumeStorage.self, forKey: .volumeStorage)
        self._jsonExport = try container.decodeIfPresent(DesiredSnapshotExport.self, forKey: .export)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonSnapshotId, forKey: .snapshotId)
        try container.encode(_jsonKind, forKey: .kind)
        try container.encode(_jsonParentId, forKey: .parentId)
        try container.encode(_jsonDesiredStatus, forKey: .desiredStatus)
        try container.encode(_jsonGeneration, forKey: .generation)
        try container.encodeIfPresent(_jsonCapture, forKey: .capture)
        try container.encodeIfPresent(_jsonVolumeStorage, forKey: .volumeStorage)
        try container.encodeIfPresent(_jsonExport, forKey: .export)
    }

    var _jsonSnapshotId: UUID {
        get { UUID(uuidString: snapshotID) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) }
        set { let value = newValue; snapshotID = value.uuidString }
    }
    var _jsonKind: SnapshotArtifactKind {
        get { kind }
        set { let value = newValue; kind = value }
    }
    var _jsonParentId: UUID {
        get { UUID(uuidString: parentID) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) }
        set { let value = newValue; parentID = value.uuidString }
    }
    var _jsonDesiredStatus: DesiredSnapshotStatus {
        get { desiredStatus }
        set { let value = newValue; desiredStatus = value }
    }
    var _jsonGeneration: Int64 {
        get { generation }
        set { let value = newValue; generation = value }
    }
    var _jsonCapture: DesiredSnapshotCapture? {
        get { hasCapture ? (capture) : nil }
        set { if let value = newValue { capture = value } else { clearCapture() } }
    }
    var _jsonVolumeStorage: DesiredVolumeStorage? {
        get { hasVolumeStorage ? (volumeStorage) : nil }
        set { if let value = newValue { volumeStorage = value } else { clearVolumeStorage() } }
    }
    var _jsonExport: DesiredSnapshotExport? {
        get { hasExport ? (export) : nil }
        set { if let value = newValue { export = value } else { clearExport() } }
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
public typealias ObservedSnapshotFacts = Strato_Agent_V1_ObservedSnapshotFacts
extension Strato_Agent_V1_ObservedSnapshotFacts: Codable {
    /// Total on-disk footprint this artifact adds, **as measured at capture**.
    /// For a VM checkpoint that is the machine state alone: the disks it lives
    /// inside are already charged as volume storage (STR-181 made that true),
    /// and an internal snapshot does not copy them.
    ///
    /// Final for the two families that are finished when they are written. For a
    /// volume snapshot it is an empty overlay's header and `currentSizeBytes` is
    /// the figure to read instead.
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
    /// Where the agent put it, when the artifact is a file or directory the
    /// agent names. Nil for a VM checkpoint, which lives inside disks it does
    /// not get to name.
    /// Host CPU architecture the capture was taken on. Every kind records it:
    /// no snapshot of machine state restores across architectures.

    // VM checkpoints (issue #564).

    /// The version of the QEMU that took the checkpoint. A restore needs a
    /// compatible (in practice: identical) build and machine type.

    // Sandbox snapshots (issues #426, #427, #428).

    /// `vmm_version` of the Firecracker that took the snapshot.
    /// Version advertised by the guest frozen into this checkpoint. Nil is a
    /// legacy/unknown artifact retained only so it can be inventoried and
    /// deleted; restore and fork require the exact current version.
    /// Version of the fork-safe artifact layout, or nil for legacy/unjailed
    /// checkpoints that remain eligible for in-place restore only.
    /// Firecracker CPU template the checkpointed guest booted with. Nil means
    /// no template: the snapshot only restores on hosts with an identical CPU
    /// model.

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
        self.init()
        self._jsonSizeBytes = sizeBytes
        self._jsonCurrentSizeBytes = currentSizeBytes
        self._jsonStoragePath = storagePath
        self._jsonArchitecture = architecture
        self._jsonQemuVersion = qemuVersion
        self._jsonFirecrackerVersion = firecrackerVersion
        self._jsonGuestControlProtocolVersion = guestControlProtocolVersion
        self._jsonForkLayoutVersion = forkLayoutVersion
        self._jsonCpuTemplate = cpuTemplate
    }

    private enum CodingKeys: String, CodingKey {
        case sizeBytes; case currentSizeBytes; case storagePath; case architecture; case qemuVersion;
        case firecrackerVersion; case guestControlProtocolVersion; case forkLayoutVersion; case cpuTemplate
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonSizeBytes = try container.decodeIfPresent(Int64.self, forKey: .sizeBytes)
        self._jsonCurrentSizeBytes = try container.decodeIfPresent(Int64.self, forKey: .currentSizeBytes)
        self._jsonStoragePath = try container.decodeIfPresent(String.self, forKey: .storagePath)
        self._jsonArchitecture = try container.decodeIfPresent(CPUArchitecture.self, forKey: .architecture)
        self._jsonQemuVersion = try container.decodeIfPresent(String.self, forKey: .qemuVersion)
        self._jsonFirecrackerVersion = try container.decodeIfPresent(String.self, forKey: .firecrackerVersion)
        self._jsonGuestControlProtocolVersion = try container.decodeIfPresent(
            Int.self, forKey: .guestControlProtocolVersion)
        self._jsonForkLayoutVersion = try container.decodeIfPresent(Int.self, forKey: .forkLayoutVersion)
        self._jsonCpuTemplate = try container.decodeIfPresent(String.self, forKey: .cpuTemplate)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(_jsonSizeBytes, forKey: .sizeBytes)
        try container.encodeIfPresent(_jsonCurrentSizeBytes, forKey: .currentSizeBytes)
        try container.encodeIfPresent(_jsonStoragePath, forKey: .storagePath)
        try container.encodeIfPresent(_jsonArchitecture, forKey: .architecture)
        try container.encodeIfPresent(_jsonQemuVersion, forKey: .qemuVersion)
        try container.encodeIfPresent(_jsonFirecrackerVersion, forKey: .firecrackerVersion)
        try container.encodeIfPresent(_jsonGuestControlProtocolVersion, forKey: .guestControlProtocolVersion)
        try container.encodeIfPresent(_jsonForkLayoutVersion, forKey: .forkLayoutVersion)
        try container.encodeIfPresent(_jsonCpuTemplate, forKey: .cpuTemplate)
    }

    var _jsonSizeBytes: Int64? {
        get { hasSizeBytes ? (sizeBytes) : nil }
        set { if let value = newValue { sizeBytes = value } else { clearSizeBytes() } }
    }
    var _jsonCurrentSizeBytes: Int64? {
        get { hasCurrentSizeBytes ? (currentSizeBytes) : nil }
        set { if let value = newValue { currentSizeBytes = value } else { clearCurrentSizeBytes() } }
    }
    var _jsonStoragePath: String? {
        get { hasStoragePath ? (storagePath) : nil }
        set { if let value = newValue { storagePath = value } else { clearStoragePath() } }
    }
    var _jsonArchitecture: CPUArchitecture? {
        get { hasArchitecture ? (architecture) : nil }
        set { if let value = newValue { architecture = value } else { clearArchitecture() } }
    }
    var _jsonQemuVersion: String? {
        get { hasQemuVersion ? (qemuVersion) : nil }
        set { if let value = newValue { qemuVersion = value } else { clearQemuVersion() } }
    }
    var _jsonFirecrackerVersion: String? {
        get { hasFirecrackerVersion ? (firecrackerVersion) : nil }
        set { if let value = newValue { firecrackerVersion = value } else { clearFirecrackerVersion() } }
    }
    var _jsonGuestControlProtocolVersion: Int? {
        get { hasGuestControlProtocolVersion ? (Int(guestControlProtocolVersion)) : nil }
        set {
            if let value = newValue {
                guestControlProtocolVersion = Int64(value)
            } else {
                clearGuestControlProtocolVersion()
            }
        }
    }
    var _jsonForkLayoutVersion: Int? {
        get { hasForkLayoutVersion ? (Int(forkLayoutVersion)) : nil }
        set { if let value = newValue { forkLayoutVersion = Int64(value) } else { clearForkLayoutVersion() } }
    }
    var _jsonCpuTemplate: String? {
        get { hasCpuTemplate ? (cpuTemplate) : nil }
        set { if let value = newValue { cpuTemplate = value } else { clearCpuTemplate() } }
    }
}

/// One snapshot artifact's state as actually observed on an agent (STR-150).
/// The convergence metadata matches `ObservedVMState` — see the doc comments
/// there.
public typealias ObservedSnapshotState = Strato_Agent_V1_ObservedSnapshotState
extension Strato_Agent_V1_ObservedSnapshotState: Codable {
    /// Whether the artifact's bytes exist on this host. A `false` entry is one
    /// the agent is listing because it is mid-capture or failed with nothing
    /// written — the mirror of the VM report's in-flight section. *Absence from
    /// the list* is what confirms a deletion; `present: false` explicitly does
    /// not.
    /// Whether this host has finished streaming the artifact to the export
    /// slots the sync asked for. False when no export was desired, when it has
    /// not finished, and when the copy was made by some other host — the
    /// control plane's own upload records are what say an exported copy is
    /// *complete*; this only says this agent believes it did its half.
    /// What the capture produced. Nil until the artifact exists.
    /// The desired-state generation this observation reflects (0 if none yet).
    /// Human-readable convergence stage ("capturing", "exporting", ...) while
    /// the agent is still working toward a newer generation. Progress only.
    /// The most recent convergence failure, if the last attempt failed.
    /// The generation whose convergence produced `lastError` (see
    /// `ObservedVMState.failedGeneration` for why the control plane needs it).
    /// Retry semantics for `lastError`; see
    /// `ObservedVMState.failureClassification`.

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
        self.init()
        self._jsonSnapshotId = snapshotId
        self._jsonKind = kind
        self._jsonParentId = parentId
        self._jsonPresent = present
        self._jsonExported = exported
        self._jsonFacts = facts
        self._jsonObservedGeneration = observedGeneration
        self._jsonConvergencePhase = convergencePhase
        self._jsonLastError = lastError
        self._jsonFailedGeneration = failedGeneration
        self._jsonFailureClassification = failureClassification
    }

    private enum CodingKeys: String, CodingKey {
        case snapshotId; case kind; case parentId; case present; case exported; case facts; case observedGeneration;
        case convergencePhase; case lastError; case failedGeneration; case failureClassification
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonSnapshotId = try container.decode(UUID.self, forKey: .snapshotId)
        self._jsonKind = try container.decode(SnapshotArtifactKind.self, forKey: .kind)
        self._jsonParentId = try container.decode(UUID.self, forKey: .parentId)
        self._jsonPresent = try container.decode(Bool.self, forKey: .present)
        self._jsonExported = try container.decode(Bool.self, forKey: .exported)
        self._jsonFacts = try container.decodeIfPresent(ObservedSnapshotFacts.self, forKey: .facts)
        self._jsonObservedGeneration = try container.decode(Int64.self, forKey: .observedGeneration)
        self._jsonConvergencePhase = try container.decodeIfPresent(String.self, forKey: .convergencePhase)
        self._jsonLastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        self._jsonFailedGeneration = try container.decodeIfPresent(Int64.self, forKey: .failedGeneration)
        self._jsonFailureClassification = try container.decodeIfPresent(
            ObservedFailureClassification.self, forKey: .failureClassification)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonSnapshotId, forKey: .snapshotId)
        try container.encode(_jsonKind, forKey: .kind)
        try container.encode(_jsonParentId, forKey: .parentId)
        try container.encode(_jsonPresent, forKey: .present)
        try container.encode(_jsonExported, forKey: .exported)
        try container.encodeIfPresent(_jsonFacts, forKey: .facts)
        try container.encode(_jsonObservedGeneration, forKey: .observedGeneration)
        try container.encodeIfPresent(_jsonConvergencePhase, forKey: .convergencePhase)
        try container.encodeIfPresent(_jsonLastError, forKey: .lastError)
        try container.encodeIfPresent(_jsonFailedGeneration, forKey: .failedGeneration)
        try container.encodeIfPresent(_jsonFailureClassification, forKey: .failureClassification)
    }

    var _jsonSnapshotId: UUID {
        get { UUID(uuidString: snapshotID) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) }
        set { let value = newValue; snapshotID = value.uuidString }
    }
    var _jsonKind: SnapshotArtifactKind {
        get { kind }
        set { let value = newValue; kind = value }
    }
    var _jsonParentId: UUID {
        get { UUID(uuidString: parentID) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) }
        set { let value = newValue; parentID = value.uuidString }
    }
    var _jsonPresent: Bool {
        get { present }
        set { let value = newValue; present = value }
    }
    var _jsonExported: Bool {
        get { exported }
        set { let value = newValue; exported = value }
    }
    var _jsonFacts: ObservedSnapshotFacts? {
        get { hasFacts ? (facts) : nil }
        set { if let value = newValue { facts = value } else { clearFacts() } }
    }
    var _jsonObservedGeneration: Int64 {
        get { observedGeneration }
        set { let value = newValue; observedGeneration = value }
    }
    var _jsonConvergencePhase: String? {
        get { hasConvergencePhase ? (convergencePhase) : nil }
        set { if let value = newValue { convergencePhase = value } else { clearConvergencePhase() } }
    }
    var _jsonLastError: String? {
        get { hasLastError ? (lastError) : nil }
        set { if let value = newValue { lastError = value } else { clearLastError() } }
    }
    var _jsonFailedGeneration: Int64? {
        get { hasFailedGeneration ? (failedGeneration) : nil }
        set { if let value = newValue { failedGeneration = value } else { clearFailedGeneration() } }
    }
    var _jsonFailureClassification: ObservedFailureClassification? {
        get { hasFailureClassification ? (failureClassification) : nil }
        set { if let value = newValue { failureClassification = value } else { clearFailureClassification() } }
    }
}
