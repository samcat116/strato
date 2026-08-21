import ControlPlanePostgres
import Foundation
import StratoShared
import Vapor

/// Lifecycle of a sandbox snapshot (issue #426).
///
/// Purely *observed* since STR-150, like `VolumeStatus` after STR-148: the
/// control plane no longer writes a transitional status before dispatching an
/// RPC, because there is no RPC. `ObservedStateApplier` derives this from what
/// the owning agent reports about the artifacts.
enum SandboxSnapshotStatus: String, Codable, CaseIterable, Sendable {
    case creating
    case ready
    case deleting
    case error
}

/// A checkpoint of a sandbox (issue #426): guest memory + VMM state captured
/// via the Firecracker snapshot API, plus a consistent copy of the rootfs
/// taken while the guest was paused. Firecracker snapshots are tied to the
/// Firecracker version, host CPU, and device topology they were taken with,
/// so the row records those compatibility constraints alongside placement.
///
/// Artifacts live in agent-owned storage beside the sandbox, so restore and
/// fork placement stay pinned to `agentId`. A snapshot can restore its source
/// in place or seed a new sandbox identity (issue #427); off-node export and
/// cross-agent restore remain issue #428.
struct SandboxSnapshot: Content, Sendable {
    static let schema = "sandbox_snapshots"

    let id: UUID?
    let name: String
    let sandboxID: UUID

    /// Project ownership, denormalized from the sandbox for querying and
    /// quota scoping (the volume-snapshot pattern).
    let projectID: UUID

    /// The sandbox's environment at snapshot time, denormalized so quota
    /// resync can scope snapshot storage without joining sandboxes.
    let environment: String
    let status: SandboxSnapshotStatus

    /// Total artifact footprint (memory + vmstate + rootfs copy) in bytes.
    /// Written at admission with the quota estimate (the sandbox's guest
    /// memory — the memory file dominates), then overwritten with the actual
    /// sizes the agent reports. Quota resync sums this column for storage
    /// accounting.
    let size: Int64?

    /// The agent holding the artifacts. Restore placement is pinned here in
    /// v1. Recorded at creation from the sandbox's placement.
    let agentId: String?

    /// The agent-owned directory holding the artifacts, as reported back.
    let storagePath: String?

    // Compatibility constraints a restore must match.
    let firecrackerVersion: String?
    let architecture: String?

    /// Guest init version frozen into memory. Nil means legacy/unknown and is
    /// retained only for inventory/deletion; restore and fork reject it.
    let guestControlProtocolVersion: Int?

    /// Version of the jailed, chroot-relative artifact layout required for a
    /// fork. Nil preserves legacy/unjailed checkpoints for in-place restore.
    let forkLayoutVersion: Int?

    /// Firecracker CPU template the checkpointed guest booted with (issue
    /// #428), agent-reported at creation. Nil means passthrough: the snapshot
    /// only restores on hosts whose CPU model equals `sourceCPUModel`.
    let cpuTemplate: String?

    /// CPU model string of the host the snapshot was taken on (from the
    /// agent's registration host info), recorded so an un-templated snapshot
    /// can be matched against a restore target's identical CPU. Nil when the
    /// source agent never reported host info — then only a templated snapshot
    /// is mobile.
    let sourceCPUModel: String?

    /// When the artifacts were last fully exported to control-plane object
    /// storage (issue #428). Nil means agent-local only: restore and fork
    /// stay pinned to `agentId`.
    let exportedAt: Date?

    /// Integrity record of the exported copy, one entry per artifact kind,
    /// written by the artifact upload route as each stream lands (sizes and
    /// SHA-256 are computed control-plane-side, never agent-supplied). The
    /// export operation only stamps `exportedAt` once every kind is present.
    let exportedArtifacts: [SandboxSnapshotExportedArtifact]?
    let errorMessage: String?

    // Desired/observed state split (ADR 0001 stage 8, STR-150).
    let desiredStatus: DesiredSnapshotStatus
    let generation: Int64
    let observedGeneration: Int64
    let convergencePhase: String?
    let failedGeneration: Int64?
    let convergenceDeadline: Date?
    let finalizers: [String]

