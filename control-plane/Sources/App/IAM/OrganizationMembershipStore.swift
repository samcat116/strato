import ControlPlanePostgres
import Fluent
import Foundation
import SQLKit

/// Immutable decoding state for the last hierarchy callers that still share a
/// Fluent transaction with identity writes. New hierarchy code uses
/// `HierarchyPersistence` directly.
struct LegacyOrganizationMembershipRecord: Decodable, Equatable, Sendable {
    let id: UUID
    let userID: UUID
    let organizationID: UUID
    let roleID: UUID?
    let createdAt: Date?
}

enum OrganizationMembershipStore {
    private static let columns = """
        id, user_id AS "userID", organization_id AS "organizationID",
        role_id AS "roleID", created_at AS "createdAt"
        """

    static func membership(
        userID: UUID, organizationID: UUID, on db: any Database
    ) async throws -> LegacyOrganizationMembershipRecord? {
        try await requireSQL(db).raw(
            """
            SELECT \(unsafeRaw: columns) FROM user_organizations
            WHERE user_id = \(bind: userID) AND organization_id = \(bind: organizationID)
            """
        ).first(decoding: LegacyOrganizationMembershipRecord.self)
    }

    static func firstMembership(
        userID: UUID, on db: any Database
    ) async throws -> LegacyOrganizationMembershipRecord? {
        try await requireSQL(db).raw(
            """
            SELECT \(unsafeRaw: columns) FROM user_organizations
            WHERE user_id = \(bind: userID)
            ORDER BY created_at, id LIMIT 1
            """
        ).first(decoding: LegacyOrganizationMembershipRecord.self)
    }

    static func memberships(
        userIDs: [UUID], on db: any Database
    ) async throws -> [LegacyOrganizationMembershipRecord] {
        guard !userIDs.isEmpty else { return [] }
        return try await requireSQL(db).raw(
            """
            SELECT \(unsafeRaw: columns) FROM user_organizations
            WHERE user_id = ANY(\(bind: userIDs))
            ORDER BY user_id, organization_id, id
            """
        ).all(decoding: LegacyOrganizationMembershipRecord.self)
    }

    static func memberships(
        organizationID: UUID, userIDs: [UUID]? = nil, on db: any Database
    ) async throws -> [LegacyOrganizationMembershipRecord] {
        let sql = try requireSQL(db)
        if let userIDs {
            guard !userIDs.isEmpty else { return [] }
            return try await sql.raw(
                """
                SELECT \(unsafeRaw: columns) FROM user_organizations
                WHERE organization_id = \(bind: organizationID)
                  AND user_id = ANY(\(bind: userIDs))
                ORDER BY user_id, id
                """
            ).all(decoding: LegacyOrganizationMembershipRecord.self)
        }
        return try await sql.raw(
            """
            SELECT \(unsafeRaw: columns) FROM user_organizations
            WHERE organization_id = \(bind: organizationID)
            ORDER BY user_id, id
            """
        ).all(decoding: LegacyOrganizationMembershipRecord.self)
    }

    static func insert(
        id: UUID = UUID(),
        userID: UUID,
        organizationID: UUID,
        roleID: UUID? = nil,
        on db: any Database
    ) async throws -> LegacyOrganizationMembershipRecord {
        guard let row = try await requireSQL(db).raw(
            """
            INSERT INTO user_organizations (id, user_id, organization_id, role_id, created_at)
            VALUES (
                \(bind: id), \(bind: userID), \(bind: organizationID),
                \(bind: roleID), CURRENT_TIMESTAMP
            )
            RETURNING \(unsafeRaw: columns)
            """
        ).first(decoding: LegacyOrganizationMembershipRecord.self) else {
            throw HierarchyPersistenceError.unexpectedRowCount(expected: 1, actual: 0)
        }
        return row
    }

    static func updateRole(
        id: UUID, roleID: UUID?, on db: any Database
    ) async throws -> LegacyOrganizationMembershipRecord? {
        try await requireSQL(db).raw(
            """
            UPDATE user_organizations SET role_id = \(bind: roleID)
            WHERE id = \(bind: id)
            RETURNING \(unsafeRaw: columns)
            """
        ).first(decoding: LegacyOrganizationMembershipRecord.self)
    }

    @discardableResult
    static func delete(id: UUID, on db: any Database) async throws -> Bool {
        struct Identifier: Decodable { let id: UUID }
        return try await requireSQL(db).raw(
            "DELETE FROM user_organizations WHERE id = \(bind: id) RETURNING id"
        ).first(decoding: Identifier.self) != nil
    }

    static func count(on db: any Database) async throws -> Int {
        struct CountRow: Decodable { let count: Int }
        return try await requireSQL(db).raw(
            "SELECT count(*)::bigint AS count FROM user_organizations"
        ).first(decoding: CountRow.self)?.count ?? 0
    }

    private static func requireSQL(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? any SQLDatabase else {
            throw HierarchyPersistenceError.unexpectedRowCount(expected: 1, actual: 0)
        }
        return sql
    }
}
