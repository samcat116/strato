import Foundation
import PostgresNIO
import Testing

@testable import ControlPlanePostgres

@Suite("Native hierarchy persistence", .serialized)
struct HierarchyPersistenceTests {
    @Test("organizational unit lifecycle keeps paths, counts, and delete guards consistent")
    func organizationalUnits() async throws {
        try await withHierarchyDatabase { database, hierarchy in
            let first = try await hierarchy.createOrganization(
                OrganizationWrite(name: "Folder Org", description: "First")
            )
            let second = try await hierarchy.createOrganization(
                OrganizationWrite(name: "Other Folder Org", description: "Second")
            )

            let root = try #require(
                try await hierarchy.createOrganizationalUnit(
                    OrganizationalUnitWrite(
                        organizationID: first.id,
                        parentID: nil,
                        name: "Engineering",
                        description: "Root"
                    )
                ).created
            )
            #expect(root.organizationalUnit.depth == 0)
            #expect(root.organizationalUnit.path == "/\(first.id)/\(root.organizationalUnit.id)")

            let child = try #require(
                try await hierarchy.createOrganizationalUnit(
                    OrganizationalUnitWrite(
                        organizationID: first.id,
                        parentID: root.organizationalUnit.id,
                        name: "Compute",
                        description: "Child"
                    )
                ).created
            )
            #expect(child.organizationalUnit.depth == 1)
            #expect(child.organizationalUnit.path == "\(root.organizationalUnit.path)/\(child.organizationalUnit.id)")

