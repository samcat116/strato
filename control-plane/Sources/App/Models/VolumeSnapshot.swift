import Fluent
import Foundation
import StratoShared
import Vapor

/// Lifecycle of a volume snapshot.
///
/// Purely *observed* since STR-150, like `VolumeStatus` after STR-148: the
/// control plane no longer writes a transitional status before dispatching an
/// RPC, because there is no RPC. `ObservedStateApplier` derives this from what
/// the owning agent reports about the bytes. `restoring` is retained for API
/// compatibility and is never written.
public enum SnapshotStatus: String, Codable, CaseIterable, Sendable {
    case creating = "creating"  // Snapshot is being captured
    case available = "available"  // Snapshot is ready for use
    case restoring = "restoring"  // Unused since STR-150; kept for API compatibility
    case deleting = "deleting"  // Snapshot is being deleted
    case error = "error"  // An error occurred
}

/// A point-in-time copy of one volume's data: an external qcow2 overlay whose
/// backing file is the volume, written by the agent's storage backend.
///
/// A durable artifact on a specific agent since STR-150 — desired state the
/// owning agent converges on and confirms, not the result of an RPC.
final class VolumeSnapshot: Model, @unchecked Sendable {
    static let schema = "volume_snapshots"

    @ID(key: .id)
    var id: UUID?

    // Basic metadata
    @Field(key: "name")
    var name: String

    @Field(key: "description")
    var description: String

    // Parent volume
    @Parent(key: "volume_id")
    var volume: Volume

    // Project ownership (denormalized for easier querying)
    @Parent(key: "project_id")
    var project: Project

    /// The parent volume's environment at capture time, denormalized so quota
    /// resync can measure the snapshot after the volume is gone — the same
    /// reason `VMSnapshot` and `SandboxSnapshot` carry one (STR-181).
    @Field(key: "environment")
    var environment: String

    // Snapshot specifications
    /// The volume's size when the snapshot was taken. Not a footprint: it is
    /// what a restore needs to size its target, and it is also the *admission*
    /// estimate the storage quota charges until the agent reports a real one —
    /// an overlay cannot outgrow the volume behind it.
    @Field(key: "size")
    var size: Int64

    /// What the overlay actually occupies right now, as the owning agent
    /// re-measures it on every report (STR-181, wire v39).
    ///
    /// This is the figure the storage quota charges, falling back to `size` when
    /// it is nil. Nil is "no agent has said" — the bytes are not on a host yet,
    /// or the agent predates v39 — never zero, so a silent agent leaves the
    /// admission estimate standing rather than making the snapshot free.
    ///
    /// Separate from `size` because the two answer different questions and the
    /// overlay's answer keeps changing: `size` is frozen at capture and a restore
    /// depends on it, while this grows as the volume diverges.
    @OptionalField(key: "observed_size_bytes")
    var observedSizeBytes: Int64?

    // Status tracking
    @Enum(key: "status")
    var status: SnapshotStatus

    @OptionalField(key: "error_message")
    var errorMessage: String?

    /// Where the agent put the overlay. The agent owns path layout, so this is
    /// the only direction a snapshot path travels: the control plane stores
    /// what it is told and never derives one.
    @OptionalField(key: "storage_path")
    var storagePath: String?

    /// The agent holding the overlay (STR-150). A volume snapshot's placement
    /// used to be re-derived from its volume's replica on every request; it is
    /// recorded now, because a desired entry has to appear in exactly one
    /// agent's sync and a volume that moves must not silently orphan its
    /// snapshots into another host's tombstone set.
    @OptionalField(key: "agent_id")
    var agentId: String?

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

    /// When the retention sweep marks this snapshot `.absent`, or nil to keep
    /// it until someone deletes it (`SnapshotRetention`).
    @OptionalField(key: "expires_at")
    var expiresAt: Date?

    // Owner tracking
    @Parent(key: "created_by_id")
    var createdBy: User

    // Timestamp
    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        name: String,
        description: String,
        volumeID: UUID,
        projectID: UUID,
        environment: String,
        size: Int64,
        agentId: String? = nil,
        expiresAt: Date? = nil,
        createdByID: UUID
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.$volume.id = volumeID
        self.$project.id = projectID
        self.environment = environment
        self.size = size
        self.status = .creating
        self.agentId = agentId
        self.desiredStatus = .present
        self.generation = 1
        self.observedGeneration = 0
        self.finalizers = []
        self.expiresAt = expiresAt
        self.$createdBy.id = createdByID
    }
}

