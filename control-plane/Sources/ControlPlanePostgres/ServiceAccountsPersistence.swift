import Foundation
import PostgresNIO

public struct ServiceAccountSnapshot: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let description: String
    public let projectID: UUID
    public let createdAt: Date?
    public let updatedAt: Date?
}

public struct ServiceAccountWrite: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let description: String
    public let projectID: UUID

    public init(
        id: UUID = UUID(),
        name: String,
        description: String = "",
        projectID: UUID
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.projectID = projectID
    }
}

/// The creator's explicit, revocable admin grant written atomically with a
/// service account. IAM vocabulary stays in the Vapor target; persistence
/// receives only stable identifiers.
public struct ServiceAccountCreatorGrant: Equatable, Sendable {
    public let id: UUID
    public let principalID: UUID
    public let roleID: UUID
    public let createdBy: UUID

    public init(
        id: UUID = UUID(),
        principalID: UUID,
        roleID: UUID,
        createdBy: UUID
    ) {
        self.id = id
        self.principalID = principalID
        self.roleID = roleID
        self.createdBy = createdBy
    }
}

public enum ServiceAccountsPersistenceError: Error, Equatable, Sendable {
    case duplicateName(projectID: UUID, name: String)
    case unexpectedRowCount(expected: Int, actual: Int)
}

public struct ServiceAccountsPersistence: Sendable {
    private let database: PostgresDatabase

    init(database: PostgresDatabase) {
        self.database = database
    }

    public func account(id: UUID) async throws -> ServiceAccountSnapshot? {
        try await database.withSession(operation: "service_accounts.lookup") { session in
            try oneOrNone(
                await session.execute(
                    FindServiceAccount(id: id),
                    operation: "service_accounts.lookup.query"))
        }
    }

    public func accounts(projectID: UUID) async throws -> [ServiceAccountSnapshot] {
        try await database.withSession(operation: "service_accounts.list_project") { session in
            try await session.execute(
                ListProjectServiceAccounts(projectID: projectID),
                operation: "service_accounts.list_project.query")
        }
    }

    public func accounts(ids: [UUID]) async throws -> [ServiceAccountSnapshot] {
        guard !ids.isEmpty else { return [] }
        return try await database.withSession(operation: "service_accounts.list_ids") { session in
            try await session.execute(
                ListServiceAccounts(ids: Array(Set(ids))),
                operation: "service_accounts.list_ids.query")
        }
    }

    public func create(
        _ write: ServiceAccountWrite,
        creatorGrant: ServiceAccountCreatorGrant? = nil
    ) async throws -> ServiceAccountSnapshot {
        do {
            return try await database.withTransaction(operation: "service_accounts.create") {
                session in
                let account = try only(
                    await session.execute(
                        InsertServiceAccount(write: write),
                        operation: "service_accounts.create.insert"))
                if let creatorGrant {
                    _ = try only(
                        await session.execute(
                            InsertServiceAccountCreatorGrant(
                                accountID: account.id,
                                grant: creatorGrant),
                            operation: "service_accounts.create.grant"))
                }
                return account
            }
        } catch let error as PSQLError
            where serviceAccountConstraint(
                error, named: "uq:service_accounts.project_id+service_accounts.name")
        {
            throw ServiceAccountsPersistenceError.duplicateName(
                projectID: write.projectID, name: write.name)
        }
    }

    public func replaceDescription(
        id: UUID,
        description: String
    ) async throws -> ServiceAccountSnapshot? {
        try await database.withSession(operation: "service_accounts.replace_description") {
            session in
            try oneOrNone(
                await session.execute(
                    ReplaceServiceAccountDescription(id: id, description: description),
                    operation: "service_accounts.replace_description.query"))
        }
    }

    /// Removes bindings attached to the account node and bindings held by the
    /// account principal before deleting it. Registration rows cascade through
    /// the existing foreign key.
    @discardableResult
    public func delete(id: UUID) async throws -> Bool {
        try await database.withTransaction(operation: "service_accounts.delete") { session in
            _ = try await session.execute(
                DeleteServiceAccountBindings(id: id),
                operation: "service_accounts.delete.bindings")
            return try await session.execute(
                DeleteServiceAccount(id: id),
                operation: "service_accounts.delete.account").count == 1
        }
    }