            #expect(
                try await hierarchy.createOrganizationalUnit(
                    OrganizationalUnitWrite(
                        organizationID: first.id,
                        parentID: root.organizationalUnit.id,
                        name: "Compute",
                        description: "Duplicate"
                    )
                ) == .duplicateName
            )
            #expect(
                try await hierarchy.createOrganizationalUnit(
                    OrganizationalUnitWrite(
                        organizationID: second.id,
                        parentID: root.organizationalUnit.id,
                        name: "Foreign",
                        description: "Invalid"
                    )
                ) == .parentOutsideOrganization
            )

            let listedRoot = try #require(
                try await hierarchy.organizationalUnits(
                    organizationID: first.id,
                    parentID: nil
                ).first
            )
            #expect(listedRoot.childCount == 1)
            #expect(
                try await hierarchy.deleteOrganizationalUnit(
                    id: root.organizationalUnit.id,
                    organizationID: first.id
                ) == .hasChildren
            )
            #expect(
                try await hierarchy.moveOrganizationalUnit(
                    id: root.organizationalUnit.id,
                    organizationID: first.id,
                    newParentID: child.organizationalUnit.id
                ) == .circularReference
            )

            let moved = try #require(
                try await hierarchy.moveOrganizationalUnit(
                    id: child.organizationalUnit.id,
                    organizationID: first.id,
                    newParentID: nil
                ).moved
            )
            #expect(moved.organizationalUnit.depth == 0)
            #expect(moved.organizationalUnit.path == "/\(first.id)/\(child.organizationalUnit.id)")

            let projectID = UUID()
            try await database.withSession(operation: "test.hierarchy.seed_folder_project") { session in
                try await session.execute(
                    SeedHierarchyFolderProject(
                        id: projectID,
                        organizationalUnitID: moved.organizationalUnit.id,
                        path: "\(moved.organizationalUnit.path)/\(projectID)"
                    ),
                    operation: "test.hierarchy.seed_folder_project.query"
                )
            }
            #expect(
                try await hierarchy.deleteOrganizationalUnit(
                    id: moved.organizationalUnit.id,
                    organizationID: first.id
                ) == .hasProjects
            )

            try await database.withSession(operation: "test.hierarchy.delete_folder_project") { session in
                _ = try await session.execute(
                    DeleteHierarchyProject(id: projectID),
                    operation: "test.hierarchy.delete_folder_project.query"
                )
            }
            #expect(
                try await hierarchy.deleteOrganizationalUnit(
                    id: moved.organizationalUnit.id,
                    organizationID: first.id
                ) == .deleted
            )
            #expect(try await hierarchy.organizationalUnit(id: moved.organizationalUnit.id) == nil)
        }
    }

    @Test("organization membership keeps grants and offboarding atomic")
    func organizationMembership() async throws {
        try await withHierarchyDatabase { database, hierarchy in
            let firstUserID = UUID()
            let secondUserID = UUID()
            try await seedUser(firstUserID, username: "first", database: database)
            try await seedUser(secondUserID, username: "second", database: database)

            let first = try await hierarchy.createOrganization(
                OrganizationWrite(name: "First", description: "First organization")
            )
            let second = try await hierarchy.createOrganization(
                OrganizationWrite(name: "Second", description: "Second organization")
            )
            #expect(try await hierarchy.allOrganizations().map(\.name) == ["First", "Second"])

            do {
                _ = try await hierarchy.createOrganization(
                    OrganizationWrite(name: first.name, description: "duplicate")
                )
                Issue.record("Expected duplicate organization name to fail")
            } catch let error as HierarchyPersistenceError {
                #expect(error == .duplicateOrganizationName(first.name))
            }

            let administratorRoleID = UUID()
            #expect(
                try await hierarchy.addMember(
                    userID: firstUserID,
                    organizationID: first.id,
                    roleID: administratorRoleID,
                    createdBy: firstUserID
                ).isApplied
            )
            #expect(
                try await hierarchy.addMember(
                    userID: secondUserID,
                    organizationID: first.id,
                    roleID: administratorRoleID,
                    createdBy: firstUserID
                ).isApplied
            )
            #expect(
                try await hierarchy.addMember(
                    userID: firstUserID,
                    organizationID: first.id,
                    roleID: administratorRoleID,
                    createdBy: firstUserID
                ) == .alreadyMember
            )

            let membershipOrganizations = try await hierarchy.organizations(forUser: firstUserID)
            #expect(membershipOrganizations.map(\.organization.id) == [first.id])
            #expect(membershipOrganizations.first?.roleID == administratorRoleID)
            #expect(try await hierarchy.members(organizationID: first.id).map(\.username) == ["first", "second"])
            #expect(try await hierarchy.userID(email: "first@example.com") == firstUserID)

            #expect(
                try await hierarchy.updateMemberRole(
                    userID: firstUserID,
                    organizationID: first.id,
                    roleID: nil,
                    administratorRoleID: administratorRoleID,
                    createdBy: secondUserID
                ).isApplied
            )
            #expect(
                try await hierarchy.removeMember(
                    userID: secondUserID,
                    organizationID: first.id,
                    administratorRoleID: administratorRoleID
                ) == .lastAdministrator
            )

            #expect(
                try await hierarchy.updateMemberRole(
                    userID: firstUserID,
                    organizationID: first.id,
                    roleID: administratorRoleID,
                    administratorRoleID: administratorRoleID,
                    createdBy: firstUserID
                ).isApplied
            )

            let projectID = UUID()
            let groupID = UUID()
            try await database.withSession(operation: "test.hierarchy.seed_offboarding") { session in
                _ = try await session.execute(
                    SeedHierarchyProject(id: projectID, organizationID: first.id),
                    operation: "test.hierarchy.seed_project"
                )
                _ = try await session.execute(
                    SeedHierarchyGroup(id: groupID, organizationID: first.id),
                    operation: "test.hierarchy.seed_group"
                )
                _ = try await session.execute(
                    SeedHierarchyGroupMembership(
                        id: UUID(),
                        userID: secondUserID,
                        groupID: groupID
                    ),
                    operation: "test.hierarchy.seed_group_membership"
                )
                _ = try await session.execute(
                    SeedHierarchyBinding(
                        id: UUID(),
                        userID: secondUserID,
                        roleID: UUID(),
                        nodeType: "project",
                        nodeID: projectID
                    ),
                    operation: "test.hierarchy.seed_project_binding"
                )
                _ = try await session.execute(
                    SeedHierarchyBinding(
                        id: UUID(),
                        userID: secondUserID,
                        roleID: UUID(),
                        nodeType: "organization",
                        nodeID: second.id
                    ),
                    operation: "test.hierarchy.seed_external_binding"
                )
            }

            #expect(
                try await hierarchy.removeMember(
                    userID: secondUserID,
                    organizationID: first.id,
                    administratorRoleID: administratorRoleID
                ).isApplied
            )
            #expect(try await hierarchy.membership(userID: secondUserID, organizationID: first.id) == nil)
            #expect(try await countRows(CountHierarchyGroupMemberships(), database: database) == 0)
            #expect(try await countRows(CountHierarchyBindings(nodeID: projectID), database: database) == 0)
            #expect(try await countRows(CountHierarchyBindings(nodeID: second.id), database: database) == 1)

            let renamed = try #require(
                try await hierarchy.updateOrganization(
                    id: first.id,
                    name: "Renamed",
                    description: nil
                )
            )
            #expect(renamed.name == "Renamed")
            #expect(renamed.description == first.description)
            #expect(try await hierarchy.setCurrentOrganization(userID: firstUserID, organizationID: first.id))
        }
    }

    private func withHierarchyDatabase(
        _ test: (ControlPlanePostgres.PostgresDatabase, HierarchyPersistence) async throws -> Void
    ) async throws {
        try await withBareNativePostgresDatabase { database in
            let migrator = try SchemaMigrator(
                database: database,
                migrations: StratoMigrations.current,
                logger: testLogger()
            )
            try await migrator.run(options: migrationOptions())
            try await test(database, ControlPlanePersistence(database: database).hierarchy)
        }
    }

    private func seedUser(
        _ id: UUID,
        username: String,
        database: ControlPlanePostgres.PostgresDatabase
    ) async throws {
        try await database.withSession(operation: "test.hierarchy.seed_user") { session in
            _ = try await session.execute(
                SeedHierarchyUser(
                    id: id,
                    username: username,
                    email: "\(username)@example.com"
                ),
                operation: "test.hierarchy.seed_user.query"
            )
        }
    }

    private func countRows<Statement: PostgresPreparedStatement>(
        _ statement: Statement,
        database: ControlPlanePostgres.PostgresDatabase
    ) async throws -> Int where Statement.Row == Int {
        try await database.withSession(operation: "test.hierarchy.count") { session in
            try #require(
                try await session.execute(statement, operation: "test.hierarchy.count.query").first
            )
        }
    }
}

