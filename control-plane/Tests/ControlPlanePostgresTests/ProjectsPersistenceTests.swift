import Foundation
import PostgresNIO
import Testing

@testable import ControlPlanePostgres

@Suite("Native project persistence", .serialized)
struct ProjectsPersistenceTests {
    private let administratorRoleID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000004")!

    @Test("project creation owns its binding and default security graph")
    func creationGraph() async throws {
        try await withProjectsDatabase { database, persistence in
            let creatorID = UUID()
            try await database.withSession(operation: "test.projects.seed_user") { session in
                try await session.execute(
                    SeedProjectUser(id: creatorID),
                    operation: "test.projects.seed_user.query"
                )
            }
            let organization = try await persistence.hierarchy.createOrganization(
                OrganizationWrite(name: "Project Org", description: "Projects")
            )
            let result = try await persistence.projects.create(.init(
                name: "Compute",
                description: "Compute workloads",
                organizationID: organization.id,
                organizationalUnitID: nil,
                defaultEnvironment: "development",
                environments: ["development", "production"],
                creatorID: creatorID,
                administratorRoleID: administratorRoleID
            ))
            let project = try #require(result.created)
            #expect(project.path == "/\(organization.id)/\(project.id)")
            #expect(project.rootOrganizationID == organization.id)

            let graph = try await database.withSession(operation: "test.projects.graph") { session in
                try #require(
                    try await session.execute(
                        ProjectCreationGraphCounts(projectID: project.id, creatorID: creatorID),
                        operation: "test.projects.graph.query"
                    ).first
                )
            }
            #expect(graph.bindings == 1)
            #expect(graph.defaultGroups == 1)
            #expect(graph.rules == 4)

            let overview = try #require(
                try await persistence.projects.projectOverview(id: project.id))
            #expect(overview.virtualMachineCount == 0)
            let stats = try await persistence.projects.stats(project: project)
            #expect(stats.totalVMs == 0)
            #expect(stats.vmsByEnvironment == ["development": 0, "production": 0])

            let duplicate = try await persistence.projects.create(.init(
                name: project.name,
                description: "Duplicate",
                organizationID: organization.id,
                organizationalUnitID: nil,
                defaultEnvironment: "development",
                environments: ["development"],
                creatorID: nil,
                administratorRoleID: administratorRoleID
            ))
            #expect(duplicate == .duplicateName)
        }
    }

    @Test("environment changes and folder paths stay atomic")
    func environmentsAndFolderPaths() async throws {
        try await withProjectsDatabase { _, persistence in
            let organization = try await persistence.hierarchy.createOrganization(
                OrganizationWrite(name: "Folder Project Org", description: "Projects")
            )
            let folder = try #require(
                try await persistence.hierarchy.createOrganizationalUnit(.init(
                    organizationID: organization.id,
                    parentID: nil,
                    name: "Engineering",
                    description: "Engineering"
                )).created
            )
            let project = try #require(
                try await persistence.projects.create(.init(
                    name: "Runtime",
                    description: "Runtime",
                    organizationID: nil,
                    organizationalUnitID: folder.organizationalUnit.id,
                    defaultEnvironment: "development",
                    environments: ["development"],
                    creatorID: nil,
                    administratorRoleID: administratorRoleID
                )).created
            )
            #expect(project.path == "\(folder.organizationalUnit.path)/\(project.id)")

            let added = try #require(
                try await persistence.projects.addEnvironment(
                    projectID: project.id, environment: "qa").updated
            )
            #expect(added.project.environments == ["development", "qa"])
            #expect(
                try await persistence.projects.removeEnvironment(
                    projectID: project.id, environment: "development") == .cannotRemove
            )
            let removed = try #require(
                try await persistence.projects.removeEnvironment(
                    projectID: project.id, environment: "qa").updated
            )
            #expect(removed.project.environments == ["development"])

            let destination = try await persistence.hierarchy.createOrganization(
                OrganizationWrite(name: "Transfer Destination", description: "Destination")
            )
            let transferred = try #require(
                try await persistence.projects.transfer(.init(
                    project: .init(
                        id: project.id,
                        name: "Runtime Renamed",
                        description: project.description,
                        defaultEnvironment: project.defaultEnvironment,
                        environments: project.environments
                    ),
                    organizationID: destination.id,
                    organizationalUnitID: nil
                )).updated
            )
            #expect(transferred.project.organizationID == destination.id)
            #expect(transferred.project.organizationalUnitID == nil)
            #expect(transferred.project.path == "/\(destination.id)/\(project.id)")
            #expect(transferred.project.name == "Runtime Renamed")

            let chain = try await persistence.hierarchy.organizationalUnitAncestors(
                id: folder.organizationalUnit.id)
            #expect(chain.map(\.id) == [folder.organizationalUnit.id])
        }
    }

    private func withProjectsDatabase(
        _ test: (ControlPlanePostgres.PostgresDatabase, ControlPlanePersistence) async throws -> Void
    ) async throws {
        try await withBareNativePostgresDatabase { database in
            let migrator = try SchemaMigrator(
                database: database,
                migrations: StratoMigrations.current,
                logger: testLogger()
            )
            try await migrator.run(options: migrationOptions())
            try await test(database, ControlPlanePersistence(database: database))
        }
    }
}

private extension ProjectCreateResult {
    var created: ProjectSnapshot? {
        if case .created(let project) = self { return project }
        return nil
    }
}

private extension ProjectEnvironmentMutationResult {
    var updated: ProjectOverview? {
        if case .updated(let overview) = self { return overview }
        return nil
    }
}

private extension ProjectTransferResult {
    var updated: ProjectOverview? {
        if case .updated(let overview) = self { return overview }
        return nil
    }
}

private extension OrganizationalUnitCreateResult {
    var created: OrganizationalUnitOverview? {
        if case .created(let overview) = self { return overview }
        return nil
    }
}

private struct SeedProjectUser: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO users (id, username, email, display_name, created_at, updated_at)
        VALUES ($1, 'project-creator', 'project-creator@example.com', 'Project Creator',
                CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        """
    typealias Row = Void
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws {}
}

private struct ProjectCreationGraphCounts: PostgresPreparedStatement {
    static let sql = """
        SELECT
            (SELECT count(*)::bigint FROM role_bindings
             WHERE principal_type = 'user' AND principal_id = $2
               AND node_type = 'project' AND node_id = $1) AS bindings,
            (SELECT count(*)::bigint FROM security_groups
             WHERE project_id = $1 AND is_default) AS default_groups,
            (SELECT count(*)::bigint FROM security_group_rules AS rule
             JOIN security_groups AS security_group ON security_group.id = rule.security_group_id
             WHERE security_group.project_id = $1 AND security_group.is_default) AS rules
        """
    struct Row: Sendable {
        let bindings: Int
        let defaultGroups: Int
        let rules: Int
    }
    let projectID: UUID
    let creatorID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(projectID)
        bindings.append(creatorID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Row {
        let value = try row.decode((Int, Int, Int).self)
        return Row(bindings: value.0, defaultGroups: value.1, rules: value.2)
    }
}
