import Fluent
import Foundation
import Vapor

/// How a pool stores volume data across its member agents.
public enum StoragePoolMode: String, Codable, CaseIterable, Sendable {
    case local = "local"  // single replica on one agent (today's FileSystemStorageBackend)
    case replicated = "replicated"  // N replicas on N distinct member agents
    case ceph = "ceph"  // shared RBD images in an external site cluster
}

/// The on-disk backend the pool's agents use for volume data.
public enum StoragePoolBacking: String, Codable, CaseIterable, Sendable {
    case filesystem = "filesystem"  // plain files + qemu-img
    case zfs = "zfs"  // ZFS datasets (replicated pools)
}

/// A storage pool selects the storage ownership model for a volume. Local
/// volumes have host-owned `VolumeReplica` rows; Ceph volumes have one shared
/// RBD image and only a control-plane execution owner.
/// Safety: this mutable Fluent model stays inside one logical operation; child tasks
/// receive IDs or immutable snapshots and reload their own instance.
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

    /// Ceph pools are project-scoped through their access row. These fields are
    /// all set for `.ceph` and all nil for host-local/reserved replicated pools.
    @OptionalParent(key: "site_id")
    var site: Site?

    @OptionalParent(key: "ceph_cluster_id")
    var cephCluster: CephCluster?

    @OptionalParent(key: "ceph_project_access_id")
    var cephProjectAccess: CephProjectAccess?

    @OptionalField(key: "ceph_pool_name")
    var cephPoolName: String?

    @OptionalField(key: "ceph_namespace")
    var cephNamespace: String?

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
        backing: StoragePoolBacking,
        siteID: UUID? = nil,
        cephClusterID: UUID? = nil,
        cephProjectAccessID: UUID? = nil,
        cephPoolName: String? = nil,
        cephNamespace: String? = nil
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.replicationFactor = replicationFactor
        self.memberAgentIds = memberAgentIds
        self.backing = backing
        self.$site.id = siteID
        self.$cephCluster.id = cephClusterID
        self.$cephProjectAccess.id = cephProjectAccessID
        self.cephPoolName = cephPoolName
        self.cephNamespace = cephNamespace
    }
}

extension StoragePool: Content {}

extension StoragePool {
    /// The pool new volumes are placed in when no pool is specified. The
    /// current-schema baseline creates it for every fresh database.
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

    /// Resolve an API-selected pool without treating its UUID as authority.
    /// Omission is the historical default-local path; Ceph selection is valid
    /// only through this project's scoped access row. Shared by standalone and
    /// managed boot-volume creation so the two paths cannot drift.
    static func resolveForCreate(
        requestedPoolID: UUID?, projectID: UUID, on db: any Database
    ) async throws -> StoragePool {
        let pool: StoragePool
        if let requestedPoolID {
            guard let selected = try await StoragePool.find(requestedPoolID, on: db) else {
                throw Abort(.notFound, reason: "Storage pool not found")
            }
            pool = selected
        } else {
            pool = try await defaultPool(on: db)
        }
        switch pool.mode {
        case .replicated:
            throw Abort(
                .conflict,
                reason:
                    "Storage pool '\(pool.name)' uses replicated mode, which is not supported by the host-local storage backend"
            )
        case .ceph:
            guard let accessID = pool.$cephProjectAccess.id,
                let access = try await CephProjectAccess.find(accessID, on: db),
                access.$project.id == projectID
            else {
                throw Abort(.forbidden, reason: "Storage pool is not configured for this project")
            }
        case .local:
            break
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
    /// - `replicated`: fail closed. The schema value was reserved for a DRBD
    ///   design that was never implemented; independent filesystem copies are
    ///   not a coherent shared volume.
    /// - `ceph`: the agent must be online in the same site and carry a fresh,
    ///   healthy Ceph-client dependency observation.
    ///
    /// `pool` is optional so callers can pass an unloaded/legacy state; no pool
    /// behaves like `local`.
    static func agentCanReach(
        agent: Agent,
        pool: StoragePool?,
        replicaAgentIds: [String],
        at instant: ClusterInstant
    ) -> Bool {
        switch pool?.mode {
        case .replicated:
            return false
        case .ceph:
            guard let pool,
                pool.$site.id != nil,
                pool.$cephCluster.id != nil,
                pool.$cephProjectAccess.id != nil
            else { return false }
            return agent.status == .online
                && agent.$site.id == pool.$site.id
                && agent.dependencyAllows(.cephVolumes, at: instant)
        case .local, nil:
            guard let agentID = agent.id?.uuidString else { return false }
            return replicaAgentIds.isEmpty || replicaAgentIds.contains(agentID)
        }
    }
}

/// Public pool metadata. Agent membership/backing are legacy local-backend
/// implementation details; Ceph credentials are reached only through the
/// write-only project access API and never appear here.
struct StoragePoolResponse: Content {
    let id: UUID?
    let name: String
    let mode: StoragePoolMode
    let siteId: UUID?
    let cephClusterId: UUID?
    let cephProjectAccessId: UUID?
    let cephPoolName: String?
    let cephNamespace: String?
    let createdAt: Date?
    let updatedAt: Date?

    init(from pool: StoragePool) {
        id = pool.id
        name = pool.name
        mode = pool.mode
        siteId = pool.$site.id
        cephClusterId = pool.$cephCluster.id
        cephProjectAccessId = pool.$cephProjectAccess.id
        cephPoolName = pool.cephPoolName
        cephNamespace = pool.cephNamespace
        createdAt = pool.createdAt
        updatedAt = pool.updatedAt
    }
}