    /// Whether an exported copy in object storage is *wanted* (STR-150).
    ///
    /// Export used to be an imperative verb; it is a placement fact now — "this
    /// snapshot should also exist off-node" — carried to the agent on the
    /// desired entry and confirmed by `exportedAt` below. Sticky on purpose: a
    /// re-export after the agent's copy was lost is the same desire restated,
    /// not a new one.
    let exportDesired: Bool

    /// How the guest proceeds once the checkpoint is captured: resume, or stay
    /// stopped (checkpoint-and-stop).
    ///
    /// Persisted, not derived from the request, because it is a *create
    /// strategy* the agent reads off the desired entry — and a desired entry is
    /// re-assembled on every sync, including ones long after the request that
    /// made it. A capture still pending across a control-plane restart would
    /// otherwise silently become a resume.
    ///
    /// Read only while the artifact is absent from the host, which is what makes
    /// it safe for a replayed sync to carry: it can never re-pause a guest whose
    /// checkpoint already exists. The sandbox's own `desiredStatus` carries the
    /// lasting half of "and stop", written in the same transaction.
    let captureMode: SandboxSnapshotMode

    /// When the retention sweep marks this snapshot `.absent`, or nil to keep
    /// it until someone deletes it (`SnapshotRetention`).
    let expiresAt: Date?
    let createdByID: UUID
    let createdAt: Date?
    let updatedAt: Date?

