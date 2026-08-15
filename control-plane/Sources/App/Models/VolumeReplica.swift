import Fluent
import Foundation
import StratoShared
import Vapor

/// Lifecycle of one physical copy of a volume.
public enum VolumeReplicaState: String, Codable, CaseIterable, Sendable {
    case provisioning = "provisioning"  // dataset being created on the agent
    case healthy = "healthy"  // in sync and serving
    case degraded = "degraded"  // serving but missing peers (replicated pools)
    case resyncing = "resyncing"  // catching up from healthy peers
    case faulted = "faulted"  // unusable; a replacement should be placed
}

/// One physical copy ("region") of a volume on one agent. A `local`-pool
/// volume has exactly one replica. The reserved `replicated` pool mode is not
/// executable until a storage backend can keep copies coherent. The logical
/// volume (size, format, desired VM attachment) stays on `Volume`; each replica
/// records where its bytes live and the health of that copy.
/// Safety: this mutable Fluent model stays inside one logical operation; child tasks
/// receive IDs or immutable snapshots and reload their own instance.
final class VolumeReplica: Model, @unchecked Sendable {
    static let schema = "volume_replicas"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "volume_id")
    var volume: Volume

    /// The agent holding this copy.
    @Field(key: "agent_id")
    var agentId: String

    /// Agent-owned storage reference. Nil until the agent reports it; the
    /// control plane persists and echoes the value without deriving layout.
    @OptionalField(key: "disk_attachment")
    var diskAttachment: DiskAttachment?

    @Enum(key: "state")
    var state: VolumeReplicaState

    /// Monotonic counter for reconciliation ordering, mirroring
    /// `DesiredVMState.generation` (see ReconciliationProtocol.swift).
    @Field(key: "generation")
    var generation: Int64

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        volumeID: UUID,
        agentId: String,
        diskAttachment: DiskAttachment? = nil,
        state: VolumeReplicaState = .provisioning,
        generation: Int64 = 0
    ) {
        self.id = id
        self.$volume.id = volumeID
        self.agentId = agentId
        self.diskAttachment = diskAttachment
        self.state = state
        self.generation = generation
    }
}

extension VolumeReplica: Content {}
