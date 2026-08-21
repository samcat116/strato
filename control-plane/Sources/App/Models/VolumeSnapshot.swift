import ControlPlanePostgres
import Foundation
import StratoShared
import Vapor

/// Lifecycle of a volume snapshot.
///
/// Purely *observed* since STR-150, like `VolumeStatus` after STR-148: the
/// control plane no longer writes a transitional status before dispatching an
/// RPC, because there is no RPC. `ObservedStateApplier` derives this from what
/// the owning agent reports about the bytes.
public enum SnapshotStatus: String, Codable, CaseIterable, Sendable {
    case creating = "creating"  // Snapshot is being captured
    case available = "available"  // Snapshot is ready for use
    case deleting = "deleting"  // Snapshot is being deleted
    case error = "error"  // An error occurred
}

/// A point-in-time copy of one volume's data: an external qcow2 overlay whose
/// backing file is the volume, written by the agent's storage backend.
///
/// A durable artifact on a specific agent since STR-150 — desired state the
/// owning agent converges on and confirms, not the result of an RPC.
struct VolumeSnapshot: Content, Sendable {
    static let schema = "volume_snapshots"

    let id: UUID?
    let name: String
    let description: String
    let volumeID: UUID
    let projectID: UUID

    /// The parent volume's environment at capture time, denormalized so quota
    /// resync can measure the snapshot after the volume is gone — the same
    /// reason `VMSnapshot` and `SandboxSnapshot` carry one (STR-181).
    let environment: String

    // Snapshot specifications
    /// The volume's size when the snapshot was taken. Not a footprint: it is
    /// what a restore needs to size its target, and it is also the storage
    /// quota's durable reservation bound — an overlay cannot outgrow the volume
    /// behind it, and it can grow without another admission point.
    let size: Int64

    /// What the overlay actually occupies right now, as the owning agent
    /// re-measures it on every report (STR-181, wire v39).
    ///
    /// This figure is exposed for observability and billing. It does not replace
    /// the quota reservation in `size`: releasing that worst-case bound after a
    /// small first report would let several overlays be admitted before any of
    /// them grew. Nil is "no agent has said" — the bytes are not on a host yet,
    /// or the agent predates v39 — never zero.
    ///
    /// Separate from `size` because the two answer different questions and the
    /// overlay's answer keeps changing: `size` is frozen at capture and a restore
    /// depends on it, while this grows as the volume diverges.
    let observedSizeBytes: Int64?

    // Status tracking
    let status: SnapshotStatus
    let errorMessage: String?

    /// Where the agent put the overlay. The agent owns path layout, so this is
    /// the only direction a snapshot path travels: the control plane stores
    /// what it is told and never derives one.
    let storagePath: String?

    /// The agent holding the overlay (STR-150). A volume snapshot's placement
    /// used to be re-derived from its volume's replica on every request; it is
    /// recorded now, because a desired entry has to appear in exactly one
    /// agent's sync and a volume that moves must not silently orphan its
    /// snapshots into another host's tombstone set.
    let agentId: String?

    // Desired/observed state split (ADR 0001 stage 8, STR-150).
    let desiredStatus: DesiredSnapshotStatus
    let generation: Int64
    let observedGeneration: Int64
    let convergencePhase: String?
    let failedGeneration: Int64?
    let convergenceDeadline: Date?
    let finalizers: [String]

    /// When the retention sweep marks this snapshot `.absent`, or nil to keep
    /// it until someone deletes it (`SnapshotRetention`).
    let expiresAt: Date?

    // Owner tracking
    let createdByID: UUID
    let createdAt: Date?