    init(
        id: UUID? = UUID(),
        name: String,
        sandboxID: UUID,
        projectID: UUID,
        environment: String,
        status: SandboxSnapshotStatus = .creating,
        size: Int64? = nil,
        agentId: String?,
        storagePath: String? = nil,
        firecrackerVersion: String? = nil,
        architecture: String? = nil,
        guestControlProtocolVersion: Int? = nil,
        forkLayoutVersion: Int? = nil,
        cpuTemplate: String? = nil,
        sourceCPUModel: String? = nil,
        exportedAt: Date? = nil,
        exportedArtifacts: [SandboxSnapshotExportedArtifact]? = nil,
        errorMessage: String? = nil,
        desiredStatus: DesiredSnapshotStatus = .present,
        generation: Int64 = 1,
        observedGeneration: Int64 = 0,
        convergencePhase: String? = nil,
        failedGeneration: Int64? = nil,
        convergenceDeadline: Date? = nil,
        finalizers: [String] = [],
        exportDesired: Bool = false,
        captureMode: SandboxSnapshotMode = .resume,
        expiresAt: Date? = nil,
        createdByID: UUID,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.sandboxID = sandboxID
        self.projectID = projectID
        self.environment = environment
        self.status = status
        self.size = size
        self.agentId = agentId
        self.storagePath = storagePath
        self.firecrackerVersion = firecrackerVersion
        self.architecture = architecture
        self.guestControlProtocolVersion = guestControlProtocolVersion
        self.forkLayoutVersion = forkLayoutVersion
        self.cpuTemplate = cpuTemplate
        self.sourceCPUModel = sourceCPUModel
        self.exportedAt = exportedAt
        self.exportedArtifacts = exportedArtifacts
        self.errorMessage = errorMessage
        self.desiredStatus = desiredStatus
        self.generation = generation
        self.observedGeneration = observedGeneration
        self.convergencePhase = convergencePhase
        self.failedGeneration = failedGeneration
        self.convergenceDeadline = convergenceDeadline
        self.finalizers = finalizers
        self.exportDesired = exportDesired
        self.captureMode = captureMode
        self.expiresAt = expiresAt
        self.createdByID = createdByID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func requireID() throws -> UUID {
        guard let id else {
            throw Abort(.internalServerError, reason: "Sandbox snapshot has no identifier")
        }
        return id
    }

    func persisted(on db: PostgresStoreContext) async throws -> Self {
        try await LegacySandboxSnapshotStore.upsert(self, on: db)
    }
    func persist(on db: PostgresStoreContext) async throws { _ = try await persisted(on: db) }
    func save(on db: PostgresStoreContext) async throws { try await persist(on: db) }
    func remove(on db: PostgresStoreContext) async throws {
        guard let id else { return }
        _ = try await LegacySandboxSnapshotStore.delete(id: id, on: db)
    }
    func delete(on db: PostgresStoreContext) async throws { try await remove(on: db) }
    static func load(_ id: UUID?, on db: PostgresStoreContext) async throws -> Self? {
        try await LegacySandboxSnapshotStore.snapshot(id: id, on: db)
    }
    static func find(_ id: UUID?, on db: PostgresStoreContext) async throws -> Self? {
        try await load(id, on: db)
    }

    static func all(on db: PostgresStoreContext) async throws -> [Self] {
        try await LegacySandboxSnapshotStore.snapshots(on: db)
    }

    func replacing(
        status: SandboxSnapshotStatus? = nil,
        size: Int64?? = nil,
        agentId: String?? = nil,
        storagePath: String?? = nil,
        firecrackerVersion: String?? = nil,
        architecture: String?? = nil,
        guestControlProtocolVersion: Int?? = nil,
        forkLayoutVersion: Int?? = nil,
        cpuTemplate: String?? = nil,
        sourceCPUModel: String?? = nil,
        exportedAt: Date?? = nil,
        exportedArtifacts: [SandboxSnapshotExportedArtifact]?? = nil,
        errorMessage: String?? = nil,
        desiredStatus: DesiredSnapshotStatus? = nil,
        generation: Int64? = nil,
        observedGeneration: Int64? = nil,
        convergencePhase: String?? = nil,
        failedGeneration: Int64?? = nil,
        convergenceDeadline: Date?? = nil,
        finalizers: [String]? = nil,
        exportDesired: Bool? = nil,
        expiresAt: Date?? = nil
    ) -> Self {
        Self(
            id: id, name: name, sandboxID: sandboxID, projectID: projectID,
            environment: environment, status: status ?? self.status,
            size: size ?? self.size, agentId: agentId ?? self.agentId,
            storagePath: storagePath ?? self.storagePath,
            firecrackerVersion: firecrackerVersion ?? self.firecrackerVersion,
            architecture: architecture ?? self.architecture,
            guestControlProtocolVersion:
                guestControlProtocolVersion ?? self.guestControlProtocolVersion,
            forkLayoutVersion: forkLayoutVersion ?? self.forkLayoutVersion,
            cpuTemplate: cpuTemplate ?? self.cpuTemplate,
            sourceCPUModel: sourceCPUModel ?? self.sourceCPUModel,
            exportedAt: exportedAt ?? self.exportedAt,
            exportedArtifacts: exportedArtifacts ?? self.exportedArtifacts,
            errorMessage: errorMessage ?? self.errorMessage,
            desiredStatus: desiredStatus ?? self.desiredStatus,
            generation: generation ?? self.generation,
            observedGeneration: observedGeneration ?? self.observedGeneration,
            convergencePhase: convergencePhase ?? self.convergencePhase,
            failedGeneration: failedGeneration ?? self.failedGeneration,
            convergenceDeadline: convergenceDeadline ?? self.convergenceDeadline,
            finalizers: finalizers ?? self.finalizers,
            exportDesired: exportDesired ?? self.exportDesired, captureMode: captureMode,
            expiresAt: expiresAt ?? self.expiresAt, createdByID: createdByID,
            createdAt: createdAt, updatedAt: updatedAt)
    }
}

/// One artifact of the exported copy in object storage: what landed under the
/// snapshot's object prefix and what any later download must verify to.
struct SandboxSnapshotExportedArtifact: Codable, Equatable, Sendable {
    let kind: SandboxSnapshotArtifactKind
    let sizeBytes: Int64
    /// Lowercase hex SHA-256 of the stored bytes.
    let sha256: String
}

extension SandboxSnapshot {
    var isReady: Bool { status == .ready && desiredStatus == .present }

    var canRestore: Bool { isReady }

    /// Deletable in any state, for `VMSnapshot.canDelete`'s reason: deletion is
    /// level-triggered and the agent's teardown is idempotent, so re-issuing it
    /// is always safe. (The lineage guard in `SandboxSnapshotController` still
    /// refuses a snapshot with live forks — that is a data-dependency rule, not
    /// a lifecycle one.)
    var canDelete: Bool { true }

    /// Whether a complete exported copy exists in object storage: the export
    /// completed (`exportedAt`) and every artifact kind has an integrity
    /// record to hand to a downloading agent.
    var isExported: Bool {
        guard exportedAt != nil, let exportedArtifacts else { return false }
        let kinds = Set(exportedArtifacts.map(\.kind))
        return SandboxSnapshotArtifactKind.allCases.allSatisfy { kinds.contains($0) }
    }

