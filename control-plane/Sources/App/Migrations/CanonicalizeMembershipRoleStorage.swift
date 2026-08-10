import Fluent
import Foundation
import SQLKit

/// STR-229: make role identity UUID-typed, export every legacy membership
/// grant into the authoritative binding store, and retire the project/group
/// grant mirrors. `user_organizations` remains because a row with no role is
/// meaningful bare membership.
struct CanonicalizeMembershipRoleStorage: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MembershipRoleMigrationError.unsupportedDatabase
        }

        try await database.schema(RoleBinding.schema)
            .field("role_id", .uuid)
            .update()
        try await database.schema(UserOrganization.schema)
            .field("role_id", .uuid)
            .update()
        try await database.schema(OIDCProvider.schema)
            .field("default_role_id", .uuid)
            .update()

        try await canonicalizeBindings(on: database)
        try await exportOrganizationMemberships(on: database)
        try await exportProjectMemberships(on: database)
        try await exportProjectGroupGrants(on: database)
        try await canonicalizeOIDCDefaults(on: database)
        try await verifyCutover(on: database)

        // Dropping the old role column also drops its role-inclusive unique
        // constraint. Recreate the same identity over the typed column.
        try await sql.raw("DROP INDEX IF EXISTS idx_role_bindings_role").run()
        try await sql.raw("ALTER TABLE role_bindings DROP COLUMN role CASCADE").run()
        try await sql.raw("ALTER TABLE role_bindings ALTER COLUMN role_id SET NOT NULL").run()
        try await sql.raw(
            """
            ALTER TABLE role_bindings
            ADD CONSTRAINT uq_role_bindings_principal_role_node
            UNIQUE (principal_type, principal_id, role_id, node_type, node_id)
            """
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_role_bindings_role_id ON role_bindings (role_id)"
        ).run()

        try await sql.raw("ALTER TABLE user_organizations DROP COLUMN role").run()
        try await sql.raw("ALTER TABLE oidc_providers DROP COLUMN default_role").run()
        try await database.schema("project_group_grants").delete()
        try await database.schema("project_members").delete()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MembershipRoleMigrationError.unsupportedDatabase
        }

        try await database.schema("project_members")
            .id()
            .field("project_id", .uuid, .required, .references("projects", "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("role", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "project_id", "user_id")
            .create()
        try await database.schema("project_group_grants")
            .id()
            .field("project_id", .uuid, .required, .references("projects", "id", onDelete: .cascade))
            .field("group_id", .uuid, .required, .references("groups", "id", onDelete: .cascade))
            .field("role", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "project_id", "group_id")
            .create()

        // A downgrade can only represent one role per project principal. Pick
        // the earliest live binding deterministically; the current schema keeps
        // every binding authoritative until this point.
        try await sql.raw(
            """
            INSERT INTO project_members (id, project_id, user_id, role, created_at, updated_at)
            SELECT DISTINCT ON (node_id, principal_id)
                gen_random_uuid(), node_id, principal_id, upper(role_id::text), created_at, created_at
            FROM role_bindings
            WHERE node_type = 'project' AND principal_type = 'user'
              AND (expires_at IS NULL OR expires_at > now())
            ORDER BY node_id, principal_id, created_at NULLS LAST, id
            """
        ).run()
        try await sql.raw(
            """
            INSERT INTO project_group_grants (id, project_id, group_id, role, created_at, updated_at)
            SELECT DISTINCT ON (node_id, principal_id)
                gen_random_uuid(), node_id, principal_id, upper(role_id::text), created_at, created_at
            FROM role_bindings
            WHERE node_type = 'project' AND principal_type = 'group'
              AND (expires_at IS NULL OR expires_at > now())
            ORDER BY node_id, principal_id, created_at NULLS LAST, id
            """
        ).run()

        try await sql.raw("ALTER TABLE user_organizations ADD COLUMN role text").run()
        try await sql.raw(
            "UPDATE user_organizations SET role = COALESCE(upper(role_id::text), 'member')"
        ).run()
        try await sql.raw("ALTER TABLE user_organizations ALTER COLUMN role SET NOT NULL").run()
        try await sql.raw("ALTER TABLE user_organizations DROP COLUMN role_id").run()

        try await sql.raw("ALTER TABLE oidc_providers ADD COLUMN default_role text").run()
        try await sql.raw(
            "UPDATE oidc_providers SET default_role = COALESCE(upper(default_role_id::text), 'member')"
        ).run()
        try await sql.raw("ALTER TABLE oidc_providers ALTER COLUMN default_role SET NOT NULL").run()
        try await sql.raw("ALTER TABLE oidc_providers DROP COLUMN default_role_id").run()

        try await sql.raw("ALTER TABLE role_bindings ADD COLUMN role text").run()
        try await sql.raw("UPDATE role_bindings SET role = upper(role_id::text)").run()
        try await sql.raw("ALTER TABLE role_bindings ALTER COLUMN role SET NOT NULL").run()
        try await sql.raw(
            "ALTER TABLE role_bindings DROP CONSTRAINT IF EXISTS uq_role_bindings_principal_role_node"
        ).run()
        try await sql.raw("DROP INDEX IF EXISTS idx_role_bindings_role_id").run()
        try await sql.raw("ALTER TABLE role_bindings DROP COLUMN role_id").run()
        try await sql.raw(
            """
            ALTER TABLE role_bindings
            ADD CONSTRAINT uq_role_bindings_principal_role_node
            UNIQUE (principal_type, principal_id, role, node_type, node_id)
            """
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_role_bindings_role ON role_bindings (role)"
        ).run()
    }

    // MARK: - Prepare

    private func canonicalizeBindings(on database: Database) async throws {
        let rows = try await LegacyRoleBinding.query(on: database)
            .sort(\.$createdAt)
            .all()
        var retainedByKey: [BindingKey: LegacyRoleBinding] = [:]

        for row in rows {
            guard let principalType = IAMPrincipalType(rawValue: row.principalType),
                let nodeType = IAMNodeType(rawValue: row.nodeType)
            else {
                throw MembershipRoleMigrationError.invalidBinding(row.id, row.principalType, row.nodeType)
            }
            let node = IAMNode(type: nodeType, id: row.nodeID)
            let roleID = try await canonicalRoleID(row.role, node: node, on: database)
            let key = BindingKey(
                principalType: principalType, principalID: row.principalID,
                roleID: roleID, node: node)

            if let retained = retainedByKey[key] {
                // Duplicate textual encodings represented the same grant. Keep
                // the union of their TTLs: nil is unbounded; otherwise the later
                // expiry is the access the two rows jointly conferred.
                retained.expiresAt = mergedExpiry(retained.expiresAt, row.expiresAt)
                if retained.createdBy == nil { retained.createdBy = row.createdBy }
                try await retained.save(on: database)
                try await row.delete(on: database)
                continue
            }

            row.roleID = roleID
            try await row.save(on: database)
            retainedByKey[key] = row
        }
    }

    private func exportOrganizationMemberships(on database: Database) async throws {
        for membership in try await LegacyOrganizationMembership.query(on: database).all() {
            let node = IAMNode(type: .organization, id: membership.organizationID)
            let roleID: UUID?
            if membership.role == "member" {
                roleID = nil
            } else {
                roleID = try await canonicalRoleID(membership.role, node: node, on: database)
            }
            membership.roleID = roleID
            try await membership.save(on: database)
            if let roleID {
                try await upsertBinding(
                    principalType: .user, principalID: membership.userID,
                    roleID: roleID, node: node, createdAt: membership.createdAt,
                    on: database)
            }
        }
    }

    private func exportProjectMemberships(on database: Database) async throws {
        for membership in try await LegacyProjectMembership.query(on: database).all() {
            let node = IAMNode(type: .project, id: membership.projectID)
            let roleID = try await canonicalRoleID(membership.role, node: node, on: database)
            try await upsertBinding(
                principalType: .user, principalID: membership.userID,
                roleID: roleID, node: node, createdAt: membership.createdAt,
                on: database)
        }
    }

    private func exportProjectGroupGrants(on database: Database) async throws {
        for grant in try await LegacyProjectGroupGrant.query(on: database).all() {
            let node = IAMNode(type: .project, id: grant.projectID)
            let roleID = try await canonicalRoleID(grant.role, node: node, on: database)
            try await upsertBinding(
                principalType: .group, principalID: grant.groupID,
                roleID: roleID, node: node, createdAt: grant.createdAt,
                on: database)
        }
    }

    private func canonicalizeOIDCDefaults(on database: Database) async throws {
        for provider in try await LegacyOIDCProviderRole.query(on: database).all() {
            if provider.defaultRole == "member" {
                provider.defaultRoleID = nil
            } else {
                provider.defaultRoleID = try await canonicalRoleID(
                    provider.defaultRole,
                    node: IAMNode(type: .organization, id: provider.organizationID),
                    on: database)
            }
            try await provider.save(on: database)
        }
    }

    private func upsertBinding(
        principalType: IAMPrincipalType,
        principalID: UUID,
        roleID: UUID,
        node: IAMNode,
        createdAt: Date?,
        on database: Database
    ) async throws {
        if let existing = try await LegacyRoleBinding.query(on: database)
            .filter(\.$principalType == principalType.rawValue)
            .filter(\.$principalID == principalID)
            .filter(\.$roleID == roleID)
            .filter(\.$nodeType == node.type.rawValue)
            .filter(\.$nodeID == node.id)
            .first()
        {
            // A relational grant has no TTL. If the same binding happened to
            // carry an expiry, the two representations jointly conferred the
            // unbounded grant; preserve that union before deleting the mirror.
            if existing.expiresAt != nil {
                existing.expiresAt = nil
                try await existing.save(on: database)
            }
            return
        }

        let binding = LegacyRoleBinding()
        binding.id = UUID()
        binding.principalType = principalType.rawValue
        binding.principalID = principalID
        binding.role = roleID.uuidString
        binding.roleID = roleID
        binding.nodeType = node.type.rawValue
        binding.nodeID = node.id
        binding.condition = nil
        binding.expiresAt = nil
        binding.createdBy = nil
        binding.createdAt = createdAt
        try await binding.create(on: database)
    }

    private func verifyCutover(on database: Database) async throws {
        if try await LegacyRoleBinding.query(on: database).filter(\.$roleID == nil).first() != nil {
            throw MembershipRoleMigrationError.incomplete("a role binding has no canonical role id")
        }

        for membership in try await LegacyOrganizationMembership.query(on: database).all() {
            guard let roleID = membership.roleID else { continue }
            try await requireBinding(
                principalType: .user, principalID: membership.userID, roleID: roleID,
                node: IAMNode(type: .organization, id: membership.organizationID), on: database)
        }
        for membership in try await LegacyProjectMembership.query(on: database).all() {
            let roleID = try await canonicalRoleID(
                membership.role, node: IAMNode(type: .project, id: membership.projectID), on: database)
            try await requireBinding(
                principalType: .user, principalID: membership.userID, roleID: roleID,
                node: IAMNode(type: .project, id: membership.projectID), on: database)
        }
        for grant in try await LegacyProjectGroupGrant.query(on: database).all() {
            let roleID = try await canonicalRoleID(
                grant.role, node: IAMNode(type: .project, id: grant.projectID), on: database)
            try await requireBinding(
                principalType: .group, principalID: grant.groupID, roleID: roleID,
                node: IAMNode(type: .project, id: grant.projectID), on: database)
        }
    }

    private func requireBinding(
        principalType: IAMPrincipalType,
        principalID: UUID,
        roleID: UUID,
        node: IAMNode,
        on database: Database
    ) async throws {
        let binding = try await LegacyRoleBinding.query(on: database)
            .filter(\.$principalType == principalType.rawValue)
            .filter(\.$principalID == principalID)
            .filter(\.$roleID == roleID)
            .filter(\.$nodeType == node.type.rawValue)
            .filter(\.$nodeID == node.id)
            .first()
        guard binding != nil else {
            throw MembershipRoleMigrationError.incomplete(
                "missing \(principalType.rawValue) binding for \(principalID) on \(node.type.rawValue) \(node.id)")
        }
    }

    private func canonicalRoleID(
        _ stored: String, node: IAMNode, on database: Database
    ) async throws -> UUID {
        if let roleID = UUID(uuidString: stored) {
            return try await validatedRoleID(roleID, stored: stored, node: node, on: database)
        }
        if node.type == .project, stored == "member" {
            return try await validatedRoleID(
                IAMRole.editor.seededID, stored: stored, node: node, on: database)
        }
        if let seeded = IAMRole(rawValue: stored) {
            return try await validatedRoleID(
                seeded.seededID, stored: stored, node: node, on: database)
        }

        let chain = try await IAMResourceTree.ancestors(of: node, on: database)
        let matches = try await RoleStore.bindable(named: stored, along: chain, on: database)
        guard matches.count == 1, let roleID = matches[0].id else {
            throw MembershipRoleMigrationError.ambiguousRole(stored, node, matches.compactMap(\.id))
        }
        return roleID
    }

    private func validatedRoleID(
        _ roleID: UUID,
        stored: String,
        node: IAMNode,
        on database: Database
    ) async throws -> UUID {
        do {
            _ = try await MemberRoleResolver.resolve(roleID, scopeNode: node, on: database)
            return roleID
        } catch {
            throw MembershipRoleMigrationError.invalidRole(stored, node, String(describing: error))
        }
    }

    private func mergedExpiry(_ lhs: Date?, _ rhs: Date?) -> Date? {
        guard let lhs, let rhs else { return nil }
        return max(lhs, rhs)
    }
}

