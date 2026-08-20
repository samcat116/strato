import ControlPlanePostgres
import Fluent
import Foundation
import SQLKit
import Vapor

/// Immutable service-account state for operations that still participate in a
/// caller-owned Fluent transaction. Native controller operations use
/// `ServiceAccountsPersistence` directly.
struct LegacyServiceAccountRecord: Decodable, Equatable, Sendable {
    let id: UUID
    let name: String
    let accountDescription: String
    let projectID: UUID
    let createdAt: Date?
    let updatedAt: Date?
}

enum LegacyServiceAccountStore {
    static func account(
        id: UUID,
        on db: any Database
    ) async throws -> LegacyServiceAccountRecord? {
        try await requireSQL(db).raw(
            "SELECT \(unsafeRaw: columns) FROM service_accounts WHERE id = \(bind: id)"
        ).first(decoding: LegacyServiceAccountRecord.self)
    }

    static func accounts(
        ids: [UUID],
        on db: any Database
    ) async throws -> [LegacyServiceAccountRecord] {
        guard !ids.isEmpty else { return [] }
        return try await requireSQL(db).raw(
            """
            SELECT \(unsafeRaw: columns)
            FROM service_accounts
            WHERE id = ANY(\(bind: ids))
            ORDER BY id
            """
        ).all(decoding: LegacyServiceAccountRecord.self)
    }

    static func ids(
        projectIDs: [UUID],
        on db: any Database
    ) async throws -> [UUID] {
        struct Identifier: Decodable { let id: UUID }
        guard !projectIDs.isEmpty else { return [] }
        return try await requireSQL(db).raw(
            "SELECT id FROM service_accounts WHERE project_id = ANY(\(bind: projectIDs)) ORDER BY id"
        ).all(decoding: Identifier.self).map(\.id)
    }

    @discardableResult
    static func insert(
        _ write: ServiceAccountWrite,
        on db: any Database
    ) async throws -> LegacyServiceAccountRecord {
        guard let account = try await requireSQL(db).raw(
            """
            INSERT INTO service_accounts (
                id, name, description, project_id, created_at, updated_at
            ) VALUES (
                \(bind: write.id), \(bind: write.name), \(bind: write.description),
                \(bind: write.projectID), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            )
            RETURNING \(unsafeRaw: columns)
            """
        ).first(decoding: LegacyServiceAccountRecord.self) else {
            throw Abort(.internalServerError, reason: "Could not create service account")
        }
        return account
    }

    static func delete(id: UUID, on db: any Database) async throws {
        try await requireSQL(db).raw(
            "DELETE FROM service_accounts WHERE id = \(bind: id)"
        ).run()
    }

    private static let columns = """
        id,
        name,
        description AS "accountDescription",
        project_id AS "projectID",
        created_at AS "createdAt",
        updated_at AS "updatedAt"
        """

    private static func requireSQL(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Service accounts require PostgreSQL")
        }
        return sql
    }
}