    func exportedArtifact(for kind: SandboxSnapshotArtifactKind) -> SandboxSnapshotExportedArtifact? {
        exportedArtifacts?.first { $0.kind == kind }
    }
}

// MARK: - Conditions and convergence (STR-150)

extension SandboxSnapshot: ConvergenceObservable {
    var lastError: String? { errorMessage }

    func replacingConvergence(
        phase: String?, lastError: String?, failedGeneration: Int64?
    ) -> Self {
        replacing(
            errorMessage: .some(lastError), convergencePhase: .some(phase),
            failedGeneration: .some(failedGeneration))
    }
}

extension SandboxSnapshot: SnapshotArtifactResource {
    static var artifactKind: SnapshotArtifactKind { .sandboxSnapshot }
    static var iamNodeType: IAMNodeType { .sandboxSnapshot }
    static var operationResourceKind: OperationResourceKind { .sandboxSnapshot }

    var parentID: UUID { sandboxID }
    var isPresentOnAgent: Bool { status == .ready }
    var wantsExport: Bool { exportDesired }

    /// `isExported` rather than the agent's own `exported` flag, deliberately:
    /// the agent's says it finished uploading, while this says the control
    /// plane holds an integrity record for every artifact — computed from bytes
    /// it hashed itself as they landed, never from anything the agent claimed.
    var exportSatisfied: Bool { !exportDesired || isExported }

    var storageQuotaScope: (projectID: UUID, environment: String)? {
        (projectID, environment)
    }

    static func overdueForConvergence(at now: Date, on db: PostgresStoreContext) async throws -> [SandboxSnapshot] {
        try await LegacySandboxSnapshotStore.snapshots(overdueAt: now, on: db)
    }

    static func placed(onAgent agentId: String, on db: PostgresStoreContext) async throws -> [SandboxSnapshot] {
        try await LegacySandboxSnapshotStore.snapshots(agentID: agentId, on: db)
    }

    static func matching(ids: [UUID], on db: PostgresStoreContext) async throws -> [SandboxSnapshot] {
        try await LegacySandboxSnapshotStore.snapshots(ids: ids, on: db)
    }

    static func expired(at now: Date, on db: PostgresStoreContext) async throws -> [SandboxSnapshot] {
        try await LegacySandboxSnapshotStore.snapshots(expiredAt: now, on: db)
    }

    static func terminating(on db: PostgresStoreContext) async throws -> [SandboxSnapshot] {
        try await LegacySandboxSnapshotStore.snapshots(terminating: true, on: db)
    }

    func adoptingReconciliationState(from committed: SandboxSnapshot) -> Self { committed }
    func replacingGeneration(_ generation: Int64) -> Self { replacing(generation: generation) }
    func replacingConvergenceDeadline(_ deadline: Date?) -> Self {
        replacing(convergenceDeadline: .some(deadline))
    }
    func replacingFinalizers(_ finalizers: [String]) -> Self { replacing(finalizers: finalizers) }
    func replacingAgentID(_ agentID: String?) -> Self { replacing(agentId: .some(agentID)) }
    func replacingDesiredStatus(_ status: DesiredSnapshotStatus) -> Self {
        replacing(desiredStatus: status)
    }
    func replacingObservedGeneration(_ generation: Int64) -> Self {
        replacing(observedGeneration: generation)
    }
    func replacingExpiration(_ expiresAt: Date?) -> Self { replacing(expiresAt: .some(expiresAt)) }
    func resolvingForStuckOperation(
        mutation: VMOperationKind, telemetryReason: String
    ) -> (resource: Self, desiredStateChanged: Bool) {
        (self, false)
    }

    func recordingCapturedFacts(
        _ facts: ObservedSnapshotFacts
    ) -> (resource: Self, changed: Bool) {
        var next = self
        var changed = false
        if let sizeBytes = facts.sizeBytes, size != sizeBytes {
            next = next.replacing(size: .some(sizeBytes))
            changed = true
        }
        if let path = facts.storagePath, storagePath != path {
            next = next.replacing(storagePath: .some(path))
            changed = true
        }
        if let version = facts.firecrackerVersion, firecrackerVersion != version {
            next = next.replacing(firecrackerVersion: .some(version))
            changed = true
        }
        if let architecture = facts.architecture?.rawValue, self.architecture != architecture {
            next = next.replacing(architecture: .some(architecture))
            changed = true
        }
        if let guestVersion = facts.guestControlProtocolVersion,
            guestControlProtocolVersion != guestVersion
        {
            next = next.replacing(guestControlProtocolVersion: .some(guestVersion))
            changed = true
        }
        if let layout = facts.forkLayoutVersion, forkLayoutVersion != layout {
            next = next.replacing(forkLayoutVersion: .some(layout))
            changed = true
        }
        if let template = facts.cpuTemplate, cpuTemplate != template {
            next = next.replacing(cpuTemplate: .some(template))
            changed = true
        }
        return (next, changed)
    }

