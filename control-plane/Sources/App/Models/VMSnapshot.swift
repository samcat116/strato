import Fluent
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
/// Safety: this mutable Fluent model stays inside one logical operation; child tasks
/// receive IDs or immutable snapshots and reload their own instance.
final class VMSnapshot: Model, @unchecked Sendable {
    static let schema = "vm_snapshots"

    @ID(key: .id)
    var id: UUID?

    /// Optional operator label; defaults to a timestamp-derived name.
    @Field(key: "name")
    var name: String

    @Field(key: "description")
    var description: String

    @Parent(key: "vm_id")
    var vm: VM

    /// Project ownership, denormalized from the VM for querying and quota
    /// scoping (the volume/sandbox-snapshot pattern).
    @Parent(key: "project_id")
    var project: Project

    /// The VM's environment at checkpoint time, denormalized so quota resync
    /// can scope snapshot storage without joining vms.
    @Field(key: "environment")
    var environment: String

    @Enum(key: "status")
    var status: VMSnapshotStatus

    /// Bytes of guest RAM + device state the checkpoint added. Written at
    /// admission with the quota estimate (the VM's memory grant bounds it),
    /// then overwritten with what the agent actually reports. Deliberately
    /// *not* the disks' size: those are already charged as volume storage, and
    /// an internal snapshot does not copy them.
    @OptionalField(key: "size")
    var size: Int64?

    /// The agent holding the checkpoint. Restore placement is pinned here in
    /// v1. Recorded at creation from the VM's placement.
    @OptionalField(key: "agent_id")
    var agentId: String?

    /// The QEMU build that captured the checkpoint; a restore needs a
    /// compatible one.
    @OptionalField(key: "qemu_version")
    var qemuVersion: String?

    @OptionalField(key: "architecture")
    var architecture: String?

    @OptionalField(key: "error_message")
    var errorMessage: String?

    // Desired/observed state split (ADR 0001 stage 8, STR-150), mirroring the
    // volume columns exactly.
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

    /// When the retention sweep marks this checkpoint `.absent`, or nil to keep
    /// it until someone deletes it (`SnapshotRetention`).
    @OptionalField(key: "expires_at")
    var expiresAt: Date?

    // Attribution, not ownership (STR-297): nulled when the creator is deleted.
    @OptionalParent(key: "created_by_id")
    var createdBy: User?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        name: String,
        description: String = "",
        vmID: UUID,
        projectID: UUID,
        environment: String,
        agentId: String?,
        expiresAt: Date? = nil,
        createdByID: UUID
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.$vm.id = vmID
        self.$project.id = projectID
        self.environment = environment
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

extension VMSnapshot: Content {}

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
    var lastError: String? {
        get { errorMessage }
        set { errorMessage = newValue }
    }
}

extension VMSnapshot: SnapshotArtifactResource {
    static var artifactKind: SnapshotArtifactKind { .vmCheckpoint }
    static var iamNodeType: IAMNodeType { .vmSnapshot }
    static var operationResourceKind: OperationResourceKind { .vmCheckpoint }

    var projectID: UUID { $project.id }
    var parentID: UUID { $vm.id }
    var isPresentOnAgent: Bool { status == .ready }

    /// A checkpoint lives inside the VM's own disks: there is nowhere to export
    /// it to short of shared storage or an object-store archive, neither of
    /// which exists for this family (issue #564 scope, STR-161).
    var wantsExport: Bool { false }

    /// The machine state is charged to the project's storage pool; the disks it
    /// lives inside are already charged under the VM.
    var storageQuotaScope: (projectID: UUID, environment: String)? {
        ($project.id, environment)
    }

    static func overdueForConvergence(at now: Date, on db: any Database) async throws -> [VMSnapshot] {
        try await VMSnapshot.query(on: db).filter(\.$convergenceDeadline <= now).all()
    }

    static func placed(onAgent agentId: String, on db: any Database) async throws -> [VMSnapshot] {
        try await VMSnapshot.query(on: db).filter(\.$agentId == agentId).all()
    }

    static func expired(at now: Date, on db: any Database) async throws -> [VMSnapshot] {
        try await VMSnapshot.query(on: db)
            .filter(\.$expiresAt <= now)
            .filter(\.$desiredStatus != DesiredSnapshotStatus.absent)
            .all()
    }

    static func terminating(on db: any Database) async throws -> [VMSnapshot] {
        try await VMSnapshot.query(on: db)
            .filter(\.$desiredStatus == DesiredSnapshotStatus.absent)
            .all()
    }

    func adoptReconciliationState(from committed: VMSnapshot) {
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
        qemuVersion = committed.qemuVersion
        architecture = committed.architecture
        finalizers = committed.finalizers
        expiresAt = committed.expiresAt
    }

    @discardableResult
    func applyCapturedFacts(_ facts: ObservedSnapshotFacts) -> Bool {
        var changed = false
        // A QEMU build that reported no size for the tag it just wrote leaves
        // the admission estimate standing: an unknown footprint must not
        // silently become a free one in quota accounting.
        if let sizeBytes = facts.sizeBytes, size != sizeBytes {
            size = sizeBytes
            changed = true
        }
        if let version = facts.qemuVersion, qemuVersion != version {
            qemuVersion = version
            changed = true
        }
        if let architecture = facts.architecture?.rawValue, self.architecture != architecture {
            self.architecture = architecture
            changed = true
        }
        return changed
    }

    @discardableResult
    func applyExported(_ exported: Bool) -> Bool { false }

    @discardableResult
    func applyObservedPresence(present: Bool, failed: Bool) -> Bool {
        let derived: VMSnapshotStatus =
            present ? .ready : (failed ? .error : (desiredStatus == .absent ? .deleting : .creating))
        guard status != derived else { return false }
        status = derived
        return true
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
        self.vmId = snapshot.$vm.id
        self.projectId = snapshot.$project.id
        self.status = snapshot.status
        self.size = snapshot.size
        self.agentId = snapshot.agentId
        self.qemuVersion = snapshot.qemuVersion
        self.architecture = snapshot.architecture
        self.errorMessage = snapshot.errorMessage
        self.expiresAt = snapshot.expiresAt
        self.conditions = snapshot.conditions
        self.createdById = snapshot.$createdBy.id
        self.createdAt = snapshot.createdAt
    }
}
