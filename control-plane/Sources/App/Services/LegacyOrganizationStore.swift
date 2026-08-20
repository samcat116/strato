import Fluent
import Foundation
import SQLKit
import Vapor

/// Explicit organization access for callers that still own a Fluent transaction.
enum LegacyOrganizationStore {
    static func organization(id: UUID?, on db: any Database) async throws -> Organization? {
        guard let id else { return nil }
        let rows = try await requireSQL(db).raw(
            "SELECT \(unsafeRaw: columns) FROM organizations AS o WHERE o.id = \(bind: id)"
        ).all(decoding: Record.self)
        guard rows.count <= 1 else {
            throw Abort(.internalServerError, reason: "Organization lookup returned duplicate rows")
        }
        return rows.first?.organization
    }

    static func organizations(
        name: String? = nil,
        caseInsensitiveName: String? = nil,
        on db: any Database
    ) async throws -> [Organization] {
        var query: SQLQueryString = "SELECT \(unsafeRaw: columns) FROM organizations AS o WHERE TRUE"
        if let name { query += " AND o.name = \(bind: name)" }
        if let caseInsensitiveName { query += " AND lower(o.name) = lower(\(bind: caseInsensitiveName))" }
        query += " ORDER BY o.created_at, o.id"
        return try await requireSQL(db).raw(query).all(decoding: Record.self).map(\.organization)
    }

    static func count(on db: any Database) async throws -> Int {
        struct Count: Decodable { let count: Int }
        return try await requireSQL(db).raw(
            "SELECT count(*)::bigint AS count FROM organizations"
        ).first(decoding: Count.self)?.count ?? 0
    }

    @discardableResult
    static func upsert(_ organization: Organization, on db: any Database) async throws -> Organization {
        let id = try organization.requireID()
        guard let row = try await requireSQL(db).raw(
            """
            INSERT INTO organizations (id, name, description, created_at, updated_at)
            VALUES (
                \(bind: id), \(bind: organization.name), \(bind: organization.description),
                CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            )
            ON CONFLICT (id) DO UPDATE SET
                name = EXCLUDED.name,
                description = EXCLUDED.description,
                updated_at = CURRENT_TIMESTAMP
            RETURNING \(unsafeRaw: returningColumns)
            """
        ).first(decoding: Record.self) else {
            throw Abort(.internalServerError, reason: "Could not persist organization")
        }
        return row.organization
    }

    @discardableResult
    static func delete(id: UUID, on db: any Database) async throws -> UUID? {
        struct Deleted: Decodable { let id: UUID }
        return try await requireSQL(db).raw(
            "DELETE FROM organizations WHERE id = \(bind: id) RETURNING id"
        ).first(decoding: Deleted.self)?.id
    }

    private struct Record: Decodable, Sendable {
        let id: UUID
        let name: String
        let description: String
        let createdAt: Date?
        let updatedAt: Date?

        var organization: Organization {
            Organization(
                id: id,
                name: name,
                description: description,
                createdAt: createdAt,
                updatedAt: updatedAt)
        }
    }

    private static let columns = """
        o.id,
        o.name,
        o.description,
        o.created_at AS "createdAt",
        o.updated_at AS "updatedAt"
        """

    private static let returningColumns = """
        id,
        name,
        description,
        created_at AS "createdAt",
        updated_at AS "updatedAt"
        """

    private static func requireSQL(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? any SQLDatabase, sql.dialect.name == "postgresql" else {
            throw Abort(.internalServerError, reason: "Organization compatibility access requires PostgreSQL")
        }
        return sql
    }
}
