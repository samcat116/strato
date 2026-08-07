import Fluent
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
final class SandboxSnapshot: Model, @unchecked Sendable {
    static let schema = "sandbox_snapshots"

    @ID(key: .id)
    var id: UUID?

    /// Optional operator label; defaults to a timestamp-derived name.
    @Field(key: "name")
    var name: String

    @Parent(key: "sandbox_id")
    var sandbox: Sandbox

    /// Project ownership, denormalized from the sandbox for querying and
    /// quota scoping (the volume-snapshot pattern).
    @Parent(key: "project_id")
    var project: Project

    /// The sandbox's environment at snapshot time, denormalized so quota
    /// resync can scope snapshot storage without joining sandboxes.
    @Field(key: "environment")
    var environment: String

    @Enum(key: "status")
    var status: SandboxSnapshotStatus

    /// Total artifact footprint (memory + vmstate + rootfs copy) in bytes.
    /// Written at admission with the quota estimate (the sandbox's guest
    /// memory — the memory file dominates), then overwritten with the actual
    /// sizes the agent reports. Quota resync sums this column for storage
    /// accounting.
    @OptionalField(key: "size")
    var size: Int64?

    /// The agent holding the artifacts. Restore placement is pinned here in
    /// v1. Recorded at creation from the sandbox's placement.
    @OptionalField(key: "agent_id")
    var agentId: String?

    /// The agent-owned directory holding the artifacts, as reported back.
    @OptionalField(key: "storage_path")
    var storagePath: String?

    // Compatibility constraints a restore must match.
    @OptionalField(key: "firecracker_version")
    var firecrackerVersion: String?

    @OptionalField(key: "architecture")
    var architecture: String?

    /// Guest init version frozen into memory. Nil means legacy/unknown and is
    /// intentionally ineligible for fork re-identification.
    @OptionalField(key: "guest_control_protocol_version")
    var guestControlProtocolVersion: Int?

    /// Version of the jailed, chroot-relative artifact layout required for a
    /// fork. Nil preserves legacy/unjailed checkpoints for in-place restore.
    @OptionalField(key: "fork_layout_version")
    var forkLayoutVersion: Int?

    /// Firecracker CPU template the checkpointed guest booted with (issue
    /// #428), agent-reported at creation. Nil means passthrough: the snapshot
    /// only restores on hosts whose CPU model equals `sourceCPUModel`.
    @OptionalField(key: "cpu_template")
    var cpuTemplate: String?

    /// CPU model string of the host the snapshot was taken on (from the
    /// agent's registration host info), recorded so an un-templated snapshot
    /// can be matched against a restore target's identical CPU. Nil when the
    /// source agent never reported host info — then only a templated snapshot
    /// is mobile.
    @OptionalField(key: "source_cpu_model")
    var sourceCPUModel: String?

    /// When the artifacts were last fully exported to control-plane object
    /// storage (issue #428). Nil means agent-local only: restore and fork
    /// stay pinned to `agentId`.
    @Timestamp(key: "exported_at", on: .none)
    var exportedAt: Date?

    /// Integrity record of the exported copy, one entry per artifact kind,
    /// written by the artifact upload route as each stream lands (sizes and
    /// SHA-256 are computed control-plane-side, never agent-supplied). The
    /// export operation only stamps `exportedAt` once every kind is present.
    @OptionalField(key: "exported_artifacts")
    var exportedArtifacts: [SandboxSnapshotExportedArtifact]?

    @OptionalField(key: "error_message")
    var errorMessage: String?

    // Desired/observed state split (ADR 0001 stage 8, STR-150).
    @Enum(key: "desired_status")
    var desiredStatus: DesiredSnapshotStatus

    @Field(key: "generation")
    var generation: Int64

    @Field(key: "observed_generation")
    var observedGeneration: Int64

    @OptionalField(key: "convergence_phase")
    var convergencePhase: String?

    @OptionalField(key: "failed_generation")
    var failedGeneration: Int64?

