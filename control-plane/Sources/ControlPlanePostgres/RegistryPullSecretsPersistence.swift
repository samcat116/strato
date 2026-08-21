import Foundation
import PostgresNIO

public struct RegistryPullSecretWrite: Sendable {
    public let id: UUID
    public let projectID: UUID
    public let registry: String
    public let username: String
    public let encryptedSecret: String

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        registry: String,
        username: String,
        encryptedSecret: String
    ) {
        self.id = id
        self.projectID = projectID
        self.registry = registry
        self.username = username
        self.encryptedSecret = encryptedSecret
    }
}

public struct RegistryPullSecretSnapshot: Equatable, Sendable {
    public let id: UUID
    public let projectID: UUID
    public let registry: String
    public let username: String
    public let encryptedSecret: String
    public let createdAt: Date?
    public let updatedAt: Date?
}

public enum RegistryPullSecretPersistenceError: Error, Equatable, Sendable {
    case duplicateRegistry(projectID: UUID, registry: String)
    case unexpectedRowCount(expected: Int, actual: Int)
}

/// Owns durable OCI registry credentials. Secret material remains encrypted in
/// every snapshot; callers must deliberately pass it through the application's
/// secrets-encryption service before using it.
public struct RegistryPullSecretsPersistence: Sendable {
    private let database: PostgresDatabase

    init(database: PostgresDatabase) {
        self.database = database
    }

    public func all() async throws -> [RegistryPullSecretSnapshot] {
        try await database.withSession(operation: "registry_pull_secrets.list_all") { session in
            try await session.execute(
                ListAllRegistryPullSecrets(),
                operation: "registry_pull_secrets.list_all.query"
            ).map(\.snapshot)
        }
    }

    public func secrets(projectID: UUID) async throws -> [RegistryPullSecretSnapshot] {
        try await secrets(projectIDs: [projectID])
    }

    public func secrets(projectIDs: Set<UUID>) async throws -> [RegistryPullSecretSnapshot] {
        guard !projectIDs.isEmpty else { return [] }
        return try await database.withSession(operation: "registry_pull_secrets.list_projects") { session in
            try await session.execute(
                ListRegistryPullSecrets(projectIDs: Array(projectIDs)),
                operation: "registry_pull_secrets.list_projects.query"
            ).map(\.snapshot)
        }
    }

    public func secret(id: UUID, projectID: UUID) async throws -> RegistryPullSecretSnapshot? {
        try await database.withSession(operation: "registry_pull_secrets.lookup") { session in
            let rows = try await session.execute(
                FindRegistryPullSecret(id: id, projectID: projectID),
                operation: "registry_pull_secrets.lookup.query"
            )
            return try oneOrNone(rows)?.snapshot
        }
    }

    public func create(_ write: RegistryPullSecretWrite) async throws -> RegistryPullSecretSnapshot {
        do {
            return try await database.withSession(operation: "registry_pull_secrets.create") { session in
                try only(
                    await session.execute(
                        InsertRegistryPullSecret(write: write),
                        operation: "registry_pull_secrets.create.query"
                    )
                ).snapshot
            }
        } catch let error as PSQLError
            where error.serverInfo?[.sqlState] == "23505"
                && error.serverInfo?[.constraintName]
                    == "uq:registry_pull_secrets.project_id+registry_pull_secrets.regis"
        {
            throw RegistryPullSecretPersistenceError.duplicateRegistry(
                projectID: write.projectID,
                registry: write.registry
            )
        }
    }

    public func update(
        id: UUID,
        projectID: UUID,
        username: String?,
        encryptedSecret: String?
    ) async throws -> RegistryPullSecretSnapshot? {
        try await database.withSession(operation: "registry_pull_secrets.update") { session in
            let rows = try await session.execute(
                UpdateRegistryPullSecret(
                    id: id,
                    projectID: projectID,
                    username: username,
                    encryptedSecret: encryptedSecret
                ),
                operation: "registry_pull_secrets.update.query"
            )
            return try oneOrNone(rows)?.snapshot
        }
    }

    @discardableResult
    public func delete(id: UUID, projectID: UUID) async throws -> RegistryPullSecretSnapshot? {
        try await database.withSession(operation: "registry_pull_secrets.delete") { session in
            let rows = try await session.execute(
                DeleteRegistryPullSecret(id: id, projectID: projectID),
                operation: "registry_pull_secrets.delete.query"
            )
            return try oneOrNone(rows)?.snapshot
        }
    }

    /// Startup convergence for rows written before encryption was configured.
    /// The compare-and-swap avoids overwriting a concurrent credential rotation.
    public func replaceEncryptedSecret(
        id: UUID,
        expectedCurrentValue: String,
        replacement: String
    ) async throws -> Bool {
        try await database.withSession(operation: "registry_pull_secrets.encrypt_legacy") { session in
            let rows = try await session.execute(
                ReplaceRegistryPullSecret(
                    id: id,
                    expectedCurrentValue: expectedCurrentValue,
                    replacement: replacement
                ),
                operation: "registry_pull_secrets.encrypt_legacy.query"
            )
            guard rows.count <= 1 else {
                throw RegistryPullSecretPersistenceError.unexpectedRowCount(
                    expected: 1,
                    actual: rows.count
                )
            }
            return !rows.isEmpty
        }
    }
}