    init(
        id: UUID? = UUID(),
        name: String,
        description: String,
        volumeID: UUID,
        projectID: UUID,
        environment: String,
        size: Int64,
        observedSizeBytes: Int64? = nil,
        status: SnapshotStatus = .creating,
        errorMessage: String? = nil,
        storagePath: String? = nil,
        agentId: String? = nil,
        desiredStatus: DesiredSnapshotStatus = .present,
        generation: Int64 = 1,
        observedGeneration: Int64 = 0,
        convergencePhase: String? = nil,
        failedGeneration: Int64? = nil,
        convergenceDeadline: Date? = nil,
        finalizers: [String] = [],
        expiresAt: Date? = nil,
        createdByID: UUID,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.volumeID = volumeID
        self.projectID = projectID
        self.environment = environment
        self.size = size
        self.observedSizeBytes = observedSizeBytes
        self.status = status
        self.errorMessage = errorMessage
        self.storagePath = storagePath
        self.agentId = agentId
        self.desiredStatus = desiredStatus
        self.generation = generation
        self.observedGeneration = observedGeneration
        self.convergencePhase = convergencePhase
        self.failedGeneration = failedGeneration
        self.convergenceDeadline = convergenceDeadline
        self.finalizers = finalizers
        self.expiresAt = expiresAt
        self.createdByID = createdByID
        self.createdAt = createdAt
    }

    func requireID() throws -> UUID {
        guard let id else {
            throw Abort(.internalServerError, reason: "Volume snapshot has no identifier")
        }
        return id
    }

    func persisted(on db: PostgresStoreContext) async throws -> Self {
        try await LegacyVolumeSnapshotStore.upsert(self, on: db)
    }

    func persist(on db: PostgresStoreContext) async throws { _ = try await persisted(on: db) }
    func save(on db: PostgresStoreContext) async throws { try await persist(on: db) }

    func remove(on db: PostgresStoreContext) async throws {
        guard let id else { return }
        _ = try await LegacyVolumeSnapshotStore.delete(id: id, on: db)
    }

    func delete(on db: PostgresStoreContext) async throws { try await remove(on: db) }

    static func load(_ id: UUID?, on db: PostgresStoreContext) async throws -> Self? {
        try await LegacyVolumeSnapshotStore.snapshot(id: id, on: db)
    }

    static func find(_ id: UUID?, on db: PostgresStoreContext) async throws -> Self? {
        try await load(id, on: db)
    }

    static func all(on db: PostgresStoreContext) async throws -> [Self] {
        try await LegacyVolumeSnapshotStore.snapshots(on: db)
    }

    func replacing(
        observedSizeBytes: Int64?? = nil,
        status: SnapshotStatus? = nil,
        errorMessage: String?? = nil,
        storagePath: String?? = nil,
        agentId: String?? = nil,
        desiredStatus: DesiredSnapshotStatus? = nil,
        generation: Int64? = nil,
        observedGeneration: Int64? = nil,
        convergencePhase: String?? = nil,
        failedGeneration: Int64?? = nil,
        convergenceDeadline: Date?? = nil,
        finalizers: [String]? = nil,
        expiresAt: Date?? = nil,
        createdAt: Date?? = nil
    ) -> Self {
        Self(
            id: id, name: name, description: description, volumeID: volumeID,
            projectID: projectID, environment: environment, size: size,
            observedSizeBytes: observedSizeBytes ?? self.observedSizeBytes,
            status: status ?? self.status,
            errorMessage: errorMessage ?? self.errorMessage,
            storagePath: storagePath ?? self.storagePath,
            agentId: agentId ?? self.agentId,
            desiredStatus: desiredStatus ?? self.desiredStatus,
            generation: generation ?? self.generation,
            observedGeneration: observedGeneration ?? self.observedGeneration,
            convergencePhase: convergencePhase ?? self.convergencePhase,
            failedGeneration: failedGeneration ?? self.failedGeneration,
            convergenceDeadline: convergenceDeadline ?? self.convergenceDeadline,
            finalizers: finalizers ?? self.finalizers,
            expiresAt: expiresAt ?? self.expiresAt,
            createdByID: createdByID,
            createdAt: createdAt ?? self.createdAt)
    }
}

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
            volumeId: self.volumeID,
            projectId: self.projectID,
            size: self.size,
            sizeGB: Double(size) / 1024.0 / 1024.0 / 1024.0,
            status: self.status,
            errorMessage: self.errorMessage,
            storagePath: self.storagePath,
            agentId: self.agentId,
            expiresAt: self.expiresAt,
            conditions: self.conditions,
            createdById: self.createdByID,
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
    var lastError: String? { errorMessage }

    func replacingConvergence(
        phase: String?, lastError: String?, failedGeneration: Int64?
    ) -> Self {
        replacing(
            errorMessage: .some(lastError), convergencePhase: .some(phase),
            failedGeneration: .some(failedGeneration))
    }
}

