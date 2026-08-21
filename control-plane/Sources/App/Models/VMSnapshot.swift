import ControlPlanePostgres
import Foundation
import StratoShared
import Vapor

/// Lifecycle of a full-VM checkpoint (issue #564).
///
/// Purely *observed* since STR-150, like `VolumeStatus` after STR-148: the
/// control plane no longer writes a transitional status before dispatching an
/// RPC, because there is no RPC. `ObservedStateApplier` derives this from what
/// the owning agent reports about the bytes.
enum VMSnapshotStatus: String, Codable, CaseIterable, Sendable {
    case creating
    case ready
    case deleting
    case error
}

/// A checkpoint of a running VM (issue #564): guest RAM, device state, and the
/// disks captured at one consistent point, written as an internal snapshot of
/// the VM's qcow2 disks by QEMU's `snapshot-save` job.
///
/// This is the memory-and-devices primitive, distinct from the disk-only
/// `VolumeSnapshot` (an external qcow2 overlay). The state lives *inside* the
/// VM's own disks on the agent that took it, so there is no artifact path to
/// record and restore placement is pinned to `agentId`; moving a checkpoint
/// off-node is deliberately out of scope for v1 (it needs either shared
/// storage or an object-storage export, like sandboxes got in #428).
///
/// A QEMU internal snapshot only restores on a compatible QEMU build and
/// machine shape, so the row records the version and architecture it was taken
/// with alongside placement — all of it reported by the agent on the observed
/// state report rather than in a one-shot RPC reply (STR-150).
struct VMSnapshot: Content, Sendable {
    static let schema = "vm_snapshots"

    let id: UUID?
    let name: String
    let description: String
    let vmID: UUID

    /// Project ownership, denormalized from the VM for querying and quota
    /// scoping (the volume/sandbox-snapshot pattern).
    let projectID: UUID

    /// The VM's environment at checkpoint time, denormalized so quota resync
    /// can scope snapshot storage without joining vms.
    let environment: String
    let status: VMSnapshotStatus

    /// Bytes of guest RAM + device state the checkpoint added. Written at
    /// admission with the quota estimate (the VM's memory grant bounds it),
    /// then overwritten with what the agent actually reports. Deliberately
    /// *not* the disks' size: those are already charged as volume storage, and
    /// an internal snapshot does not copy them.
    let size: Int64?

    /// The agent holding the checkpoint. Restore placement is pinned here in
    /// v1. Recorded at creation from the VM's placement.
    let agentId: String?

    /// The QEMU build that captured the checkpoint; a restore needs a
    /// compatible one.
    let qemuVersion: String?
    let architecture: String?
    let errorMessage: String?

    // Desired/observed state split (ADR 0001 stage 8, STR-150), mirroring the
    // volume columns exactly.
    let desiredStatus: DesiredSnapshotStatus
    let generation: Int64
    let observedGeneration: Int64
    let convergencePhase: String?
    let failedGeneration: Int64?
    let convergenceDeadline: Date?
    let finalizers: [String]

    /// When the retention sweep marks this checkpoint `.absent`, or nil to keep
    /// it until someone deletes it (`SnapshotRetention`).
    let expiresAt: Date?
    let createdByID: UUID
    let createdAt: Date?
    let updatedAt: Date?

    init(
        id: UUID? = UUID(),
        name: String,
        description: String = "",
        vmID: UUID,
        projectID: UUID,
        environment: String,
        status: VMSnapshotStatus = .creating,
        size: Int64? = nil,
        agentId: String?,
        qemuVersion: String? = nil,
        architecture: String? = nil,
        errorMessage: String? = nil,
        desiredStatus: DesiredSnapshotStatus = .present,
        generation: Int64 = 1,
        observedGeneration: Int64 = 0,
        convergencePhase: String? = nil,
        failedGeneration: Int64? = nil,
        convergenceDeadline: Date? = nil,
        finalizers: [String] = [],
        expiresAt: Date? = nil,
        createdByID: UUID,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.vmID = vmID
        self.projectID = projectID
        self.environment = environment
        self.status = status
        self.size = size
        self.agentId = agentId
        self.qemuVersion = qemuVersion
        self.architecture = architecture
        self.errorMessage = errorMessage
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
        self.updatedAt = updatedAt
    }

    func requireID() throws -> UUID {
        guard let id else { throw Abort(.internalServerError, reason: "VM snapshot has no identifier") }
        return id
    }