private struct RegistryPullSecretRecord: Sendable {
    let id: UUID
    let projectID: UUID
    let registry: String
    let username: String
    let encryptedSecret: String
    let createdAt: Date?
    let updatedAt: Date?

    init(row: PostgresRow) throws {
        (id, projectID, registry, username, encryptedSecret, createdAt, updatedAt) =
            try row.decode((UUID, UUID, String, String, String, Date?, Date?).self)
    }

    var snapshot: RegistryPullSecretSnapshot {
        RegistryPullSecretSnapshot(
            id: id,
            projectID: projectID,
            registry: registry,
            username: username,
            encryptedSecret: encryptedSecret,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private let registryPullSecretColumns = """
    id, project_id, registry, username, secret, created_at, updated_at
    """

private struct ListAllRegistryPullSecrets: PostgresPreparedStatement {
    static let sql = """
        SELECT \(registryPullSecretColumns)
        FROM registry_pull_secrets
        ORDER BY project_id, registry, id
        """
    typealias Row = RegistryPullSecretRecord

    func makeBindings() -> PostgresBindings { PostgresBindings() }
    func decodeRow(_ row: PostgresRow) throws -> Row { try Row(row: row) }
}

private struct ListRegistryPullSecrets: PostgresPreparedStatement {
    static let sql = """
        SELECT \(registryPullSecretColumns)
        FROM registry_pull_secrets
        WHERE project_id = ANY($1)
        ORDER BY project_id, registry, id
        """
    typealias Row = RegistryPullSecretRecord
    let projectIDs: [UUID]

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(projectIDs)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Row { try Row(row: row) }
}

private struct FindRegistryPullSecret: PostgresPreparedStatement {
    static let sql = """
        SELECT \(registryPullSecretColumns)
        FROM registry_pull_secrets
        WHERE id = $1 AND project_id = $2
        """
    typealias Row = RegistryPullSecretRecord
    let id: UUID
    let projectID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(projectID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Row { try Row(row: row) }
}

private struct InsertRegistryPullSecret: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO registry_pull_secrets (
            id, project_id, registry, username, secret, created_at, updated_at
        ) VALUES ($1, $2, $3, $4, $5, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        RETURNING \(registryPullSecretColumns)
        """
    typealias Row = RegistryPullSecretRecord
    let write: RegistryPullSecretWrite

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 5)
        bindings.append(write.id)
        bindings.append(write.projectID)
        bindings.append(write.registry)
        bindings.append(write.username)
        bindings.append(write.encryptedSecret)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Row { try Row(row: row) }
}

private struct UpdateRegistryPullSecret: PostgresPreparedStatement {
    static let sql = """
        UPDATE registry_pull_secrets
        SET username = COALESCE($3, username),
            secret = COALESCE($4, secret),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = $1 AND project_id = $2
        RETURNING \(registryPullSecretColumns)
        """
    typealias Row = RegistryPullSecretRecord
    let id: UUID
    let projectID: UUID
    let username: String?
    let encryptedSecret: String?

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 4)
        bindings.append(id)
        bindings.append(projectID)
        bindings.append(username, context: .default)
        bindings.append(encryptedSecret, context: .default)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Row { try Row(row: row) }
}

private struct DeleteRegistryPullSecret: PostgresPreparedStatement {
    static let sql = """
        DELETE FROM registry_pull_secrets
        WHERE id = $1 AND project_id = $2
        RETURNING \(registryPullSecretColumns)
        """
    typealias Row = RegistryPullSecretRecord
    let id: UUID
    let projectID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(projectID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Row { try Row(row: row) }
}

private struct ReplaceRegistryPullSecret: PostgresPreparedStatement {
    static let sql = """
        UPDATE registry_pull_secrets
        SET secret = $3, updated_at = CURRENT_TIMESTAMP
        WHERE id = $1 AND secret = $2
        RETURNING id
        """
    typealias Row = UUID
    let id: UUID
    let expectedCurrentValue: String
    let replacement: String

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(id)
        bindings.append(expectedCurrentValue)
        bindings.append(replacement)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private func oneOrNone<T>(_ values: [T]) throws -> T? {
    guard values.count <= 1 else {
        throw RegistryPullSecretPersistenceError.unexpectedRowCount(
            expected: 1,
            actual: values.count
        )
    }
    return values.first
}

private func only<T>(_ values: [T]) throws -> T {
    guard values.count == 1, let value = values.first else {
        throw RegistryPullSecretPersistenceError.unexpectedRowCount(
            expected: 1,
            actual: values.count
        )
    }
    return value
}