extension VolumeSnapshot: SnapshotArtifactResource {
    static var artifactKind: SnapshotArtifactKind { .volumeSnapshot }
    static var iamNodeType: IAMNodeType { .volumeSnapshot }
    static var operationResourceKind: OperationResourceKind { .volumeSnapshot }

    var parentID: UUID { volumeID }
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
    /// start destroying snapshots because their volume diverged.
    ///
    /// Enforcement stays at admission, where the parent volume's *whole* size
    /// is reserved rather than the overlay's: a snapshot cannot be admitted
    /// unless the pool could absorb it fully grown.
    var storageQuotaScope: (projectID: UUID, environment: String)? { nil }

    static func overdueForConvergence(at now: Date, on db: PostgresStoreContext) async throws -> [VolumeSnapshot] {
        try await LegacyVolumeSnapshotStore.snapshots(overdueAt: now, on: db)
    }

    static func placed(onAgent agentId: String, on db: PostgresStoreContext) async throws -> [VolumeSnapshot] {
        try await LegacyVolumeSnapshotStore.snapshots(agentID: agentId, on: db)
    }

    static func matching(ids: [UUID], on db: PostgresStoreContext) async throws -> [VolumeSnapshot] {
        try await LegacyVolumeSnapshotStore.snapshots(ids: ids, on: db)
    }

    static func expired(at now: Date, on db: PostgresStoreContext) async throws -> [VolumeSnapshot] {
        try await LegacyVolumeSnapshotStore.snapshots(expiredAt: now, on: db)
    }

    static func terminating(on db: PostgresStoreContext) async throws -> [VolumeSnapshot] {
        try await LegacyVolumeSnapshotStore.snapshots(terminating: true, on: db)
    }

    func adoptingReconciliationState(from committed: VolumeSnapshot) -> Self {
        committed
    }

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

    /// How much the reported footprint has to move before it is worth a row
    /// write (STR-181).
    ///
    /// A report goes out every 20 seconds, and event-driven ones coalesce at
    /// 500 ms, so an overlay under active write would otherwise cost an `UPDATE`
    /// per snapshot per report for a figure that feeds a byte quota displayed in
    /// GiB. A megabyte of hysteresis buys back all of that and costs nothing any
    /// reader can see.
    static let footprintReportGranularity: Int64 = 1 << 20

    func recordingCapturedFacts(
        _ facts: ObservedSnapshotFacts
    ) -> (resource: Self, changed: Bool) {
        var next = self
        var changed = false
        if let path = facts.storagePath, storagePath != path {
            next = next.replacing(storagePath: .some(path))
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
            next = next.replacing(observedSizeBytes: .some(footprint))
            changed = true
        }
        return (next, changed)
    }

    func recordingExported(_ exported: Bool) -> (resource: Self, changed: Bool) { (self, false) }

    func recordingObservedPresence(
        present: Bool, failed: Bool
    ) -> (resource: Self, changed: Bool) {
        let derived: SnapshotStatus =
            present ? .available : (failed ? .error : (desiredStatus == .absent ? .deleting : .creating))
        guard status != derived else { return (self, false) }
        return (replacing(status: derived), true)
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
    /// (STR-181). Null means no agent has said — the bytes are not on a host yet,
    /// or the agent predates wire v39. The quota keeps `size` reserved either way.
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
        self.volumeId = snapshot.volumeID
        self.projectId = snapshot.projectID
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
        self.createdById = snapshot.createdByID
        self.createdAt = snapshot.createdAt
    }
}
