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

    // VM checkpoints (issue #564).

    // Sandbox snapshots (issues #426, #427, #428).

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

}

/// One snapshot artifact's state as actually observed on an agent (STR-150).
/// The convergence metadata matches `ObservedVMState` — see the doc comments
/// there.
public typealias ObservedSnapshotState = Strato_Agent_V1_ObservedSnapshotState
extension Strato_Agent_V1_ObservedSnapshotState: Codable {

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

}
