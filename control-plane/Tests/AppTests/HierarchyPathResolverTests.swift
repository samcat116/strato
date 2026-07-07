import Testing
import Vapor
import Fluent
import VaporTesting
@testable import App

@Suite("HierarchyPathResolver Tests", .serialized)
final class HierarchyPathResolverTests {

    func withApp(_ test: (Application, TestDataBuilder) async throws -> Void) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()
            try await test(app, TestDataBuilder(db: app.db))
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test("path for a project under a nested OU walks org -> OU chain -> project")
    func testProjectPathViaNestedOU() async throws {
        try await withApp { app, builder in
            let org = try await builder.createOrganization(name: "Acme")
            let eng = try await builder.createOU(name: "Engineering", description: "d", organization: org)
            let backend = try await builder.createOU(
                name: "Backend", description: "d", organization: org, parentOU: eng)
            let project = try await builder.createProject(name: "API", description: "d", ou: backend)

            let path = try await HierarchyPathResolver.buildEntityPath(
                entityType: "project",
                entityID: project.id!,
                organizationID: org.id!,
                on: app.db
            )

            #expect(path.map { $0.type } == ["organization", "organizational_unit", "organizational_unit", "project"])
            #expect(path.map { $0.name } == ["Acme", "Engineering", "Backend", "API"])
        }
    }

    @Test("path for a VM appends org -> OU -> project -> vm")
    func testVMPath() async throws {
        try await withApp { app, builder in
            let org = try await builder.createOrganization(name: "Acme")
            let eng = try await builder.createOU(name: "Engineering", description: "d", organization: org)
            let project = try await builder.createProject(name: "API", description: "d", ou: eng)
            let vm = try await builder.createVM(name: "web-1", project: project)

            let path = try await HierarchyPathResolver.buildEntityPath(
                entityType: "vm",
                entityID: vm.id!,
                organizationID: org.id!,
                on: app.db
            )

            #expect(path.map { $0.type } == ["organization", "organizational_unit", "project", "vm"])
            #expect(path.last?.name == "web-1")
        }
    }

    @Test("path for a project directly under the organization is org -> project")
    func testProjectPathDirectOrg() async throws {
        try await withApp { app, builder in
            let org = try await builder.createOrganization(name: "Acme")
            let project = try await builder.createProject(name: "Standalone", description: "d", organization: org)

            let path = try await HierarchyPathResolver.buildEntityPath(
                entityType: "project",
                entityID: project.id!,
                organizationID: org.id!,
                on: app.db
            )

            #expect(path.map { $0.type } == ["organization", "project"])
            #expect(path.map { $0.name } == ["Acme", "Standalone"])
        }
    }

    @Test("unknown entity type yields only the organization root")
    func testUnknownEntityType() async throws {
        try await withApp { app, builder in
            let org = try await builder.createOrganization(name: "Acme")

            let path = try await HierarchyPathResolver.buildEntityPath(
                entityType: "widget",
                entityID: UUID(),
                organizationID: org.id!,
                on: app.db
            )

            #expect(path.map { $0.type } == ["organization"])
            #expect(path.first?.name == "Acme")
        }
    }
}