private extension OrganizationMemberMutationResult {
    var isApplied: Bool {
        if case .applied = self { return true }
        return false
    }
}

private extension OrganizationalUnitCreateResult {
    var created: OrganizationalUnitOverview? {
        if case .created(let overview) = self { return overview }
        return nil
    }
}

private extension OrganizationalUnitMoveResult {
    var moved: OrganizationalUnitOverview? {
        if case .moved(let overview) = self { return overview }
        return nil
    }
}

private struct SeedHierarchyUser: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO users (id, username, email, display_name, created_at, updated_at)
        VALUES ($1, $2, $3, $2, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        """
    typealias Row = Void
    let id: UUID
    let username: String
    let email: String
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(id)
        bindings.append(username)
        bindings.append(email)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws {}
}

private struct SeedHierarchyProject: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO projects (
            id, name, description, organization_id, organizational_unit_id,
            path, default_environment, environments, created_at, updated_at
        )
        VALUES ($1, 'Project', '', $2, NULL, '/' || $2::text || '/' || $1::text,
                'development', ARRAY['development']::text[], CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        """
    typealias Row = Void
    let id: UUID
    let organizationID: UUID
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(organizationID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws {}
}

private struct SeedHierarchyFolderProject: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO projects (
            id, name, description, organization_id, organizational_unit_id,
            path, default_environment, environments, created_at, updated_at
        )
        VALUES ($1, 'Folder Project', '', NULL, $2, $3,
                'development', ARRAY['development']::text[], CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        """
    typealias Row = Void
    let id: UUID
    let organizationalUnitID: UUID
    let path: String
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(id)
        bindings.append(organizationalUnitID)
        bindings.append(path)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws {}
}

private struct DeleteHierarchyProject: PostgresPreparedStatement {
    static let sql = "DELETE FROM projects WHERE id = $1"
    typealias Row = Void
    let id: UUID
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws {}
}

private struct SeedHierarchyGroup: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO groups (id, organization_id, name, description, scim_provisioned, created_at, updated_at)
        VALUES ($1, $2, 'Offboarding', '', false, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        """
    typealias Row = Void
    let id: UUID
    let organizationID: UUID
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(organizationID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws {}
}

private struct SeedHierarchyGroupMembership: PostgresPreparedStatement {
    static let sql = "INSERT INTO user_groups (id, user_id, group_id, created_at) VALUES ($1, $2, $3, CURRENT_TIMESTAMP)"
    typealias Row = Void
    let id: UUID
    let userID: UUID
    let groupID: UUID
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(id)
        bindings.append(userID)
        bindings.append(groupID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws {}
}

private struct SeedHierarchyBinding: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO role_bindings (
            id, principal_type, principal_id, role_id, node_type, node_id,
            condition, expires_at, created_by, created_at
        )
        VALUES ($1, 'user', $2, $3, $4, $5, NULL, NULL, NULL, CURRENT_TIMESTAMP)
        """
    typealias Row = Void
    let id: UUID
    let userID: UUID
    let roleID: UUID
    let nodeType: String
    let nodeID: UUID
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 5)
        bindings.append(id)
        bindings.append(userID)
        bindings.append(roleID)
        bindings.append(nodeType)
        bindings.append(nodeID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws {}
}

private struct CountHierarchyGroupMemberships: PostgresPreparedStatement {
    static let sql = "SELECT count(*)::bigint FROM user_groups"
    typealias Row = Int
    func makeBindings() throws -> PostgresBindings { .init() }
    func decodeRow(_ row: PostgresRow) throws -> Int { try row.decode(Int.self) }
}

private struct CountHierarchyBindings: PostgresPreparedStatement {
    static let sql = "SELECT count(*)::bigint FROM role_bindings WHERE node_id = $1"
    typealias Row = Int
    let nodeID: UUID
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(nodeID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Int { try row.decode(Int.self) }
}
