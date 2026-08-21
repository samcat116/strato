import ControlPlanePostgres
import Foundation
import Vapor

/// Explicit project access for callers that still own a Fluent transaction.
enum LegacyProjectStore {
    static func project(id: UUID?, on db: PostgresStoreContext) async throws -> Project? {
        guard let id else { return nil }
        let rows = try await requireSQL(db).raw(
            "SELECT \(unsafeRaw: columns) FROM projects AS p WHERE p.id = \(bind: id)"
        ).all(decoding: Record.self)
        guard rows.count <= 1 else {
            throw Abort(.internalServerError, reason: "Project lookup returned duplicate rows")
        }
        return rows.first?.project
    }

    static func projects(
        ids: [UUID]? = nil,
        organizationIDs: [UUID] = [],
        organizationalUnitIDs: [UUID] = [],
        on db: PostgresStoreContext
    ) async throws -> [Project] {
        if ids?.isEmpty == true { return [] }
        if ids == nil && organizationIDs.isEmpty && organizationalUnitIDs.isEmpty {
            return try await requireSQL(db).raw(
                "SELECT \(unsafeRaw: columns) FROM projects AS p ORDER BY p.created_at, p.id"
            ).all(decoding: Record.self).map(\.project)
        }

        var query: PostgresSQLQuery = "SELECT \(unsafeRaw: columns) FROM projects AS p WHERE TRUE"
        if let ids { query += " AND p.id = ANY(\(bind: ids))" }
        if !organizationIDs.isEmpty || !organizationalUnitIDs.isEmpty {
            query += " AND (FALSE"
            if !organizationIDs.isEmpty { query += " OR p.organization_id = ANY(\(bind: organizationIDs))" }
            if !organizationalUnitIDs.isEmpty {
                query += " OR p.organizational_unit_id = ANY(\(bind: organizationalUnitIDs))"
            }
            query += ")"
        }
        query += " ORDER BY p.created_at, p.id"
        return try await requireSQL(db).raw(query).all(decoding: Record.self).map(\.project)
    }

    static func search(
        organizationIDs: [UUID] = [],
        organizationalUnitIDs: [UUID] = [],
        query term: String,
        limit: Int = 10,
        on db: PostgresStoreContext
    ) async throws -> [Project] {
        guard !organizationIDs.isEmpty || !organizationalUnitIDs.isEmpty else { return [] }
        var query: PostgresSQLQuery =
            "SELECT \(unsafeRaw: columns) FROM projects AS p WHERE (FALSE"
        if !organizationIDs.isEmpty { query += " OR p.organization_id = ANY(\(bind: organizationIDs))" }
        if !organizationalUnitIDs.isEmpty {
            query += " OR p.organizational_unit_id = ANY(\(bind: organizationalUnitIDs))"
        }
        query += ") AND (p.name ILIKE \(bind: "%\(term)%") OR p.description ILIKE \(bind: "%\(term)%"))"
        query += " ORDER BY p.name, p.id LIMIT \(bind: limit)"
        return try await requireSQL(db).raw(query).all(decoding: Record.self).map(\.project)
    }

    static func count(name: String? = nil, on db: PostgresStoreContext) async throws -> Int {
        struct Count: Decodable { let count: Int }
        var query: PostgresSQLQuery = "SELECT count(*)::bigint AS count FROM projects AS p WHERE TRUE"
        if let name { query += " AND p.name = \(bind: name)" }
        return try await requireSQL(db).raw(query).first(decoding: Count.self)?.count ?? 0
    }

    @discardableResult
    static func upsert(_ project: Project, on db: PostgresStoreContext) async throws -> Project {
        let id = try project.requireID()
        guard let row = try await requireSQL(db).raw(
            """
            INSERT INTO projects (
                id, name, description, organization_id, organizational_unit_id,
                path, default_environment, environments, created_at, updated_at
            ) VALUES (
                \(bind: id), \(bind: project.name), \(bind: project.description),
                \(bind: project.organizationID), \(bind: project.organizationalUnitID),
                \(bind: project.path), \(bind: project.defaultEnvironment),
                \(bind: project.environments), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            )
            ON CONFLICT (id) DO UPDATE SET
                name = EXCLUDED.name,
                description = EXCLUDED.description,
                organization_id = EXCLUDED.organization_id,
                organizational_unit_id = EXCLUDED.organizational_unit_id,
                path = EXCLUDED.path,
                default_environment = EXCLUDED.default_environment,
                environments = EXCLUDED.environments,
                updated_at = CURRENT_TIMESTAMP
            RETURNING \(unsafeRaw: returningColumns)
            """
        ).first(decoding: Record.self) else {
            throw Abort(.internalServerError, reason: "Could not persist project")
        }
        return row.project
    }

    @discardableResult
    static func delete(id: UUID, on db: PostgresStoreContext) async throws -> UUID? {
        struct Deleted: Decodable { let id: UUID }
        return try await requireSQL(db).raw(
            "DELETE FROM projects WHERE id = \(bind: id) RETURNING id"
        ).first(decoding: Deleted.self)?.id
    }

    private struct Record: Decodable, Sendable {
        let id: UUID
        let name: String
        let description: String
        let organizationID: UUID?
        let organizationalUnitID: UUID?
        let path: String
        let defaultEnvironment: String
        let environments: [String]
        let createdAt: Date?
        let updatedAt: Date?

        var project: Project {
            Project(
                id: id, name: name, description: description,
                organizationID: organizationID, organizationalUnitID: organizationalUnitID,
                path: path, defaultEnvironment: defaultEnvironment, environments: environments,
                createdAt: createdAt, updatedAt: updatedAt)
        }
    }

    private static let columns = """
        p.id,
        p.name,
        p.description,
        p.organization_id AS "organizationID",
        p.organizational_unit_id AS "organizationalUnitID",
        p.path,
        p.default_environment AS "defaultEnvironment",
        p.environments,
        p.created_at AS "createdAt",
        p.updated_at AS "updatedAt"
        """

    private static let returningColumns = """
        id,
        name,
        description,
        organization_id AS "organizationID",
        organizational_unit_id AS "organizationalUnitID",
        path,
        default_environment AS "defaultEnvironment",
        environments,
        created_at AS "createdAt",
        updated_at AS "updatedAt"
        """

    private static func requireSQL(_ db: PostgresStoreContext) throws -> PostgresStoreContext {
        guard let sql = db as? PostgresStoreContext, sql.dialect.name == "postgresql" else {
            throw Abort(.internalServerError, reason: "Project compatibility access requires PostgreSQL")
        }
        return sql
    }
}
