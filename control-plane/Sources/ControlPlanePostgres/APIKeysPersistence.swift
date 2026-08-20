import Foundation
import PostgresNIO

public struct APIKeyWrite: Sendable {
    public let id: UUID
    public let userID: UUID
    public let name: String
    public let keyHash: String
    public let keyPrefix: String
    public let restriction: StoredCredentialRestriction
    public let isActive: Bool
    public let expiresAt: Date?

    public init(
        id: UUID = UUID(),
        userID: UUID,
        name: String,
        keyHash: String,
        keyPrefix: String,
        restriction: StoredCredentialRestriction,
        isActive: Bool = true,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.userID = userID
        self.name = name
        self.keyHash = keyHash
        self.keyPrefix = keyPrefix
        self.restriction = restriction
        self.isActive = isActive
        self.expiresAt = expiresAt
    }
}

public struct APIKeyChanges: Sendable {
    public let name: String?
    public let restriction: StoredCredentialRestriction?
    public let isActive: Bool?

    public init(
        name: String? = nil,
        restriction: StoredCredentialRestriction? = nil,
        isActive: Bool? = nil
    ) {
        self.name = name
        self.restriction = restriction
        self.isActive = isActive
    }
}

public struct APIKeySnapshot: Equatable, Sendable {
    public let id: UUID
    public let userID: UUID
    public let name: String
    public let keyPrefix: String
    public let restriction: StoredCredentialRestriction
    public let isActive: Bool
    public let expiresAt: Date?
    public let lastUsedAt: Date?
    public let lastUsedIP: String?
    public let createdAt: Date?
    public let updatedAt: Date?

    public init(
        id: UUID,
        userID: UUID,
        name: String,
        keyPrefix: String,
        restriction: StoredCredentialRestriction,
        isActive: Bool = true,
        expiresAt: Date? = nil,
        lastUsedAt: Date? = nil,
        lastUsedIP: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.userID = userID
        self.name = name
        self.keyPrefix = keyPrefix
        self.restriction = restriction
        self.isActive = isActive
        self.expiresAt = expiresAt
        self.lastUsedAt = lastUsedAt
        self.lastUsedIP = lastUsedIP
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func isExpired(at now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return now > expiresAt
    }

    public func isValid(at now: Date = Date()) -> Bool {
        isActive && !isExpired(at: now)
    }
}

public enum APIKeyPersistenceError: Error, Equatable, Sendable {
    case limitReached(maximum: Int)
    case unexpectedRowCount(expected: Int, actual: Int)
}

/// Owns API-key issuance, lookup, rotation settings, and revocation policy.
public struct APIKeysPersistence: Sendable {
    private let database: PostgresDatabase

    init(database: PostgresDatabase) {
        self.database = database
    }

    public func activeKey(keyHash: String) async throws -> APIKeySnapshot? {
        try await database.withSession(operation: "api_keys.authenticate") { session in
            try await oneOrNone(
                session.execute(
                    FindActiveAPIKey(keyHash: keyHash),
                    operation: "api_keys.authenticate.query"
                )
            )
        }
    }

    public func keys(userID: UUID) async throws -> [APIKeySnapshot] {
        try await database.withSession(operation: "api_keys.list") { session in
            try await session.execute(
                ListAPIKeys(userID: userID),
                operation: "api_keys.list.query"
            ).map(\.snapshot)
        }
    }

    public func ownedKey(id: UUID, userID: UUID) async throws -> APIKeySnapshot? {
        try await database.withSession(operation: "api_keys.lookup_owned") { session in
            try await oneOrNone(
                session.execute(
                    FindOwnedAPIKey(id: id, userID: userID),
                    operation: "api_keys.lookup_owned.query"
                )
            )
        }
    }

    /// Issue a key while serializing the per-user limit check with issuance.
    public func issue(
        _ write: APIKeyWrite,
        maximumKeysPerUser: Int
    ) async throws -> APIKeySnapshot {
        precondition(maximumKeysPerUser > 0)
        return try await database.withTransaction(operation: "api_keys.issue") { session in
            let counts = try await session.execute(
                LockAndCountAPIKeys(userID: write.userID),
                operation: "api_keys.issue.lock_and_count"
            )
            guard counts.count == 1, let count = counts.first else {
                throw APIKeyPersistenceError.unexpectedRowCount(
                    expected: 1,
                    actual: counts.count
                )
            }
            guard count < maximumKeysPerUser else {
                throw APIKeyPersistenceError.limitReached(maximum: maximumKeysPerUser)
            }
            return try await only(
                session.execute(
                    InsertAPIKey(write: write),
                    operation: "api_keys.issue.insert"
                )
            )
        }
    }

