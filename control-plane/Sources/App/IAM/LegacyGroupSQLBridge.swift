import Fluent
import Foundation
import SQLKit

/// Temporary transaction-preserving bridge for hierarchy/IAM code that still
/// owns Fluent transactions while group persistence moves to PostgresNIO.
///
/// New group, SCIM, and OIDC operations must use `GroupsPersistence`. These
/// narrowly scoped reads and deletes exist only where moving one statement to
/// the native pool would split an existing transaction. Delete this bridge
/// when the hierarchy/IAM cohort moves its owning transactions.
enum LegacyGroupSQLBridge {
    struct GroupIdentity: Decodable, Sendable {
        let id: UUID
        let organizationID: UUID

        private enum CodingKeys: String, CodingKey {
            case id
            case organizationID = "organization_id"
        }
    }

    struct Membership: Decodable, Sendable {
        let userID: UUID
        let groupID: UUID

        private enum CodingKeys: String, CodingKey {
            case userID = "user_id"
            case groupID = "group_id"
        }
    }

    enum Error: Swift.Error {
        case requiresSQLDatabase
    }

    static func group(id: UUID, on db: any Database) async throws -> GroupIdentity? {
        try await sql(db).raw(
            "SELECT id, organization_id FROM groups WHERE id = \(bind: id)"
        ).first(decoding: GroupIdentity.self)
    }

    static func groups(ids: [UUID], on db: any Database) async throws -> [GroupIdentity] {
        guard !ids.isEmpty else { return [] }
        return try await sql(db).raw(
            "SELECT id, organization_id FROM groups WHERE id = ANY(\(bind: ids))"
        ).all(decoding: GroupIdentity.self)
    }

    static func groupIDs(organizationID: UUID, on db: any Database) async throws -> [UUID] {
        try await sql(db).raw(
            "SELECT id FROM groups WHERE organization_id = \(bind: organizationID)"
        ).all(decoding: IDRow.self).map(\.id)
    }

    static func memberships(userIDs: [UUID], on db: any Database) async throws -> [Membership] {
        guard !userIDs.isEmpty else { return [] }
        return try await sql(db).raw(
            "SELECT user_id, group_id FROM user_groups WHERE user_id = ANY(\(bind: userIDs))"
        ).all(decoding: Membership.self)
    }

    static func memberships(groupIDs: [UUID], on db: any Database) async throws -> [Membership] {
        guard !groupIDs.isEmpty else { return [] }
        return try await sql(db).raw(
            "SELECT user_id, group_id FROM user_groups WHERE group_id = ANY(\(bind: groupIDs))"
        ).all(decoding: Membership.self)
    }

    static func hasMember(userID: UUID, groupID: UUID, on db: any Database) async throws -> Bool {
        try await sql(db).raw(
            """
            SELECT EXISTS(
                SELECT 1 FROM user_groups
                WHERE user_id = \(bind: userID) AND group_id = \(bind: groupID)
            ) AS value
            """
        ).first(decoding: BoolRow.self)?.value ?? false
    }

    static func groupsShareMember(_ first: UUID, _ second: UUID, on db: any Database) async throws -> Bool {
        try await sql(db).raw(
            """
            SELECT EXISTS(
                SELECT 1
                FROM user_groups first_membership
                JOIN user_groups second_membership
                  ON second_membership.user_id = first_membership.user_id
                WHERE first_membership.group_id = \(bind: first)
                  AND second_membership.group_id = \(bind: second)
            ) AS value
            """
        ).first(decoding: BoolRow.self)?.value ?? false
    }

    static func hasMemberOutsideOrganization(
        groupID: UUID, organizationID: UUID, on db: any Database
    ) async throws -> Bool {
        try await sql(db).raw(
            """
            SELECT EXISTS(
                SELECT 1
                FROM user_groups membership
                WHERE membership.group_id = \(bind: groupID)
                  AND NOT EXISTS (
                    SELECT 1 FROM user_organizations organization_membership
                    WHERE organization_membership.user_id = membership.user_id
                      AND organization_membership.organization_id = \(bind: organizationID)
                  )
            ) AS value
            """
        ).first(decoding: BoolRow.self)?.value ?? false
    }

    /// Must be called on the transaction that removes the organization
    /// membership, so group-derived grants cannot survive a partial commit.
    static func removeMemberships(
        userID: UUID, inOrganization organizationID: UUID, on db: any Database
    ) async throws {
        try await sql(db).raw(
            """
            DELETE FROM user_groups
            WHERE user_id = \(bind: userID)
              AND group_id IN (
                SELECT id FROM groups WHERE organization_id = \(bind: organizationID)
              )
            """
        ).run()
    }

    private struct IDRow: Decodable {
        let id: UUID
    }

    private struct BoolRow: Decodable {
        let value: Bool
    }

    private static func sql(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? any SQLDatabase else { throw Error.requiresSQLDatabase }
        return sql
    }
}
