import Fluent
import Foundation
import SQLKit
import Vapor

/// Explicit account access for callers that still own a Fluent transaction.
/// The value interface prevents Fluent models or row streams escaping a lease.
enum LegacyUserStore {
    static func user(id: UUID?, on db: any Database) async throws -> User? {
        guard let id else { return nil }
        let rows = try await requireSQL(db).raw(
            "SELECT \(unsafeRaw: columns) FROM users AS u WHERE u.id = \(bind: id)"
        ).all(decoding: Record.self)
        guard rows.count <= 1 else {
            throw Abort(.internalServerError, reason: "User lookup returned duplicate rows")
        }
        return rows.first?.user
    }

    static func users(
        ids: [UUID]? = nil,
        username: String? = nil,
        email: String? = nil,
        oidcProviderID: UUID? = nil,
        oidcSubject: String? = nil,
        currentOrganizationID: UUID? = nil,
        isSystemAdmin: Bool? = nil,
        disabled: Bool? = nil,
        excludingID: UUID? = nil,
        orderByUsername: Bool = false,
        on db: any Database
    ) async throws -> [User] {
        if ids?.isEmpty == true { return [] }
        var query: SQLQueryString = "SELECT \(unsafeRaw: columns) FROM users AS u WHERE TRUE"
        if let ids { query += " AND u.id = ANY(\(bind: ids))" }
        if let username { query += " AND u.username = \(bind: username)" }
        if let email { query += " AND u.email = \(bind: email)" }
        if let oidcProviderID { query += " AND u.oidc_provider_id = \(bind: oidcProviderID)" }
        if let oidcSubject { query += " AND u.oidc_subject = \(bind: oidcSubject)" }
        if let currentOrganizationID {
            query += " AND u.current_organization_id = \(bind: currentOrganizationID)"
        }
        if let isSystemAdmin { query += " AND u.is_system_admin = \(bind: isSystemAdmin)" }
        if let disabled {
            query += disabled ? " AND u.disabled_at IS NOT NULL" : " AND u.disabled_at IS NULL"
        }
        if let excludingID { query += " AND u.id <> \(bind: excludingID)" }
        query += orderByUsername ? " ORDER BY u.username, u.id" : " ORDER BY u.created_at, u.id"
        return try await requireSQL(db).raw(query).all(decoding: Record.self).map(\.user)
    }

    static func conflictingUser(
        username: String,
        email: String,
        excludingID: UUID? = nil,
        on db: any Database
    ) async throws -> User? {
        var query: SQLQueryString =
            "SELECT \(unsafeRaw: columns) FROM users AS u WHERE (u.username = \(bind: username) OR u.email = \(bind: email))"
        if let excludingID { query += " AND u.id <> \(bind: excludingID)" }
        query += " ORDER BY u.created_at, u.id LIMIT 1"
        return try await requireSQL(db).raw(query).first(decoding: Record.self)?.user
    }

    static func count(on db: any Database) async throws -> Int {
        struct Count: Decodable { let count: Int }
        return try await requireSQL(db).raw(
            "SELECT count(*)::bigint AS count FROM users"
        ).first(decoding: Count.self)?.count ?? 0
    }