    public func updateOwnedKey(
        id: UUID,
        userID: UUID,
        changes: APIKeyChanges
    ) async throws -> APIKeySnapshot? {
        try await database.withSession(operation: "api_keys.update_owned") { session in
            try await oneOrNone(
                session.execute(
                    UpdateOwnedAPIKey(id: id, userID: userID, changes: changes),
                    operation: "api_keys.update_owned.query"
                )
            )
        }
    }

    @discardableResult
    public func deleteOwnedKey(id: UUID, userID: UUID) async throws -> Bool {
        try await database.withSession(operation: "api_keys.delete_owned") { session in
            try await session.execute(
                DeleteOwnedAPIKey(id: id, userID: userID),
                operation: "api_keys.delete_owned.query"
            ).count == 1
        }
    }

    @discardableResult
    public func deactivateAll(userID: UUID) async throws -> Int {
        try await database.withSession(operation: "api_keys.deactivate_all") { session in
            try await session.execute(
                DeactivateAPIKeys(userID: userID),
                operation: "api_keys.deactivate_all.query"
            ).count
        }
    }

    @discardableResult
    public func recordUsage(
        id: UUID,
        usedAt: Date,
        sourceIP: String?,
        staleBefore: Date
    ) async throws -> Bool {
        try await database.withSession(operation: "api_keys.record_usage") { session in
            try await session.execute(
                RecordAPIKeyUsage(
                    id: id,
                    usedAt: usedAt,
                    sourceIP: sourceIP,
                    staleBefore: staleBefore
                ),
                operation: "api_keys.record_usage.query"
            ).count == 1
        }
    }

    private func oneOrNone(_ rows: [APIKeyRecord]) throws -> APIKeySnapshot? {
        guard rows.count <= 1 else {
            throw APIKeyPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
        }
        return rows.first?.snapshot
    }

    private func only(_ rows: [APIKeyRecord]) throws -> APIKeySnapshot {
        guard rows.count == 1, let row = rows.first else {
            throw APIKeyPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
        }
        return row.snapshot
    }
}

private struct APIKeyRecord: Sendable {
    let id: UUID
    let userID: UUID
    let name: String
    let keyHash: String
    let keyPrefix: String
    let restrictionActions: [String]
    let restrictionNodeType: String?
    let restrictionNodeID: UUID?
    let isActive: Bool
    let expiresAt: Date?
    let lastUsedAt: Date?
    let lastUsedIP: String?
    let createdAt: Date?
    let updatedAt: Date?

    init(row: PostgresRow) throws {
        (
            id, userID, name, keyHash, keyPrefix, restrictionActions,
            restrictionNodeType, restrictionNodeID, isActive, expiresAt,
            lastUsedAt, lastUsedIP, createdAt, updatedAt
        ) = try row.decode(
            (
                UUID, UUID, String, String, String, [String], String?, UUID?, Bool,
                Date?, Date?, String?, Date?, Date?
            ).self)
    }