extension VolumeSnapshot: Content {}

// MARK: - Public DTO

extension VolumeSnapshot {
    struct Public: Content {
        let id: UUID?
        let name: String
        let description: String
        let volumeId: UUID?
        let projectId: UUID?
        let size: Int64
        let sizeGB: Double
        let status: SnapshotStatus
        let errorMessage: String?
        let storagePath: String?
        let agentId: String?
        let expiresAt: Date?
        let conditions: ResourceConditions
        let createdById: UUID?
        let createdAt: Date?
    }

    func asPublic() -> Public {
        return Public(
            id: self.id,
            name: self.name,
            description: self.description,
            volumeId: self.$volume.id,
            projectId: self.$project.id,
            size: self.size,
            sizeGB: Double(size) / 1024.0 / 1024.0 / 1024.0,
            status: self.status,
            errorMessage: self.errorMessage,
            storagePath: self.storagePath,
            agentId: self.agentId,
            expiresAt: self.expiresAt,
            conditions: self.conditions,
            createdById: self.$createdBy.id,
            createdAt: self.createdAt
        )
    }
}

// MARK: - Computed Properties

extension VolumeSnapshot {
    /// Deletable in any state, for `VMSnapshot.canDelete`'s reason: deletion is
    /// level-triggered and the agent's teardown is idempotent.
    var canDelete: Bool { true }
}

// MARK: - Conditions and convergence (STR-150)

extension VolumeSnapshot: ConvergenceObservable {
    var lastError: String? {
        get { errorMessage }
        set { errorMessage = newValue }
    }
}

extension VolumeSnapshot: SnapshotArtifactResource {
    static var artifactKind: SnapshotArtifactKind { .volumeSnapshot }
    static var iamNodeType: IAMNodeType { .volumeSnapshot }
    static var operationResourceKind: OperationResourceKind { .volumeSnapshot }

    var projectID: UUID { $project.id }
    var parentID: UUID { $volume.id }
    var isPresentOnAgent: Bool { status == .available }

    /// An overlay is meaningless without the backing chain it points at, so
    /// there is nothing coherent to upload off-node.
    var wantsExport: Bool { false }

    /// Nil deliberately, even though a volume snapshot *does* draw on the
    /// storage pool now (STR-181).
    ///
    /// What this scope arms is `enforceStorageQuota`, which **deletes** an
    /// artifact whose real footprint put an enabled quota over its limit. That
    /// contract exists for the one-shot estimate→truth jump at capture, where a
    /// sandbox snapshot can land several times the size admission reserved: it
    /// fires once, on a number that then stops moving. An overlay's number never
    /// stops moving, so arming it here would re-run the check on every report and
    /// start destroying snapshots because their volume diverged — a far worse
    /// outcome than the overage, and one the user did nothing to cause.
    ///
    /// Enforcement stays at admission, which is why `reserveVolumeSnapshot`
    /// checks the parent volume's *whole* size rather than the overlay's: a
    /// snapshot cannot be admitted unless the pool could absorb it fully grown.
    var storageQuotaScope: (projectID: UUID, environment: String)? { nil }

    static func overdueForConvergence(at now: Date, on db: any Database) async throws -> [VolumeSnapshot] {
        try await VolumeSnapshot.query(on: db).filter(\.$convergenceDeadline <= now).all()
    }

    static func placed(onAgent agentId: String, on db: any Database) async throws -> [VolumeSnapshot] {
        try await VolumeSnapshot.query(on: db).filter(\.$agentId == agentId).all()
    }

    static func expired(at now: Date, on db: any Database) async throws -> [VolumeSnapshot] {
        try await VolumeSnapshot.query(on: db)
            .filter(\.$expiresAt <= now)
            .filter(\.$desiredStatus != DesiredSnapshotStatus.absent)
            .all()
    }

    static func terminating(on db: any Database) async throws -> [VolumeSnapshot] {
        try await VolumeSnapshot.query(on: db)
            .filter(\.$desiredStatus == DesiredSnapshotStatus.absent)
            .all()
    }

    func adoptReconciliationState(from committed: VolumeSnapshot) {
        status = committed.status
        desiredStatus = committed.desiredStatus
        generation = committed.generation
        observedGeneration = committed.observedGeneration
        convergencePhase = committed.convergencePhase
        errorMessage = committed.errorMessage
        failedGeneration = committed.failedGeneration
        convergenceDeadline = committed.convergenceDeadline
        agentId = committed.agentId
        storagePath = committed.storagePath
        observedSizeBytes = committed.observedSizeBytes
        finalizers = committed.finalizers
        expiresAt = committed.expiresAt
    }