    @discardableResult
    static func upsert(_ user: User, on db: any Database) async throws -> User {
        let id = try user.requireID()
        guard let row = try await requireSQL(db).raw(
            """
            INSERT INTO users (
                id, username, email, display_name, current_organization_id,
                is_system_admin, source, oidc_provider_id, oidc_subject,
                scim_provisioned, scim_active, session_epoch, disabled_at,
                created_at, updated_at
            ) VALUES (
                \(bind: id), \(bind: user.username), \(bind: user.email),
                \(bind: user.displayName), \(bind: user.currentOrganizationId),
                \(bind: user.isSystemAdmin), \(bind: user.sourceRaw),
                \(bind: user.oidcProviderID), \(bind: user.oidcSubject),
                \(bind: user.scimProvisioned), \(bind: user.scimActive),
                \(bind: user.sessionEpoch), \(bind: user.disabledAt),
                CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            )
            ON CONFLICT (id) DO UPDATE SET
                username = EXCLUDED.username,
                email = EXCLUDED.email,
                display_name = EXCLUDED.display_name,
                current_organization_id = EXCLUDED.current_organization_id,
                is_system_admin = EXCLUDED.is_system_admin,
                source = EXCLUDED.source,
                oidc_provider_id = EXCLUDED.oidc_provider_id,
                oidc_subject = EXCLUDED.oidc_subject,
                scim_provisioned = EXCLUDED.scim_provisioned,
                scim_active = EXCLUDED.scim_active,
                session_epoch = EXCLUDED.session_epoch,
                disabled_at = EXCLUDED.disabled_at,
                updated_at = CURRENT_TIMESTAMP
            RETURNING \(unsafeRaw: returningColumns)
            """
        ).first(decoding: Record.self) else {
            throw Abort(.internalServerError, reason: "Could not persist user")
        }
        return row.user
    }

    @discardableResult
    static func delete(id: UUID, on db: any Database) async throws -> UUID? {
        struct Deleted: Decodable { let id: UUID }
        return try await requireSQL(db).raw(
            "DELETE FROM users WHERE id = \(bind: id) RETURNING id"
        ).first(decoding: Deleted.self)?.id
    }

    private struct Record: Decodable, Sendable {
        let id: UUID
        let username: String
        let email: String
        let displayName: String
        let currentOrganizationId: UUID?
        let isSystemAdmin: Bool
        let sourceRaw: String
        let oidcProviderID: UUID?
        let oidcSubject: String?
        let scimProvisioned: Bool
        let scimActive: Bool
        let sessionEpoch: Int
        let disabledAt: Date?
        let createdAt: Date?
        let updatedAt: Date?

        var user: User {
            User(
                id: id, username: username, email: email, displayName: displayName,
                currentOrganizationId: currentOrganizationId,
                isSystemAdmin: isSystemAdmin,
                source: UserSource(rawValue: sourceRaw) ?? .local,
                oidcProviderID: oidcProviderID, oidcSubject: oidcSubject,
                scimProvisioned: scimProvisioned, scimActive: scimActive,
                sessionEpoch: sessionEpoch, disabledAt: disabledAt,
                createdAt: createdAt, updatedAt: updatedAt)
        }
    }

    private static let columns = """
        u.id,
        u.username,
        u.email,
        u.display_name AS "displayName",
        u.current_organization_id AS "currentOrganizationId",
        u.is_system_admin AS "isSystemAdmin",
        u.source AS "sourceRaw",
        u.oidc_provider_id AS "oidcProviderID",
        u.oidc_subject AS "oidcSubject",
        u.scim_provisioned AS "scimProvisioned",
        u.scim_active AS "scimActive",
        u.session_epoch AS "sessionEpoch",
        u.disabled_at AS "disabledAt",
        u.created_at AS "createdAt",
        u.updated_at AS "updatedAt"
        """

    private static let returningColumns = """
        id,
        username,
        email,
        display_name AS "displayName",
        current_organization_id AS "currentOrganizationId",
        is_system_admin AS "isSystemAdmin",
        source AS "sourceRaw",
        oidc_provider_id AS "oidcProviderID",
        oidc_subject AS "oidcSubject",
        scim_provisioned AS "scimProvisioned",
        scim_active AS "scimActive",
        session_epoch AS "sessionEpoch",
        disabled_at AS "disabledAt",
        created_at AS "createdAt",
        updated_at AS "updatedAt"
        """

    private static func requireSQL(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? any SQLDatabase, sql.dialect.name == "postgresql" else {
            throw Abort(.internalServerError, reason: "User compatibility access requires PostgreSQL")
        }
        return sql
    }
}
