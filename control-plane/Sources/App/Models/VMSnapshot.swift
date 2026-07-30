import Fluent
import Foundation
import StratoShared
import Vapor

/// Lifecycle of a full-VM checkpoint (issue #564). `creating` is the only
/// non-terminal state a client polls through (the create operation record
/// carries the verdict); `deleting` is retryable, like volume and sandbox
/// snapshots — a control-plane restart mid-delete leaves the record
/// recoverable, and agent-side deletion is idempotent.
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
/// with alongside placement.
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
        description: String = "",
        vmID: UUID,
        projectID: UUID,
        environment: String,
        agentId: String?,
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
        self.$createdBy.id = createdByID
    }
}

extension VMSnapshot: Content {}

extension VMSnapshot {
    var canRestore: Bool { status == .ready }

    /// `.creating` is deliberately not deletable — its create operation is
    /// still pending and owns the row's resolution.
    var canDelete: Bool { status == .ready || status == .error || status == .deleting }
}

// MARK: - Request/Response DTOs

struct CreateVMSnapshotRequest: Content {
    let name: String?
    let description: String?
}

struct VMSnapshotResponse: Content {
    let id: UUID?
    let name: String
    let description: String
    let vmId: UUID?
    let projectId: UUID?
    let status: VMSnapshotStatus
    /// Bytes of machine state; nil while creating, or when the agent's QEMU
    /// reported no size for the checkpoint it took.
    let size: Int64?
    let agentId: String?
    let qemuVersion: String?
    let architecture: String?
    let errorMessage: String?
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
        self.createdById = snapshot.$createdBy.id
        self.createdAt = snapshot.createdAt
    }
}
