import Foundation
import PostgresNIO
import Testing

@testable import ControlPlanePostgres

@Suite("Native group persistence", .serialized)
struct GroupsPersistenceTests {
    @Test("group lifecycle preserves scope, uniqueness, and member counts")
    func lifecycle() async throws {
        try await withGroupsDatabase { database, groups in
            let organizationID = UUID()
            let otherOrganizationID = UUID()
            try await seedOrganization(organizationID, database: database)
            try await seedOrganization(otherOrganizationID, database: database)

            let groupID = UUID()
            let created = try await groups.create(
                GroupWrite(
                    id: groupID,
                    organizationID: organizationID,
                    name: "Engineering",
                    description: "Builds Strato",
                    scimProvisioned: true
                )
            )
            _ = try await groups.create(
                GroupWrite(
                    organizationID: otherOrganizationID,
                    name: "Engineering",
                    description: "A separately scoped group"
                )
            )

            #expect(created.id == groupID)
            #expect(created.scimProvisioned)
            #expect(created.createdAt != nil)
            #expect(try await groups.group(id: groupID) == created)
            #expect(try await groups.ownedGroup(id: groupID, organizationID: organizationID) == created)
            #expect(try await groups.ownedGroup(id: groupID, organizationID: otherOrganizationID) == nil)
            #expect(try await groups.countOwnedGroups(ids: [groupID], organizationID: organizationID) == 1)
            #expect(try await groups.groups(organizationID: organizationID).first?.memberCount == 0)

            do {
                _ = try await groups.create(
                    GroupWrite(
                        organizationID: organizationID,
                        name: created.name,
                        description: "Duplicate"
                    )
                )
                Issue.record("Expected duplicate group name to fail")
            } catch let error as GroupPersistenceError {
                #expect(error == .duplicateName(organizationID: organizationID, name: created.name))
            }

            let replaced = try #require(
                try await groups.replace(
                    GroupWrite(
                        id: groupID,
                        organizationID: organizationID,
                        name: "Platform Engineering",
                        description: "Owns the platform"
                    )
                )
            )
            #expect(replaced.name == "Platform Engineering")
            #expect(replaced.description == "Owns the platform")
            #expect(!replaced.scimProvisioned)
            #expect(
                try await groups.replace(
                    GroupWrite(
                        id: groupID,
                        organizationID: otherOrganizationID,
                        name: "Must not move",
                        description: ""
                    )
                ) == nil
            )
        }
    }

    @Test("membership intent enforces organization eligibility and remains idempotent")
    func membershipIntent() async throws {
        try await withGroupsDatabase { database, groups in
            let organizationID = UUID()
            let eligibleUserID = UUID()
            let replacementUserID = UUID()
            let ineligibleUserID = UUID()
            try await seedOrganization(organizationID, database: database)
            try await seedUser(eligibleUserID, username: "eligible", database: database)
            try await seedUser(replacementUserID, username: "replacement", database: database)
            try await seedUser(ineligibleUserID, username: "external", database: database)
            try await seedOrganizationMember(eligibleUserID, organizationID: organizationID, database: database)
            try await seedOrganizationMember(replacementUserID, organizationID: organizationID, database: database)

            let first = try await groups.create(
                GroupWrite(organizationID: organizationID, name: "First", description: "")
            )
            let second = try await groups.create(
                GroupWrite(organizationID: organizationID, name: "Second", description: "")
            )

            let added = try await groups.addMembers(
                [eligibleUserID, eligibleUserID, ineligibleUserID],
                to: first.id,
                organizationID: organizationID
            )
            #expect(added.groupFound)
            #expect(Set(added.addedUserIDs) == [eligibleUserID])
            #expect(Set(added.ineligibleUserIDs) == [ineligibleUserID])
            #expect(try await groups.hasMember(userID: eligibleUserID, groupID: first.id))
            #expect(try await groups.members(groupID: first.id).map(\.username) == ["eligible"])
            #expect(try await groups.memberships(userIDs: [eligibleUserID]).count == 1)
            #expect(try await groups.memberships(groupIDs: [first.id]).count == 1)
            #expect(try await groups.memberCount(groupID: first.id) == 1)
            #expect(try await groups.groups(organizationID: organizationID).first?.memberCount == 1)

            let unchanged = try await groups.addMembers(
                [eligibleUserID],
                to: first.id,
                organizationID: organizationID
            )
            #expect(unchanged.addedUserIDs.isEmpty)

            _ = try await groups.addMembers([eligibleUserID], to: second.id, organizationID: organizationID)
            #expect(try await groups.groupsShareMember(first.id, second.id))
            #expect(!(try await groups.hasMemberOutsideOrganization(groupID: first.id, organizationID: organizationID)))

            try await insertHistoricalMembership(
                userID: ineligibleUserID,
                groupID: first.id,
                database: database
            )
            #expect(try await groups.hasMemberOutsideOrganization(groupID: first.id, organizationID: organizationID))

            let replaced = try await groups.replaceMembers(
                [replacementUserID],
                in: first.id,
                organizationID: organizationID
            )
            #expect(Set(replaced.removedUserIDs) == [eligibleUserID, ineligibleUserID])
            #expect(Set(replaced.addedUserIDs) == [replacementUserID])
            #expect(try await groups.members(groupID: first.id).map(\.userID) == [replacementUserID])

            #expect(
                try await groups.setMembership(
                    userID: replacementUserID,
                    groupID: first.id,
                    organizationID: organizationID,
                    desired: false
                ) == .applied
            )
            #expect(
                try await groups.setMembership(
                    userID: replacementUserID,
                    groupID: first.id,
                    organizationID: organizationID,
                    desired: false
                ) == .unchanged
            )
            #expect(
                try await groups.setMembership(
                    userID: ineligibleUserID,
                    groupID: first.id,
                    organizationID: organizationID,
                    desired: true
                ) == .userNotOrganizationMember
            )
            #expect(
                try await groups.setMembership(
                    userID: eligibleUserID,
                    groupID: UUID(),
                    organizationID: organizationID,
                    desired: true
                ) == .groupNotFound
            )
        }
    }

    @Test("SCIM search combines filters and preserves organization scope")
    func search() async throws {
        try await withGroupsDatabase { database, groups in
            let organizationID = UUID()
            let otherOrganizationID = UUID()
            try await seedOrganization(organizationID, database: database)
            try await seedOrganization(otherOrganizationID, database: database)
            for name in ["Platform Engineering", "Product Engineering", "Support"] {
                _ = try await groups.create(
                    GroupWrite(organizationID: organizationID, name: name, description: "")
                )
            }
            _ = try await groups.create(
                GroupWrite(
                    organizationID: otherOrganizationID,
                    name: "Platform Engineering",
                    description: ""
                )
            )

            let page = try await groups.search(
                organizationID: organizationID,
                filters: [.contains("ENGINEER"), .startsWith("plat")],
                offset: 0,
                limit: 10
            )
            #expect(page.total == 1)
            #expect(page.items.map(\.name) == ["Platform Engineering"])

            let paged = try await groups.search(
                organizationID: organizationID,
                offset: 1,
                limit: 1
            )
            #expect(paged.total == 3)
            #expect(paged.items.count == 1)
        }
    }

    @Test("delete atomically removes the group principal and memberships")
    func deleteCleanup() async throws {
        try await withGroupsDatabase { database, groups in
            let organizationID = UUID()
            let userID = UUID()
            try await seedOrganization(organizationID, database: database)
            try await seedUser(userID, username: "member", database: database)
            try await seedOrganizationMember(userID, organizationID: organizationID, database: database)
            let group = try await groups.create(
                GroupWrite(organizationID: organizationID, name: "Disposable", description: "")
            )
            _ = try await groups.addMembers([userID], to: group.id, organizationID: organizationID)
            try await insertRoleBinding(groupID: group.id, database: database)

            #expect(try await groups.delete(id: group.id, organizationID: UUID()) == false)
            #expect(try await groups.delete(id: group.id, organizationID: organizationID))
            #expect(try await groups.group(id: group.id) == nil)
            #expect(try await rowCount(CountTestMemberships(), database: database) == 0)
            #expect(try await rowCount(CountTestRoleBindings(), database: database) == 0)
            #expect(try await groups.delete(id: group.id, organizationID: organizationID) == false)
        }
    }

    private func withGroupsDatabase(
        _ test: (ControlPlanePostgres.PostgresDatabase, GroupsPersistence) async throws -> Void
    ) async throws {
        try await withBareNativePostgresDatabase { database in
            try await database.withSession(operation: "test.groups.schema") { session in
                _ = try await session.command(
                    "CREATE TABLE organizations (id UUID PRIMARY KEY)",
                    operation: "test.groups.schema.create_organizations"
                )
                _ = try await session.command(
                    """
                    CREATE TABLE users (
                        id UUID PRIMARY KEY,
                        username TEXT NOT NULL,
                        display_name TEXT NOT NULL,
                        email TEXT NOT NULL
                    )
                    """,
                    operation: "test.groups.schema.create_users"
                )
                _ = try await session.command(
                    """
                    CREATE TABLE groups (
                        id UUID PRIMARY KEY,
                        organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                        name TEXT NOT NULL,
                        description TEXT NOT NULL,
                        scim_provisioned BOOLEAN NOT NULL DEFAULT FALSE,
                        created_at TIMESTAMPTZ,
                        updated_at TIMESTAMPTZ,
                        CONSTRAINT "uq:groups.name+groups.organization_id"
                            UNIQUE (name, organization_id)
                    )
                    """,
                    operation: "test.groups.schema.create_groups"
                )
                _ = try await session.command(
                    """
                    CREATE TABLE user_organizations (
                        id UUID PRIMARY KEY,
                        user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                        organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                        created_at TIMESTAMPTZ,
                        UNIQUE (user_id, organization_id)
                    )
                    """,
                    operation: "test.groups.schema.create_organization_memberships"
                )
                _ = try await session.command(
                    """
                    CREATE TABLE user_groups (
                        id UUID PRIMARY KEY,
                        user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                        group_id UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
                        created_at TIMESTAMPTZ,
                        UNIQUE (user_id, group_id)
                    )
                    """,
                    operation: "test.groups.schema.create_group_memberships"
                )
                _ = try await session.command(
                    """
                    CREATE TABLE role_bindings (
                        id UUID PRIMARY KEY,
                        principal_type TEXT NOT NULL,
                        principal_id UUID NOT NULL
                    )
                    """,
                    operation: "test.groups.schema.create_role_bindings"
                )
            }
            try await test(database, ControlPlanePersistence(database: database).groups)
        }
    }

    private func seedOrganization(
        _ id: UUID,
        database: ControlPlanePostgres.PostgresDatabase
    ) async throws {
        try await database.withSession(operation: "test.groups.seed_organization") { session in
            _ = try await session.command(
                "INSERT INTO organizations (id) VALUES ('\(id)')",
                operation: "test.groups.seed_organization.insert"
            )
        }
    }

    private func seedUser(
        _ id: UUID,
        username: String,
        database: ControlPlanePostgres.PostgresDatabase
    ) async throws {
        try await database.withSession(operation: "test.groups.seed_user") { session in
            _ = try await session.command(
                """
                INSERT INTO users (id, username, display_name, email)
                VALUES ('\(id)', '\(username)', '\(username)', '\(username)@example.com')
                """,
                operation: "test.groups.seed_user.insert"
            )
        }
    }

    private func seedOrganizationMember(
        _ userID: UUID,
        organizationID: UUID,
        database: ControlPlanePostgres.PostgresDatabase
    ) async throws {
        try await database.withSession(operation: "test.groups.seed_organization_member") { session in
            _ = try await session.command(
                """
                INSERT INTO user_organizations (id, user_id, organization_id, created_at)
                VALUES ('\(UUID())', '\(userID)', '\(organizationID)', CURRENT_TIMESTAMP)
                """,
                operation: "test.groups.seed_organization_member.insert"
            )
        }
    }

    private func insertHistoricalMembership(
        userID: UUID,
        groupID: UUID,
        database: ControlPlanePostgres.PostgresDatabase
    ) async throws {
        try await database.withSession(operation: "test.groups.seed_historical_membership") { session in
            _ = try await session.command(
                """
                INSERT INTO user_groups (id, user_id, group_id, created_at)
                VALUES ('\(UUID())', '\(userID)', '\(groupID)', CURRENT_TIMESTAMP)
                """,
                operation: "test.groups.seed_historical_membership.insert"
            )
        }
    }

    private func insertRoleBinding(
        groupID: UUID,
        database: ControlPlanePostgres.PostgresDatabase
    ) async throws {
        try await database.withSession(operation: "test.groups.seed_role_binding") { session in
            _ = try await session.command(
                """
                INSERT INTO role_bindings (id, principal_type, principal_id)
                VALUES ('\(UUID())', 'group', '\(groupID)')
                """,
                operation: "test.groups.seed_role_binding.insert"
            )
        }
    }

    private func rowCount<Statement: PostgresPreparedStatement>(
        _ statement: Statement,
        database: ControlPlanePostgres.PostgresDatabase
    ) async throws -> Int where Statement.Row == Int {
        try await database.withSession(operation: "test.groups.count") { session in
            try #require(
                try await session.execute(statement, operation: "test.groups.count.query").first
            )
        }
    }
}

private protocol TestGroupCountStatement: PostgresPreparedStatement where Row == Int {}

private extension TestGroupCountStatement {
    func makeBindings() -> PostgresBindings { PostgresBindings() }
    func decodeRow(_ row: PostgresRow) throws -> Int { try row.decode(Int.self) }
}

private struct CountTestMemberships: TestGroupCountStatement {
    static let sql = "SELECT count(*)::bigint FROM user_groups"
}

private struct CountTestRoleBindings: TestGroupCountStatement {
    static let sql = "SELECT count(*)::bigint FROM role_bindings"
}
