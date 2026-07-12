import Fluent
import Foundation
import Vapor

/// How a pool stores volume data across its member agents.
public enum StoragePoolMode: String, Codable, CaseIterable, Sendable {
    case local = "local"  // single replica on one agent (today's FileSystemStorageBackend)
    case replicated = "replicated"  // N replicas on N distinct member agents
}

/// The on-disk backend the pool's agents use for volume data.
public enum StoragePoolBacking: String, Codable, CaseIterable, Sendable {
    case filesystem = "filesystem"  // plain files + qemu-img
    case zfs = "zfs"  // ZFS datasets (replicated pools)
}

/// A storage pool groups the agents a volume's data may live on and how it is
/// replicated among them. Every volume belongs to exactly one pool; a volume's
/// physical copies are its `VolumeReplica` rows, each on one of the pool's
/// member agents. See `docs/architecture/distributed-storage.md`.
final class StoragePool: Model, @unchecked Sendable {
    static let schema = "storage_pools"

    /// Name of the pool created by migration that adopts all pre-pool volumes.
    /// It represents today's behavior: `local` mode, `filesystem` backing, and
    /// no member restriction (any QEMU-capable agent may hold a replica).
    static let defaultPoolName = "default"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "name")
    var name: String

    @Enum(key: "mode")
    var mode: StoragePoolMode

    @Field(key: "replication_factor")
    var replicationFactor: Int

    /// Agent IDs eligible to hold this pool's replicas. Empty means
    /// unrestricted — any agent that can serve the pool's backing qualifies.
    @Field(key: "member_agent_ids")
    var memberAgentIds: [String]

    @Enum(key: "backing")
    var backing: StoragePoolBacking

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        name: String,
        mode: StoragePoolMode,
        replicationFactor: Int = 1,
        memberAgentIds: [String] = [],
        backing: StoragePoolBacking
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.replicationFactor = replicationFactor
        self.memberAgentIds = memberAgentIds
        self.backing = backing
    }
}

extension StoragePool: Content {}

extension StoragePool {
    /// The pool new volumes are placed in when no pool is specified. Created
    /// by `CreateStoragePool`, so it exists on every migrated database.
    static func defaultPool(on db: Database) async throws -> StoragePool {
        guard
            let pool = try await StoragePool.query(on: db)
                .filter(\.$name == defaultPoolName)
                .first()
        else {
            throw Abort(.internalServerError, reason: "Default storage pool is missing; run migrations")
        }
        return pool
    }

    /// Whether an agent can reach the data of a volume placed in this pool —
    /// the pool-aware generalization of the old same-hypervisor attach guard.
    ///
    /// - `local`: the volume's data exists on exactly the agents holding its
    ///   replicas, so the agent must be one of them. A volume with no replicas
    ///   yet (never provisioned) is reachable from anywhere, matching the old
    ///   guard's "no hypervisor recorded" case.
    /// - `replicated`: any member agent reaches the replica set over the
    ///   network, so membership decides.
    ///
    /// `pool` is optional so callers can pass an unloaded/legacy state; no pool
    /// behaves like `local`.
    static func agentCanReach(agentId: String, pool: StoragePool?, replicaAgentIds: [String]) -> Bool {
        switch pool?.mode {
        case .replicated:
            return pool!.memberAgentIds.isEmpty || pool!.memberAgentIds.contains(agentId)
        case .local, nil:
            return replicaAgentIds.isEmpty || replicaAgentIds.contains(agentId)
        }
    }
}
