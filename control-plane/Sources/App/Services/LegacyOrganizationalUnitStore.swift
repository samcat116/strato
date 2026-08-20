import Fluent
import Foundation
import SQLKit
import Vapor

/// Explicit folder access for callers that still own a Fluent transaction.
/// Returned rows are immutable values; relationship loading is intentionally absent.
enum LegacyOrganizationalUnitStore {
    static func organizationalUnit(id: UUID?, on db: any Database) async throws -> OrganizationalUnit? {
        guard let id else { return nil }
        let rows = try await requireSQL(db).raw(
            "SELECT \(unsafeRaw: columns) FROM organizational_units AS ou WHERE ou.id = \(bind: id)"
        ).all(decoding: Record.self)
        guard rows.count <= 1 else {
            throw Abort(.internalServerError, reason: "Folder lookup returned duplicate rows")
        }
        return rows.first?.organizationalUnit
    }

    static func organizationalUnits(
        ids: [UUID]? = nil,
        organizationIDs: [UUID]? = nil,
        on db: any Database
    ) async throws -> [OrganizationalUnit] {
        if ids?.isEmpty == true || organizationIDs?.isEmpty == true { return [] }
        var query: SQLQueryString =
            "SELECT \(unsafeRaw: columns) FROM organizational_units AS ou WHERE TRUE"
        if let ids { query += " AND ou.id = ANY(\(bind: ids))" }
        if let organizationIDs { query += " AND ou.organization_id = ANY(\(bind: organizationIDs))" }
        query += " ORDER BY ou.depth, ou.name, ou.id"
        return try await requireSQL(db).raw(query).all(decoding: Record.self).map(\.organizationalUnit)
    }

    static func descendants(ofPath path: String, on db: any Database) async throws -> [OrganizationalUnit] {
        try await requireSQL(db).raw(
            """
            SELECT \(unsafeRaw: columns)
            FROM organizational_units AS ou
            WHERE ou.path LIKE \(bind: path + "/%")
            ORDER BY ou.name, ou.id
            """
        ).all(decoding: Record.self).map(\.organizationalUnit)
    }

    static func search(
        organizationIDs: [UUID],
        query term: String,
        limit: Int = 10,
        on db: any Database
    ) async throws -> [OrganizationalUnit] {
        guard !organizationIDs.isEmpty else { return [] }
        return try await requireSQL(db).raw(
            """
            SELECT \(unsafeRaw: columns)
            FROM organizational_units AS ou
            WHERE ou.organization_id = ANY(\(bind: organizationIDs))
              AND (ou.name ILIKE \(bind: "%\(term)%") OR ou.description ILIKE \(bind: "%\(term)%"))
            ORDER BY ou.name, ou.id
            LIMIT \(bind: limit)
            """
        ).all(decoding: Record.self).map(\.organizationalUnit)
    }

    @discardableResult
    static func upsert(_ folder: OrganizationalUnit, on db: any Database) async throws -> OrganizationalUnit {
        let id = try folder.requireID()
        guard let row = try await requireSQL(db).raw(
            """
            INSERT INTO organizational_units (
                id, name, description, organization_id, parent_ou_id,
                path, depth, created_at, updated_at
            ) VALUES (
                \(bind: id), \(bind: folder.name), \(bind: folder.description),
                \(bind: folder.organizationID), \(bind: folder.parentOUID),
                \(bind: folder.path), \(bind: folder.depth),
                CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            )
            ON CONFLICT (id) DO UPDATE SET
                name = EXCLUDED.name,
                description = EXCLUDED.description,
                organization_id = EXCLUDED.organization_id,
                parent_ou_id = EXCLUDED.parent_ou_id,
                path = EXCLUDED.path,
                depth = EXCLUDED.depth,
                updated_at = CURRENT_TIMESTAMP
            RETURNING \(unsafeRaw: returningColumns)
            """
        ).first(decoding: Record.self) else {
            throw Abort(.internalServerError, reason: "Could not persist folder")
        }
        return row.organizationalUnit
    }

    private struct Record: Decodable, Sendable {
        let id: UUID
        let name: String
        let description: String
        let organizationID: UUID
        let parentOUID: UUID?
        let path: String
        let depth: Int
        let createdAt: Date?
        let updatedAt: Date?

        var organizationalUnit: OrganizationalUnit {
            OrganizationalUnit(
                id: id,
                name: name,
                description: description,
                organizationID: organizationID,
                parentOUID: parentOUID,
                path: path,
                depth: depth,
                createdAt: createdAt,
                updatedAt: updatedAt)
        }
    }

    private static let columns = """
        ou.id,
        ou.name,
        ou.description,
        ou.organization_id AS "organizationID",
        ou.parent_ou_id AS "parentOUID",
        ou.path,
        ou.depth,
        ou.created_at AS "createdAt",
        ou.updated_at AS "updatedAt"
        """

    private static let returningColumns = """
        id,
        name,
        description,
        organization_id AS "organizationID",
        parent_ou_id AS "parentOUID",
        path,
        depth,
        created_at AS "createdAt",
        updated_at AS "updatedAt"
        """

    private static func requireSQL(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? any SQLDatabase, sql.dialect.name == "postgresql" else {
            throw Abort(.internalServerError, reason: "Folder compatibility access requires PostgreSQL")
        }
        return sql
    }
}
