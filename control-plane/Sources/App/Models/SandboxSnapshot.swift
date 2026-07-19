import Fluent
import Foundation
import Vapor

/// Lifecycle of a sandbox snapshot (issue #426). `creating` is the only
/// non-terminal state a client polls through (the create operation record
/// carries the verdict); `deleting` is retryable, like volume snapshots — a
/// control-plane restart mid-delete leaves the record recoverable, and
/// agent-side artifact deletion is idempotent.
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
        sandboxID: UUID,
        projectID: UUID,
        environment: String,
        agentId: String?,
        createdByID: UUID
    ) {
        self.id = id
        self.name = name
        self.$sandbox.id = sandboxID
        self.$project.id = projectID
        self.environment = environment
        self.status = .creating
        self.agentId = agentId
        self.$createdBy.id = createdByID
    }
}

extension SandboxSnapshot: Content {}

extension SandboxSnapshot {
    var isReady: Bool { status == .ready }

    var canRestore: Bool { status == .ready }

    /// `.creating` is deliberately not deletable — its create operation is
    /// still pending and owns the row's resolution.
    var canDelete: Bool { status == .ready || status == .error || status == .deleting }
}

// MARK: - Request/Response DTOs

struct CreateSandboxSnapshotRequest: Content {
    let name: String?
    /// `true` checkpoints-and-stops: the sandbox converges to `stopped` after
    /// the snapshot instead of resuming. Defaults to `false` (resume).
    let stop: Bool?
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
    let errorMessage: String?
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
        self.errorMessage = snapshot.errorMessage
        self.createdById = snapshot.$createdBy.id
        self.createdAt = snapshot.createdAt
    }
}