    private func only<Value>(_ rows: [Value]) throws -> Value {
        guard rows.count == 1, let value = rows.first else {
            throw ServiceAccountsPersistenceError.unexpectedRowCount(
                expected: 1, actual: rows.count)
        }
        return value
    }

    private func oneOrNone<Value>(_ rows: [Value]) throws -> Value? {
        guard rows.count <= 1 else {
            throw ServiceAccountsPersistenceError.unexpectedRowCount(
                expected: 1, actual: rows.count)
        }
        return rows.first
    }
}

private let serviceAccountColumns = "id, name, description, project_id, created_at, updated_at"

private protocol ServiceAccountStatement: PostgresPreparedStatement
    where Row == ServiceAccountSnapshot {}

private extension ServiceAccountStatement {
    func decodeRow(_ row: PostgresRow) throws -> ServiceAccountSnapshot {
        let value = try row.decode((UUID, String, String, UUID, Date?, Date?).self)
        return ServiceAccountSnapshot(
            id: value.0,
            name: value.1,
            description: value.2,
            projectID: value.3,
            createdAt: value.4,
            updatedAt: value.5)
    }
}

private struct FindServiceAccount: ServiceAccountStatement {
    static let sql = "SELECT \(serviceAccountColumns) FROM service_accounts WHERE id = $1"
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
}

private struct ListProjectServiceAccounts: ServiceAccountStatement {
    static let sql = """
        SELECT \(serviceAccountColumns)
        FROM service_accounts
        WHERE project_id = $1
        ORDER BY name, id
        """
    let projectID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(projectID)
        return bindings
    }
}

private struct ListServiceAccounts: ServiceAccountStatement {
    static let sql = """
        SELECT \(serviceAccountColumns)
        FROM service_accounts
        WHERE id = ANY($1)
        ORDER BY id
        """
    let ids: [UUID]
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(ids)
        return bindings
    }
}

private struct InsertServiceAccount: ServiceAccountStatement {
    static let sql = """
        INSERT INTO service_accounts (
            id, name, description, project_id, created_at, updated_at
        ) VALUES ($1, $2, $3, $4, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        RETURNING \(serviceAccountColumns)
        """
    let write: ServiceAccountWrite
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 4)
        bindings.append(write.id)
        bindings.append(write.name)
        bindings.append(write.description)
        bindings.append(write.projectID)
        return bindings
    }
}

private struct ReplaceServiceAccountDescription: ServiceAccountStatement {
    static let sql = """
        UPDATE service_accounts
        SET description = $2, updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING \(serviceAccountColumns)
        """
    let id: UUID
    let description: String
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(description)
        return bindings
    }
}

private struct InsertServiceAccountCreatorGrant: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO role_bindings (
            id, principal_type, principal_id, role_id, node_type, node_id,
            condition, expires_at, created_by, created_at
        ) VALUES ($1, 'user', $2, $3, 'service_account', $4, NULL, NULL, $5,
                  CURRENT_TIMESTAMP)
        RETURNING id
        """
    typealias Row = UUID
    let accountID: UUID
    let grant: ServiceAccountCreatorGrant
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 5)
        bindings.append(grant.id)
        bindings.append(grant.principalID)
        bindings.append(grant.roleID)
        bindings.append(accountID)
        bindings.append(grant.createdBy)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct DeleteServiceAccountBindings: PostgresPreparedStatement {
    static let sql = """
        DELETE FROM role_bindings
        WHERE (principal_type = 'service_account' AND principal_id = $1)
           OR (node_type = 'service_account' AND node_id = $1)
        RETURNING id
        """
    typealias Row = UUID
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct DeleteServiceAccount: PostgresPreparedStatement {
    static let sql = "DELETE FROM service_accounts WHERE id = $1 RETURNING id"
    typealias Row = UUID
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private func serviceAccountConstraint(_ error: PSQLError, named name: String) -> Bool {
    error.serverInfo?[.sqlState] == "23505" && error.serverInfo?[.constraintName] == name
}