private struct BindingKey: Hashable {
    let principalType: IAMPrincipalType
    let principalID: UUID
    let roleID: UUID
    let node: IAMNode
}

private enum MembershipRoleMigrationError: Error, CustomStringConvertible {
    case unsupportedDatabase
    case invalidBinding(UUID?, String, String)
    case invalidRole(String, IAMNode, String)
    case ambiguousRole(String, IAMNode, [UUID])
    case incomplete(String)

    var description: String {
        switch self {
        case .unsupportedDatabase:
            return "CanonicalizeMembershipRoleStorage requires a SQL database"
        case .invalidBinding(let id, let principal, let node):
            return "Role binding \(id?.uuidString ?? "unknown") has invalid principal/node types \(principal)/\(node)"
        case .invalidRole(let stored, let node, let reason):
            return
                "Stored role '\(stored)' on \(node.type.rawValue) \(node.id) is not a valid in-scope role id: \(reason)"
        case .ambiguousRole(let stored, let node, let matches):
            return "Stored role '\(stored)' on \(node.type.rawValue) \(node.id) does not resolve uniquely (\(matches))"
        case .incomplete(let reason):
            return "Membership role cutover verification failed: \(reason)"
        }
    }
}

private final class LegacyRoleBinding: Model, @unchecked Sendable {
    static let schema = "role_bindings"
    @ID(key: .id) var id: UUID?
    @Field(key: "principal_type") var principalType: String
    @Field(key: "principal_id") var principalID: UUID
    @Field(key: "role") var role: String
    @OptionalField(key: "role_id") var roleID: UUID?
    @Field(key: "node_type") var nodeType: String
    @Field(key: "node_id") var nodeID: UUID
    @OptionalField(key: "condition") var condition: String?
    @OptionalField(key: "expires_at") var expiresAt: Date?
    @OptionalField(key: "created_by") var createdBy: UUID?
    @OptionalField(key: "created_at") var createdAt: Date?
    init() {}
}

