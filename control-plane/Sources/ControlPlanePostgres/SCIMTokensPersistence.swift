import Foundation
import PostgresNIO

public struct SCIMTokenWrite: Sendable {
    public let id: UUID
    public let organizationID: UUID
    public let name: String
    public let tokenHash: String
    public let tokenPrefix: String
    public let isActive: Bool
    public let expiresAt: Date?
    public let createdByID: UUID

    public init(
        id: UUID = UUID(),
        organizationID: UUID,
        name: String,
        tokenHash: String,
        tokenPrefix: String,
        isActive: Bool = true,
        expiresAt: Date? = nil,
        createdByID: UUID
    ) {
        self.id = id
        self.organizationID = organizationID
        self.name = name
        self.tokenHash = tokenHash
        self.tokenPrefix = tokenPrefix
        self.isActive = isActive
        self.expiresAt = expiresAt
        self.createdByID = createdByID
    }
}

public struct SCIMTokenChanges: Sendable {
    public let name: String?
    public let isActive: Bool?

    public init(name: String? = nil, isActive: Bool? = nil) {
        self.name = name
        self.isActive = isActive
    }
}

public struct SCIMTokenSnapshot: Equatable, Sendable {
    public let id: UUID
    public let organizationID: UUID
    public let name: String
    public let tokenPrefix: String
    public let isActive: Bool
    public let expiresAt: Date?
    public let lastUsedAt: Date?
    public let lastUsedIP: String?
    public let createdByID: UUID
    public let createdAt: Date?
    public let updatedAt: Date?