    @OptionalField(key: "convergence_deadline")
    var convergenceDeadline: Date?

    @Field(key: "finalizers")
    var finalizers: [String]

    /// Whether an exported copy in object storage is *wanted* (STR-150).
    ///
    /// Export used to be an imperative verb; it is a placement fact now — "this
    /// snapshot should also exist off-node" — carried to the agent on the
    /// desired entry and confirmed by `exportedAt` below. Sticky on purpose: a
    /// re-export after the agent's copy was lost is the same desire restated,
    /// not a new one.
    @Field(key: "export_desired")
    var exportDesired: Bool

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
    @Enum(key: "capture_mode")
    var captureMode: SandboxSnapshotMode

    /// When the retention sweep marks this snapshot `.absent`, or nil to keep
    /// it until someone deletes it (`SnapshotRetention`).
    @OptionalField(key: "expires_at")
    var expiresAt: Date?

    @Parent(key: "created_by_id")
    var createdBy: User

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        name: String,
        sandboxID: UUID,
        projectID: UUID,
        environment: String,
        agentId: String?,
        captureMode: SandboxSnapshotMode = .resume,
        expiresAt: Date? = nil,
        createdByID: UUID
    ) {
        self.id = id
        self.name = name
        self.$sandbox.id = sandboxID
        self.$project.id = projectID
        self.environment = environment
        self.status = .creating
        self.agentId = agentId
        self.desiredStatus = .present
        self.generation = 1
        self.observedGeneration = 0
        self.finalizers = []
        self.exportDesired = false
        self.captureMode = captureMode
        self.expiresAt = expiresAt
        self.$createdBy.id = createdByID
    }
}

extension SandboxSnapshot: Content {}

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
    var lastError: String? {
        get { errorMessage }
        set { errorMessage = newValue }
    }
}

extension SandboxSnapshot: SnapshotArtifactResource {
    static var artifactKind: SnapshotArtifactKind { .sandboxSnapshot }
    static var iamNodeType: IAMNodeType { .sandboxSnapshot }
    static var operationResourceKind: OperationResourceKind { .sandboxSnapshot }

    var projectID: UUID { $project.id }
    var parentID: UUID { $sandbox.id }
    var isPresentOnAgent: Bool { status == .ready }
    var wantsExport: Bool { exportDesired }

    /// An export is part of what this artifact's desired state asks for, so it
    /// is part of whether that state is satisfied — otherwise a client would
    /// see `converged` the moment the capture landed and have no way to wait
    /// for the copy it asked for in the same request.
    ///
    /// `isExported` rather than the agent's own report, deliberately: the
    /// agent's `exported` flag says it finished uploading, while this says the
    /// control plane has an integrity record for every artifact — computed from
    /// bytes it hashed itself as they landed, never from anything the agent
    /// claimed.
    var conditions: ResourceConditions {
        ResourceConditions(
            targetGeneration: generation,
            observedGeneration: observedGeneration,
            desiredSatisfied: isPresentOnAgent && (!exportDesired || isExported),
            phase: convergencePhase,
            lastError: errorMessage,
            failedGeneration: failedGeneration
        )
    }

    static func overdueForConvergence(at now: Date, on db: any Database) async throws -> [SandboxSnapshot] {
        try await SandboxSnapshot.query(on: db).filter(\.$convergenceDeadline <= now).all()
    }

    static func placed(onAgent agentId: String, on db: any Database) async throws -> [SandboxSnapshot] {
        try await SandboxSnapshot.query(on: db).filter(\.$agentId == agentId).all()
    }

    static func expired(at now: Date, on db: any Database) async throws -> [SandboxSnapshot] {
        try await SandboxSnapshot.query(on: db)
            .filter(\.$expiresAt <= now)
            .filter(\.$desiredStatus != DesiredSnapshotStatus.absent)
            .all()
    }