    func persisted(on db: PostgresStoreContext) async throws -> Self {
        try await LegacyVMSnapshotStore.upsert(self, on: db)
    }
    func persist(on db: PostgresStoreContext) async throws { _ = try await persisted(on: db) }
    func save(on db: PostgresStoreContext) async throws { try await persist(on: db) }
    func remove(on db: PostgresStoreContext) async throws {
        guard let id else { return }
        _ = try await LegacyVMSnapshotStore.delete(id: id, on: db)
    }
    func delete(on db: PostgresStoreContext) async throws { try await remove(on: db) }
    static func load(_ id: UUID?, on db: PostgresStoreContext) async throws -> Self? {
        try await LegacyVMSnapshotStore.snapshot(id: id, on: db)
    }
    static func find(_ id: UUID?, on db: PostgresStoreContext) async throws -> Self? {
        try await load(id, on: db)
    }

    static func all(on db: PostgresStoreContext) async throws -> [Self] {
        try await LegacyVMSnapshotStore.snapshots(on: db)
    }

    func replacing(
        status: VMSnapshotStatus? = nil,
        size: Int64?? = nil,
        agentId: String?? = nil,
        qemuVersion: String?? = nil,
        architecture: String?? = nil,
        errorMessage: String?? = nil,
        desiredStatus: DesiredSnapshotStatus? = nil,
        generation: Int64? = nil,
        observedGeneration: Int64? = nil,
        convergencePhase: String?? = nil,
        failedGeneration: Int64?? = nil,
        convergenceDeadline: Date?? = nil,
        finalizers: [String]? = nil,
        expiresAt: Date?? = nil
    ) -> Self {
        Self(
            id: id, name: name, description: description, vmID: vmID,
            projectID: projectID, environment: environment, status: status ?? self.status,
            size: size ?? self.size, agentId: agentId ?? self.agentId,
            qemuVersion: qemuVersion ?? self.qemuVersion,
            architecture: architecture ?? self.architecture,
            errorMessage: errorMessage ?? self.errorMessage,
            desiredStatus: desiredStatus ?? self.desiredStatus,
            generation: generation ?? self.generation,
            observedGeneration: observedGeneration ?? self.observedGeneration,
            convergencePhase: convergencePhase ?? self.convergencePhase,
            failedGeneration: failedGeneration ?? self.failedGeneration,
            convergenceDeadline: convergenceDeadline ?? self.convergenceDeadline,
            finalizers: finalizers ?? self.finalizers, expiresAt: expiresAt ?? self.expiresAt,
            createdByID: createdByID, createdAt: createdAt, updatedAt: updatedAt)
    }
}

extension VMSnapshot {
    var canRestore: Bool { status == .ready && desiredStatus == .present }

    /// A checkpoint is deletable in any state, including a capture that never
    /// finished: deletion is level-triggered and the agent's teardown is
    /// idempotent, so re-issuing it is always safe. The `.creating` exclusion
    /// this replaces existed because a pending operation owned the row's
    /// resolution; nothing owns it now but the reconciliation loop.
    var canDelete: Bool { true }
}

// MARK: - Conditions and convergence (STR-150)

extension VMSnapshot: ConvergenceObservable {
    /// A checkpoint's convergence failure and its user-facing error share one
    /// column, `Volume`'s arrangement and for its reason: there has never been
    /// a second error to report, and two columns would only invite them to
    /// disagree in the API response.
    var lastError: String? { errorMessage }

    func replacingConvergence(
        phase: String?, lastError: String?, failedGeneration: Int64?
    ) -> Self {
        replacing(
            errorMessage: .some(lastError), convergencePhase: .some(phase),
            failedGeneration: .some(failedGeneration))
    }
}

extension VMSnapshot: SnapshotArtifactResource {
    static var artifactKind: SnapshotArtifactKind { .vmCheckpoint }
    static var iamNodeType: IAMNodeType { .vmSnapshot }
    static var operationResourceKind: OperationResourceKind { .vmCheckpoint }

    var parentID: UUID { vmID }
    var isPresentOnAgent: Bool { status == .ready }

    /// A checkpoint lives inside the VM's own disks: there is nowhere to export
    /// it to short of shared storage or an object-store archive, neither of
    /// which exists for this family (issue #564 scope, STR-161).
    var wantsExport: Bool { false }