    /// How much the reported footprint has to move before it is worth a row
    /// write (STR-181).
    ///
    /// A report goes out every 20 seconds, and event-driven ones coalesce at
    /// 500 ms, so an overlay under active write would otherwise cost an `UPDATE`
    /// per snapshot per report for a figure that feeds a byte quota displayed in
    /// GiB. A megabyte of hysteresis buys back all of that and costs nothing any
    /// reader can see.
    static let footprintReportGranularity: Int64 = 1 << 20

    @discardableResult
    func applyCapturedFacts(_ facts: ObservedSnapshotFacts) -> Bool {
        var changed = false
        if let path = facts.storagePath, storagePath != path {
            storagePath = path
            changed = true
        }
        // `currentSizeBytes`, never `sizeBytes` — and never into `size`.
        //
        // `size` means "how big the volume was when the snapshot was taken",
        // which is what a restore needs to size its target and what the quota
        // charges until a real figure arrives. What the agent measures is the
        // *overlay's* footprint, a different number that grows as the volume
        // diverges, so it lands in its own column. `sizeBytes` is that same
        // measurement taken at capture, when the overlay is an empty file, and
        // is still ignored: a pre-v39 agent reports only that one, and reading
        // it would make every snapshot it holds cost ~200 KB.
        if let footprint = facts.currentSizeBytes,
            observedSizeBytes.map({ abs(footprint - $0) >= Self.footprintReportGranularity }) ?? true
        {
            observedSizeBytes = footprint
            changed = true
        }
        return changed
    }

    @discardableResult
    func applyExported(_ exported: Bool) -> Bool { false }

    @discardableResult
    func applyObservedPresence(present: Bool, failed: Bool) -> Bool {
        let derived: SnapshotStatus =
            present ? .available : (failed ? .error : (desiredStatus == .absent ? .deleting : .creating))
        guard status != derived else { return false }
        status = derived
        return true
    }
}

// MARK: - Request/Response DTOs

struct CreateSnapshotRequest: Content, ValidatedRequestBody {
    var name: String
    let description: String?
    /// How long to keep the snapshot, in seconds. Omitted uses the fleet
    /// default (`SNAPSHOT_DEFAULT_TTL_SECONDS`, unset by default); `0` keeps it
    /// until someone deletes it, overriding that default.
    let ttlSeconds: Int?

    mutating func validate() throws {
        name = try Validate.name(name)
        try Validate.text(description)
    }
}

struct SnapshotResponse: Content {
    let id: UUID?
    let name: String
    let description: String
    let volumeId: UUID?
    let projectId: UUID?
    /// The project environment this snapshot's bytes are charged to (STR-181).
    let environment: String
    /// The parent volume's size when the snapshot was taken — what a restore
    /// sizes its target to, and what the storage quota admits against.
    let size: Int64
    let sizeFormatted: String
    /// What the overlay actually occupies, as last reported by the owning agent
    /// (STR-181). Null means no agent has said — the bytes are not on a host
    /// yet, or the agent predates wire v39 — in which case the quota charges
    /// `size` instead.
    let observedSize: Int64?
    let observedSizeFormatted: String?
    let status: SnapshotStatus
    let errorMessage: String?
    let agentId: String?
    /// When retention will delete this snapshot; nil means it is kept until
    /// someone deletes it.
    let expiresAt: Date?
    /// What clients poll instead of `status` (ADR 0001 stage 1, STR-150).
    let conditions: ResourceConditions
    let createdById: UUID?
    let createdAt: Date?

    init(from snapshot: VolumeSnapshot) {
        self.id = snapshot.id
        self.name = snapshot.name
        self.description = snapshot.description
        self.volumeId = snapshot.$volume.id
        self.projectId = snapshot.$project.id
        self.environment = snapshot.environment
        self.size = snapshot.size
        self.sizeFormatted = snapshot.size.formattedByteSize
        self.observedSize = snapshot.observedSizeBytes
        self.observedSizeFormatted = snapshot.observedSizeBytes?.formattedByteSize
        self.status = snapshot.status
        self.errorMessage = snapshot.errorMessage
        self.agentId = snapshot.agentId
        self.expiresAt = snapshot.expiresAt
        self.conditions = snapshot.conditions
        self.createdById = snapshot.$createdBy.id
        self.createdAt = snapshot.createdAt
    }
}