    public init(
        id: UUID,
        organizationID: UUID,
        name: String,
        tokenPrefix: String,
        isActive: Bool = true,
        expiresAt: Date? = nil,
        lastUsedAt: Date? = nil,
        lastUsedIP: String? = nil,
        createdByID: UUID,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.organizationID = organizationID
        self.name = name
        self.tokenPrefix = tokenPrefix
        self.isActive = isActive
        self.expiresAt = expiresAt
        self.lastUsedAt = lastUsedAt
        self.lastUsedIP = lastUsedIP
        self.createdByID = createdByID
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

public enum SCIMTokenPersistenceError: Error, Equatable, Sendable {
    case unexpectedRowCount(expected: Int, actual: Int)
}

/// Owns organization-scoped SCIM provisioning credential lifecycle and usage.
public struct SCIMTokensPersistence: Sendable {
    private let database: PostgresDatabase

    init(database: PostgresDatabase) {
        self.database = database
    }

    public func token(tokenHash: String) async throws -> SCIMTokenSnapshot? {
        try await database.withSession(operation: "scim_tokens.authenticate") { session in
            try oneOrNone(
                await session.execute(
                    FindSCIMToken(tokenHash: tokenHash),
                    operation: "scim_tokens.authenticate.query"
                )
            )
        }
    }

    public func tokens(organizationID: UUID) async throws -> [SCIMTokenSnapshot] {
        try await database.withSession(operation: "scim_tokens.list") { session in
            try await session.execute(
                ListSCIMTokens(organizationID: organizationID),
                operation: "scim_tokens.list.query"
            ).map(\.snapshot)
        }
    }

    public func ownedToken(id: UUID, organizationID: UUID) async throws -> SCIMTokenSnapshot? {
        try await database.withSession(operation: "scim_tokens.lookup_owned") { session in
            try oneOrNone(
                await session.execute(
                    FindOwnedSCIMToken(id: id, organizationID: organizationID),
                    operation: "scim_tokens.lookup_owned.query"
                )
            )
        }
    }

    public func issue(_ write: SCIMTokenWrite) async throws -> SCIMTokenSnapshot {
        try await database.withSession(operation: "scim_tokens.issue") { session in
            try only(
                await session.execute(
                    InsertSCIMToken(write: write),
                    operation: "scim_tokens.issue.query"
                )
            )
        }
    }

    public func updateOwnedToken(
        id: UUID,
        organizationID: UUID,
        changes: SCIMTokenChanges
    ) async throws -> SCIMTokenSnapshot? {
        try await database.withSession(operation: "scim_tokens.update_owned") { session in
            try oneOrNone(
                await session.execute(
                    UpdateOwnedSCIMToken(
                        id: id,
                        organizationID: organizationID,
                        changes: changes
                    ),
                    operation: "scim_tokens.update_owned.query"
                )
            )
        }
    }

    @discardableResult
    public func deleteOwnedToken(id: UUID, organizationID: UUID) async throws -> Bool {
        try await database.withSession(operation: "scim_tokens.delete_owned") { session in
            try await session.execute(
                DeleteOwnedSCIMToken(id: id, organizationID: organizationID),
                operation: "scim_tokens.delete_owned.query"
            ).count == 1
        }
    }

    @discardableResult
    public func recordUsage(
        id: UUID,
        usedAt: Date,
        sourceIP: String?,
        staleBefore: Date
    ) async throws -> Bool {
        try await database.withSession(operation: "scim_tokens.record_usage") { session in
            try await session.execute(
                RecordSCIMTokenUsage(
                    id: id,
                    usedAt: usedAt,
                    sourceIP: sourceIP,
                    staleBefore: staleBefore
                ),
                operation: "scim_tokens.record_usage.query"
            ).count == 1
        }
    }

    private func oneOrNone(_ rows: [SCIMTokenRecord]) throws -> SCIMTokenSnapshot? {
        guard rows.count <= 1 else {
            throw SCIMTokenPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
        }
        return rows.first?.snapshot
    }

    private func only(_ rows: [SCIMTokenRecord]) throws -> SCIMTokenSnapshot {
        guard rows.count == 1, let row = rows.first else {
            throw SCIMTokenPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
        }
        return row.snapshot
    }
}

private struct SCIMTokenRecord: Sendable {
    let id: UUID
    let organizationID: UUID
    let name: String
    let tokenHash: String
    let tokenPrefix: String
    let isActive: Bool
    let expiresAt: Date?
    let lastUsedAt: Date?
    let lastUsedIP: String?
    let createdByID: UUID
    let createdAt: Date?
    let updatedAt: Date?

    init(row: PostgresRow) throws {
        (
            id, organizationID, name, tokenHash, tokenPrefix, isActive,
            expiresAt, lastUsedAt, lastUsedIP, createdByID, createdAt, updatedAt
        ) = try row.decode(
            (
                UUID, UUID, String, String, String, Bool,
                Date?, Date?, String?, UUID, Date?, Date?
            ).self
        )
    }

    var snapshot: SCIMTokenSnapshot {
        SCIMTokenSnapshot(
            id: id,
            organizationID: organizationID,
            name: name,
            tokenPrefix: tokenPrefix,
            isActive: isActive,
            expiresAt: expiresAt,
            lastUsedAt: lastUsedAt,
            lastUsedIP: lastUsedIP,
            createdByID: createdByID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private let scimTokenColumns = """
    id, organization_id, name, token_hash, token_prefix, is_active,
    expires_at, last_used_at, last_used_ip, created_by_id, created_at, updated_at
    """

private protocol SCIMTokenRecordStatement: PostgresPreparedStatement where Row == SCIMTokenRecord {}

private extension SCIMTokenRecordStatement {
    func decodeRow(_ row: PostgresRow) throws -> SCIMTokenRecord {
        try SCIMTokenRecord(row: row)
    }
}

private struct FindSCIMToken: SCIMTokenRecordStatement {
    static let sql = "SELECT \(scimTokenColumns) FROM scim_tokens WHERE token_hash = $1"
    let tokenHash: String

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(tokenHash)
        return bindings
    }
}

private struct ListSCIMTokens: SCIMTokenRecordStatement {
    static let sql = """
        SELECT \(scimTokenColumns)
        FROM scim_tokens
        WHERE organization_id = $1
        ORDER BY created_at DESC, id DESC
        """
    let organizationID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(organizationID)
        return bindings
    }
}

private struct FindOwnedSCIMToken: SCIMTokenRecordStatement {
    static let sql = "SELECT \(scimTokenColumns) FROM scim_tokens WHERE id = $1 AND organization_id = $2"
    let id: UUID
    let organizationID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(organizationID)
        return bindings
    }
}

private struct InsertSCIMToken: SCIMTokenRecordStatement {
    static let sql = """
        INSERT INTO scim_tokens (
            id, organization_id, name, token_hash, token_prefix, is_active,
            expires_at, last_used_at, last_used_ip, created_by_id, created_at, updated_at
        ) VALUES (
            $1, $2, $3, $4, $5, $6, $7, NULL, NULL, $8, CURRENT_TIMESTAMP, NULL
        )
        RETURNING \(scimTokenColumns)
        """
    static let bindingDataTypes: [PostgresDataType] = [
        .uuid, .uuid, .text, .text, .text, .bool, .timestamptz, .uuid,
    ]
    let write: SCIMTokenWrite

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 8)
        bindings.append(write.id)
        bindings.append(write.organizationID)
        bindings.append(write.name)
        bindings.append(write.tokenHash)
        bindings.append(write.tokenPrefix)
        bindings.append(write.isActive)
        bindings.append(write.expiresAt)
        bindings.append(write.createdByID)
        return bindings
    }
}

private struct UpdateOwnedSCIMToken: SCIMTokenRecordStatement {
    static let sql = """
        UPDATE scim_tokens
        SET name = CASE WHEN $3 THEN $4 ELSE name END,
            is_active = CASE WHEN $5 THEN $6 ELSE is_active END,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = $1 AND organization_id = $2
        RETURNING \(scimTokenColumns)
        """
    static let bindingDataTypes: [PostgresDataType] = [
        .uuid, .uuid, .bool, .text, .bool, .bool,
    ]
    let id: UUID
    let organizationID: UUID
    let changes: SCIMTokenChanges

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 6)
        bindings.append(id)
        bindings.append(organizationID)
        bindings.append(changes.name != nil)
        bindings.append(changes.name)
        bindings.append(changes.isActive != nil)
        bindings.append(changes.isActive)
        return bindings
    }
}

private struct DeleteOwnedSCIMToken: PostgresPreparedStatement {
    static let sql = "DELETE FROM scim_tokens WHERE id = $1 AND organization_id = $2 RETURNING id"
    typealias Row = UUID
    let id: UUID
    let organizationID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(organizationID)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct RecordSCIMTokenUsage: PostgresPreparedStatement {
    static let sql = """
        UPDATE scim_tokens
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