    static func terminating(on db: any Database) async throws -> [SandboxSnapshot] {
        try await SandboxSnapshot.query(on: db)
            .filter(\.$desiredStatus == DesiredSnapshotStatus.absent)
            .all()
    }

    func adoptReconciliationState(from committed: SandboxSnapshot) {
        status = committed.status
        desiredStatus = committed.desiredStatus
        generation = committed.generation
        observedGeneration = committed.observedGeneration
        convergencePhase = committed.convergencePhase
        errorMessage = committed.errorMessage
        failedGeneration = committed.failedGeneration
        convergenceDeadline = committed.convergenceDeadline
        agentId = committed.agentId
        size = committed.size
        storagePath = committed.storagePath
        firecrackerVersion = committed.firecrackerVersion
        architecture = committed.architecture
        guestControlProtocolVersion = committed.guestControlProtocolVersion
        forkLayoutVersion = committed.forkLayoutVersion
        cpuTemplate = committed.cpuTemplate
        sourceCPUModel = committed.sourceCPUModel
        captureMode = committed.captureMode
        exportDesired = committed.exportDesired
        exportedAt = committed.exportedAt
        exportedArtifacts = committed.exportedArtifacts
        finalizers = committed.finalizers
        expiresAt = committed.expiresAt
    }

    @discardableResult
    func applyCapturedFacts(_ facts: ObservedSnapshotFacts) -> Bool {
        var changed = false
        if let sizeBytes = facts.sizeBytes, size != sizeBytes {
            size = sizeBytes
            changed = true
        }
        if let path = facts.storagePath, storagePath != path {
            storagePath = path
            changed = true
        }
        if let version = facts.firecrackerVersion, firecrackerVersion != version {
            firecrackerVersion = version
            changed = true
        }
        if let architecture = facts.architecture?.rawValue, self.architecture != architecture {
            self.architecture = architecture
            changed = true
        }
        if let guestVersion = facts.guestControlProtocolVersion,
            guestControlProtocolVersion != guestVersion
        {
            guestControlProtocolVersion = guestVersion
            changed = true
        }
        if let layout = facts.forkLayoutVersion, forkLayoutVersion != layout {
            forkLayoutVersion = layout
            changed = true
        }
        if let template = facts.cpuTemplate, cpuTemplate != template {
            cpuTemplate = template
            changed = true
        }
        return changed
    }

    /// Deliberately does **not** stamp `exportedAt`.
    ///
    /// The agent saying "I uploaded" and the control plane having a complete,
    /// hashed copy are different claims, and only the second one may authorize
    /// a cross-agent restore. `exportedAt` is stamped by the artifact upload
    /// route once every kind has an integrity record the control plane computed
    /// itself — this only mirrors the agent's half so a re-driven sync does not
    /// re-upload an archive that already landed.
    @discardableResult
    func applyExported(_ exported: Bool) -> Bool { false }

    @discardableResult
    func applyObservedPresence(present: Bool, failed: Bool) -> Bool {
        let derived: SandboxSnapshotStatus =
            present ? .ready : (failed ? .error : (desiredStatus == .absent ? .deleting : .creating))
        guard status != derived else { return false }
        status = derived
        return true
    }
}

// MARK: - Request/Response DTOs

struct CreateSandboxSnapshotRequest: Content {
    let name: String?
    /// `true` checkpoints-and-stops: the sandbox converges to `stopped` after
    /// the snapshot instead of resuming. Defaults to `false` (resume).
    let stop: Bool?
    /// How long to keep the snapshot, in seconds. Omitted uses the fleet
    /// default (`SNAPSHOT_DEFAULT_TTL_SECONDS`, unset by default); `0` keeps it
    /// until someone deletes it, overriding that default.
    let ttlSeconds: Int?
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
        self.sandboxId = snapshot.$sandbox.id
        self.projectId = snapshot.$project.id
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
        self.createdById = snapshot.$createdBy.id
        self.createdAt = snapshot.createdAt
    }
}
