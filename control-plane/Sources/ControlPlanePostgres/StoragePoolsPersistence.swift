import Foundation
import PostgresNIO

public enum StoragePoolMode: String, Codable, CaseIterable, Sendable {
    case local
    case replicated
}

public enum StoragePoolBacking: String, Codable, CaseIterable, Sendable {
    case filesystem
    case zfs
}

public struct StoragePoolSnapshot: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let mode: StoragePoolMode
    public let replicationFactor: Int
    public let memberAgentIDs: [String]
    public let backing: StoragePoolBacking
    public let createdAt: Date?
    public let updatedAt: Date?

    public init(
        id: UUID,
        name: String,
        mode: StoragePoolMode,
        replicationFactor: Int = 1,
        memberAgentIDs: [String] = [],
        backing: StoragePoolBacking,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.replicationFactor = replicationFactor
        self.memberAgentIDs = memberAgentIDs
        self.backing = backing
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum StoragePoolPersistenceError: Error, Equatable, Sendable {
    case missingDefaultPool
    case unknownMode(String)
    case unknownBacking(String)
    case unexpectedRowCount(expected: Int, actual: Int)
}

/// Storage-pool lookup and placement policy. Pools have no public mutation API
/// today; their seeded/default state is still read through this domain seam.
public struct StoragePoolsPersistence: Sendable {
    public static let defaultPoolName = "default"

    private let database: PostgresDatabase

    init(database: PostgresDatabase) {
        self.database = database
    }

    public func all() async throws -> [StoragePoolSnapshot] {
        try await database.withSession(operation: "storage_pools.list") { session in
            try await session.execute(
                ListStoragePools(),
                operation: "storage_pools.list.query"
            ).map { try $0.snapshot() }
        }
    }

    public func pool(id: UUID) async throws -> StoragePoolSnapshot? {
        try await database.withSession(operation: "storage_pools.lookup") { session in
            let rows = try await session.execute(
                FindStoragePool(id: id),
                operation: "storage_pools.lookup.query"
            )
            guard rows.count <= 1 else {
                throw StoragePoolPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
            }
            return try rows.first?.snapshot()
        }
    }

    public func defaultPool() async throws -> StoragePoolSnapshot {
        try await database.withSession(operation: "storage_pools.default") { session in
            let rows = try await session.execute(
                FindDefaultStoragePool(),
                operation: "storage_pools.default.query"
            )
            guard rows.count <= 1 else {
                throw StoragePoolPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
            }
            guard let row = rows.first else {
                throw StoragePoolPersistenceError.missingDefaultPool
            }
            return try row.snapshot()
        }
    }

    /// Replace the placement policy for an existing pool. This is intentionally
    /// explicit rather than exposing a mutable row object.
    public func update(
        id: UUID,
        mode: StoragePoolMode,
        replicationFactor: Int,
        memberAgentIDs: [String],
        backing: StoragePoolBacking
    ) async throws -> StoragePoolSnapshot? {
        precondition(replicationFactor > 0)
        return try await database.withSession(operation: "storage_pools.update") { session in
            let rows = try await session.execute(
                UpdateStoragePool(
                    id: id,
                    mode: mode,
                    replicationFactor: replicationFactor,
                    memberAgentIDs: memberAgentIDs,
                    backing: backing
                ),
                operation: "storage_pools.update.query"
            )
            guard rows.count <= 1 else {
                throw StoragePoolPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
            }
            return try rows.first?.snapshot()
        }
    }

    /// Whether an agent can reach a volume's data. Replicated filesystem/ZFS
    /// pools remain fail-closed until a coherent shared backend is shipped.
    public static func agentCanReach(
        agentID: String,
        pool: StoragePoolSnapshot?,
        replicaAgentIDs: [String]
    ) -> Bool {
        switch pool?.mode {
        case .replicated:
            return false
        case .local, nil:
            return replicaAgentIDs.isEmpty || replicaAgentIDs.contains(agentID)
        }
    }
}

private struct StoragePoolRecord: Sendable {
    let id: UUID
    let name: String
    let mode: String
    let replicationFactor: Int
    let memberAgentIDs: [String]
    let backing: String
    let createdAt: Date?
    let updatedAt: Date?

    init(row: PostgresRow) throws {
        (
            id, name, mode, replicationFactor, memberAgentIDs, backing,
            createdAt, updatedAt
        ) = try row.decode((
            UUID, String, String, Int, [String], String, Date?, Date?
        ).self)
    }

    func snapshot() throws -> StoragePoolSnapshot {
        guard let mode = StoragePoolMode(rawValue: mode) else {
            throw StoragePoolPersistenceError.unknownMode(mode)
        }
        guard let backing = StoragePoolBacking(rawValue: backing) else {
            throw StoragePoolPersistenceError.unknownBacking(backing)
        }
        return StoragePoolSnapshot(
            id: id,
            name: name,
            mode: mode,
            replicationFactor: replicationFactor,
            memberAgentIDs: memberAgentIDs,
            backing: backing,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private let storagePoolColumns = """
    id, name, mode, replication_factor, member_agent_ids, backing,
    created_at, updated_at
    """

private struct ListStoragePools: PostgresPreparedStatement {
    static let sql = "SELECT \(storagePoolColumns) FROM storage_pools ORDER BY name, id"
    typealias Row = StoragePoolRecord

    func makeBindings() -> PostgresBindings { PostgresBindings() }
    func decodeRow(_ row: PostgresRow) throws -> StoragePoolRecord {
        try StoragePoolRecord(row: row)
    }
}

private struct FindStoragePool: PostgresPreparedStatement {
    static let sql = "SELECT \(storagePoolColumns) FROM storage_pools WHERE id = $1"
    typealias Row = StoragePoolRecord
    let id: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> StoragePoolRecord {
        try StoragePoolRecord(row: row)
    }
}

private struct FindDefaultStoragePool: PostgresPreparedStatement {
    static let sql = "SELECT \(storagePoolColumns) FROM storage_pools WHERE name = $1"
    typealias Row = StoragePoolRecord

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(StoragePoolsPersistence.defaultPoolName)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> StoragePoolRecord {
        try StoragePoolRecord(row: row)
    }
}

private struct UpdateStoragePool: PostgresPreparedStatement {
    static let sql = """
        UPDATE storage_pools
        SET mode = $2,
            replication_factor = $3,
            member_agent_ids = $4,
            backing = $5,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING \(storagePoolColumns)
        """
    static let bindingDataTypes: [PostgresDataType] = [.uuid, .text, .int8, .textArray, .text]
    typealias Row = StoragePoolRecord
    let id: UUID
    let mode: StoragePoolMode
    let replicationFactor: Int
    let memberAgentIDs: [String]
    let backing: StoragePoolBacking

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 5)
        bindings.append(id)
        bindings.append(mode.rawValue)
        bindings.append(replicationFactor)
        bindings.append(memberAgentIDs)
        bindings.append(backing.rawValue)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> StoragePoolRecord {
        try StoragePoolRecord(row: row)
    }
}