private final class LegacyOrganizationMembership: Model, @unchecked Sendable {
    static let schema = "user_organizations"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    @Field(key: "organization_id") var organizationID: UUID
    @Field(key: "role") var role: String
    @OptionalField(key: "role_id") var roleID: UUID?
    @OptionalField(key: "created_at") var createdAt: Date?
    init() {}
}

private final class LegacyProjectMembership: Model, @unchecked Sendable {
    static let schema = "project_members"
    @ID(key: .id) var id: UUID?
    @Field(key: "project_id") var projectID: UUID
    @Field(key: "user_id") var userID: UUID
    @Field(key: "role") var role: String
    @OptionalField(key: "created_at") var createdAt: Date?
    init() {}
}

private final class LegacyProjectGroupGrant: Model, @unchecked Sendable {
    static let schema = "project_group_grants"
    @ID(key: .id) var id: UUID?
    @Field(key: "project_id") var projectID: UUID
    @Field(key: "group_id") var groupID: UUID
    @Field(key: "role") var role: String
    @OptionalField(key: "created_at") var createdAt: Date?
    init() {}
}

private final class LegacyOIDCProviderRole: Model, @unchecked Sendable {
    static let schema = "oidc_providers"
    @ID(key: .id) var id: UUID?
    @Field(key: "organization_id") var organizationID: UUID
    @Field(key: "default_role") var defaultRole: String
    @OptionalField(key: "default_role_id") var defaultRoleID: UUID?
    init() {}
}