    /// The machine state is charged to the project's storage pool; the disks it
    /// lives inside are already charged under the VM.
    var storageQuotaScope: (projectID: UUID, environment: String)? {
        (projectID, environment)
    }

    static func overdueForConvergence(at now: Date, on db: PostgresStoreContext) async throws -> [VMSnapshot] {
        try await LegacyVMSnapshotStore.snapshots(overdueAt: now, on: db)
    }

    static func placed(onAgent agentId: String, on db: PostgresStoreContext) async throws -> [VMSnapshot] {
        try await LegacyVMSnapshotStore.snapshots(agentID: agentId, on: db)
    }

    static func matching(ids: [UUID], on db: PostgresStoreContext) async throws -> [VMSnapshot] {
        try await LegacyVMSnapshotStore.snapshots(ids: ids, on: db)
    }

    static func expired(at now: Date, on db: PostgresStoreContext) async throws -> [VMSnapshot] {
        try await LegacyVMSnapshotStore.snapshots(expiredAt: now, on: db)
    }

    static func terminating(on db: PostgresStoreContext) async throws -> [VMSnapshot] {
        try await LegacyVMSnapshotStore.snapshots(terminating: true, on: db)
    }

    func adoptingReconciliationState(from committed: VMSnapshot) -> Self { committed }
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
        // A QEMU build that reported no size for the tag it just wrote leaves
        // the admission estimate standing: an unknown footprint must not
        // silently become a free one in quota accounting.
        if let sizeBytes = facts.sizeBytes, size != sizeBytes {
            next = next.replacing(size: .some(sizeBytes))
            changed = true
        }
        if let version = facts.qemuVersion, qemuVersion != version {
            next = next.replacing(qemuVersion: .some(version))
            changed = true
        }
        if let architecture = facts.architecture?.rawValue, self.architecture != architecture {
            next = next.replacing(architecture: .some(architecture))
            changed = true
        }
        return (next, changed)
    }

    func recordingExported(_ exported: Bool) -> (resource: Self, changed: Bool) { (self, false) }

    func recordingObservedPresence(
        present: Bool, failed: Bool
    ) -> (resource: Self, changed: Bool) {
        let derived: VMSnapshotStatus =
            present ? .ready : (failed ? .error : (desiredStatus == .absent ? .deleting : .creating))
        guard status != derived else { return (self, false) }
        return (replacing(status: derived), true)
    }
}

// MARK: - Request/Response DTOs

struct CreateVMSnapshotRequest: Content, ValidatedRequestBody {
    var name: String?
    let description: String?
    /// How long to keep the checkpoint, in seconds. Omitted uses the fleet
    /// default (`SNAPSHOT_DEFAULT_TTL_SECONDS`, unset by default); `0` keeps it
    /// until someone deletes it, overriding that default.
    let ttlSeconds: Int?

    mutating func validate() throws {
        name = try Validate.name(name)
        try Validate.text(description)
    }
}

struct VMSnapshotResponse: Content {
    let id: UUID?
    let name: String
    let description: String
    let vmId: UUID?
    let projectId: UUID?
    let status: VMSnapshotStatus
    /// Bytes of machine state; nil while capturing, or when the agent's QEMU
    /// reported no size for the checkpoint it took.
    let size: Int64?
    let agentId: String?
    let qemuVersion: String?
    let architecture: String?
    let errorMessage: String?
    /// When retention will delete this checkpoint; nil means it is kept until
    /// someone deletes it.
    let expiresAt: Date?
    /// The client-facing answer to "is my mutation done?" (ADR 0001 stage 1),
    /// derived on read. Checkpoints join the 202-and-converge flow in STR-150,
    /// so this is what clients poll rather than the status string.
    let conditions: ResourceConditions
    let createdById: UUID?
    let createdAt: Date?

    init(from snapshot: VMSnapshot) {
        self.id = snapshot.id
        self.name = snapshot.name
        self.description = snapshot.description
        self.vmId = snapshot.vmID
        self.projectId = snapshot.projectID
        self.status = snapshot.status
        self.size = snapshot.size
        self.agentId = snapshot.agentId
        self.qemuVersion = snapshot.qemuVersion
        self.architecture = snapshot.architecture
        self.errorMessage = snapshot.errorMessage
        self.expiresAt = snapshot.expiresAt
        self.conditions = snapshot.conditions
        self.createdById = snapshot.createdByID
        self.createdAt = snapshot.createdAt
    }
}