    /// The agent's export report is deliberately **not** mirrored onto the row.
    ///
    /// "I uploaded" and "the control plane holds a complete, hashed copy" are
    /// different claims, and only the second may authorize a cross-agent
    /// restore. `exportedAt` is stamped by the artifact upload route, on the PUT
    /// that completes the set, from bytes it hashed itself.
    ///
    /// Nothing is lost by ignoring the agent's half: what keeps a re-driven sync
    /// from re-uploading an archive that already landed is the agent's own
    /// durable `SnapshotRecord.exported`, which never leaves the host.
    func recordingExported(_ exported: Bool) -> (resource: Self, changed: Bool) { (self, false) }

    func recordingObservedPresence(
        present: Bool, failed: Bool
    ) -> (resource: Self, changed: Bool) {
        let derived: SandboxSnapshotStatus =
            present ? .ready : (failed ? .error : (desiredStatus == .absent ? .deleting : .creating))
        guard status != derived else { return (self, false) }
        return (replacing(status: derived), true)
    }
}

// MARK: - Request/Response DTOs

struct CreateSandboxSnapshotRequest: Content, ValidatedRequestBody {
    var name: String?
    /// `true` checkpoints-and-stops: the sandbox converges to `stopped` after
    /// the snapshot instead of resuming. Defaults to `false` (resume).
    let stop: Bool?
    /// How long to keep the snapshot, in seconds. Omitted uses the fleet
    /// default (`SNAPSHOT_DEFAULT_TTL_SECONDS`, unset by default); `0` keeps it
    /// until someone deletes it, overriding that default.
    let ttlSeconds: Int?

    mutating func validate() throws {
        name = try Validate.name(name)
    }
}

struct SandboxSnapshotResponse: Content {
    let id: UUID?
    let name: String
    let sandboxId: UUID?
    let projectId: UUID?
    let status: SandboxSnapshotStatus
    let size: Int64?
    let agentId: String?
    let firecrackerVersion: String?
    let architecture: String?
    let guestControlProtocolVersion: Int?
    let forkLayoutVersion: Int?
    let cpuTemplate: String?
    /// Whether an exported copy is wanted (STR-150). `exportedAt` is when one
    /// last completed; the pair is the desired/observed split for mobility.
    let exportDesired: Bool
    /// When the artifacts were last fully exported to object storage; nil for
    /// an agent-local snapshot (issue #428).
    let exportedAt: Date?
    let errorMessage: String?
    /// When retention will delete this snapshot; nil means it is kept until
    /// someone deletes it.
    let expiresAt: Date?
    /// What clients poll instead of `status` (ADR 0001 stage 1, STR-150).
    let conditions: ResourceConditions
    let createdById: UUID?
    let createdAt: Date?

    init(from snapshot: SandboxSnapshot) {
        self.id = snapshot.id
        self.name = snapshot.name
        self.sandboxId = snapshot.sandboxID
        self.projectId = snapshot.projectID
        self.status = snapshot.status
        self.size = snapshot.size
        self.agentId = snapshot.agentId
        self.firecrackerVersion = snapshot.firecrackerVersion
        self.architecture = snapshot.architecture
        self.guestControlProtocolVersion = snapshot.guestControlProtocolVersion
        self.forkLayoutVersion = snapshot.forkLayoutVersion
        self.cpuTemplate = snapshot.cpuTemplate
        self.exportDesired = snapshot.exportDesired
        self.exportedAt = snapshot.exportedAt
        self.errorMessage = snapshot.errorMessage
        self.expiresAt = snapshot.expiresAt
        self.conditions = snapshot.conditions
        self.createdById = snapshot.createdByID
        self.createdAt = snapshot.createdAt
    }
}