    var snapshot: APIKeySnapshot {
        APIKeySnapshot(
            id: id,
            userID: userID,
            name: name,
            keyPrefix: keyPrefix,
            restriction: StoredCredentialRestriction(
                actions: restrictionActions,
                nodeType: restrictionNodeType,
                nodeID: restrictionNodeID
            ),
            isActive: isActive,
            expiresAt: expiresAt,
            lastUsedAt: lastUsedAt,
            lastUsedIP: lastUsedIP,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private let apiKeyColumns = """
    id, user_id, name, key_hash, key_prefix, restriction_actions,
    restriction_node_type, restriction_node_id, is_active, expires_at,
    last_used_at, last_used_ip, created_at, updated_at
    """

private protocol APIKeyRecordStatement: PostgresPreparedStatement where Row == APIKeyRecord {}

private extension APIKeyRecordStatement {
    func decodeRow(_ row: PostgresRow) throws -> APIKeyRecord {
        try APIKeyRecord(row: row)
    }
}

private struct FindActiveAPIKey: APIKeyRecordStatement {
    static let sql = "SELECT \(apiKeyColumns) FROM api_keys WHERE key_hash = $1 AND is_active = TRUE"
    let keyHash: String

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(keyHash)
        return bindings
    }
}

private struct ListAPIKeys: APIKeyRecordStatement {
    static let sql = """
        SELECT \(apiKeyColumns)
        FROM api_keys
        WHERE user_id = $1
        ORDER BY created_at DESC, id DESC
        """
    let userID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(userID)
        return bindings
    }
}

private struct FindOwnedAPIKey: APIKeyRecordStatement {
    static let sql = "SELECT \(apiKeyColumns) FROM api_keys WHERE id = $1 AND user_id = $2"
    let id: UUID
    let userID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(userID)
        return bindings
    }
}

private struct LockAndCountAPIKeys: PostgresPreparedStatement {
    static let sql = """
        WITH owner_lock AS (
            SELECT pg_advisory_xact_lock(hashtext($1))
        )
        SELECT count(*)::bigint
        FROM api_keys, owner_lock
        WHERE user_id = $2
        """
    typealias Row = Int64
    let userID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append("api-key-user:\(userID.uuidString.lowercased())")
        bindings.append(userID)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> Int64 {
        try row.decode(Int64.self)
    }
}

private struct InsertAPIKey: APIKeyRecordStatement {
    static let sql = """
        INSERT INTO api_keys (
            id, user_id, name, key_hash, key_prefix, restriction_actions,
            restriction_node_type, restriction_node_id, is_active, expires_at,
            last_used_at, last_used_ip, created_at, updated_at
        ) VALUES (
            $1, $2, $3, $4, $5, $6, $7, $8, $9, $10,
            NULL, NULL, CURRENT_TIMESTAMP, NULL
        )
        RETURNING \(apiKeyColumns)
        """
    static let bindingDataTypes: [PostgresDataType] = [
        .uuid, .uuid, .text, .text, .text, .textArray, .text, .uuid, .bool,
        .timestamptz,
    ]
    let write: APIKeyWrite

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 10)
        bindings.append(write.id)
        bindings.append(write.userID)
        bindings.append(write.name)
        bindings.append(write.keyHash)
        bindings.append(write.keyPrefix)
        bindings.append(write.restriction.actions)
        bindings.append(write.restriction.nodeType)
        bindings.append(write.restriction.nodeID)
        bindings.append(write.isActive)
        bindings.append(write.expiresAt)
        return bindings
    }
}

private struct UpdateOwnedAPIKey: APIKeyRecordStatement {
    static let sql = """
        UPDATE api_keys
        SET name = CASE WHEN $3 THEN $4 ELSE name END,
            restriction_actions = CASE WHEN $5 THEN $6 ELSE restriction_actions END,
            restriction_node_type = CASE WHEN $5 THEN $7 ELSE restriction_node_type END,
            restriction_node_id = CASE WHEN $5 THEN $8 ELSE restriction_node_id END,
            is_active = CASE WHEN $9 THEN $10 ELSE is_active END,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = $1 AND user_id = $2
        RETURNING \(apiKeyColumns)
        """
    static let bindingDataTypes: [PostgresDataType] = [
        .uuid, .uuid, .bool, .text, .bool, .textArray, .text, .uuid, .bool, .bool,
    ]
    let id: UUID
    let userID: UUID
    let changes: APIKeyChanges

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 10)
        bindings.append(id)
        bindings.append(userID)
        bindings.append(changes.name != nil)
        bindings.append(changes.name)
        bindings.append(changes.restriction != nil)
        bindings.append(changes.restriction?.actions)
        bindings.append(changes.restriction?.nodeType)
        bindings.append(changes.restriction?.nodeID)
        bindings.append(changes.isActive != nil)
        bindings.append(changes.isActive)
        return bindings
    }
}

private struct DeleteOwnedAPIKey: PostgresPreparedStatement {
    static let sql = "DELETE FROM api_keys WHERE id = $1 AND user_id = $2 RETURNING id"
    typealias Row = UUID
    let id: UUID
    let userID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(userID)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct DeactivateAPIKeys: PostgresPreparedStatement {
    static let sql = """
        UPDATE api_keys SET is_active = FALSE, updated_at = CURRENT_TIMESTAMP
        WHERE user_id = $1 AND is_active = TRUE
        RETURNING id
        """
    typealias Row = UUID
    let userID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(userID)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct RecordAPIKeyUsage: PostgresPreparedStatement {
    static let sql = """
        UPDATE api_keys
        SET last_used_at = $2, last_used_ip = $3, updated_at = CURRENT_TIMESTAMP
        WHERE id = $1 AND (last_used_at IS NULL OR last_used_at < $4)
        RETURNING id
        """
    static let bindingDataTypes: [PostgresDataType] = [
        .uuid, .timestamptz, .text, .timestamptz,
    ]
    typealias Row = UUID
    let id: UUID
    let usedAt: Date
    let sourceIP: String?
    let staleBefore: Date

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 4)
        bindings.append(id)
        bindings.append(usedAt)
        bindings.append(sourceIP)
        bindings.append(staleBefore)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}
