import Testing
import Vapor
import Fluent
import VaporTesting
import AppTestSupport
@testable import App

@Suite("Hierarchy Integration Tests", .serialized, .postgresFixture)
final class HierarchyIntegrationTests {

    // Helper to run tests with fresh app and test data
    func withHierarchyTestApp(_ test: (Application, TestDataBuilder, User, Organization, String) async throws -> Void)
        async throws
    {
        let app = try await Application.makeForTesting()

        do {
            TestFixtureDiagnostics.shared.configuring(app)
            try await configure(app)

            let builder = TestDataBuilder(db: app.db)

            // Create base test data
            let testUser = try await builder.createUser()
            let testOrganization = try await builder.createOrganization()
            try await builder.addUserToOrganization(user: testUser, organization: testOrganization, role: "admin")
            testUser.currentOrganizationId = testOrganization.id
            try await testUser.save(on: app.db)

            let authToken = try await testUser.generateAPIKey(on: app.db)

            TestFixtureDiagnostics.shared.running(app)
            try await test(app, builder, testUser, testOrganization, authToken)
        } catch {
            TestFixtureDiagnostics.shared.report(error, on: app)
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    // MARK: - Complete Hierarchy Tests

    @Test("Create complete organizational hierarchy")
    func testCreateCompleteHierarchy() async throws {
        try await withHierarchyTestApp { app, builder, testUser, testOrganization, authToken in
            // Create OUs
            let engineering = try await builder.createOU(
                name: "Engineering",
                description: "Engineering department",
                organization: testOrganization
            )

            let backend = try await builder.createOU(
                name: "Backend",
                description: "Backend team",
                organization: testOrganization,
                parentOU: engineering
            )

            let frontend = try await builder.createOU(
                name: "Frontend",
                description: "Frontend team",
                organization: testOrganization,
                parentOU: engineering
            )

            // Create projects
            let apiProject = try await builder.createProject(
                name: "API Service",
                description: "Main API",
                ou: backend
            )

            _ = try await builder.createProject(
                name: "Web App",
                description: "Web application",
                ou: frontend
            )

            // Create groups
            let backendGroup = try await builder.createGroup(
                name: "Backend Developers",
                description: "Backend team members",
                organization: testOrganization
            )

            // Add users to group
            let developer1 = try await builder.createUser(
                username: "dev1",
                email: "dev1@example.com",
                displayName: "Developer 1"
            )
            try await builder.addUserToOrganization(user: developer1, organization: testOrganization)
            try await backendGroup.addMember(developer1.id!, on: app.db)

            // Verify hierarchy
            #expect(backend.$parentOU.id == engineering.id)
            #expect(backend.depth == 1)
            #expect(apiProject.$organizationalUnit.id == backend.id)

            // Test hierarchy navigation
            let engineeringProjects = try await engineering.getAllProjects(on: app.db)
            #expect(engineeringProjects.count == 2)
            #expect(engineeringProjects.contains { $0.name == "API Service" })
            #expect(engineeringProjects.contains { $0.name == "Web App" })
        }
    }

    // MARK: - Search and Filter Tests

    @Test("Search entities across hierarchy")
    func testHierarchySearch() async throws {
        try await withHierarchyTestApp { app, builder, testUser, testOrganization, authToken in
            // Create test data
            let engineering = try await builder.createOU(
                name: "Engineering",
                description: "Main engineering department",
                organization: testOrganization
            )

            let backend = try await builder.createOU(
                name: "Backend Engineering",
                description: "Backend development team",
                organization: testOrganization,
                parentOU: engineering
            )

            _ = try await builder.createProject(
                name: "API Backend Service",
                description: "Core API service",
                ou: backend
            )

            // Test search
            try await app.test(.GET, "/api/hierarchy/search?q=backend") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .ok)

                let response = try res.content.decode(HierarchySearchResponse.self)
                #expect(response.results.count >= 1)
                #expect(response.totalResults >= 1)
                #expect(response.results.contains { $0.name.lowercased().contains("backend") })
                #expect(response.results.contains { $0.name.lowercased().contains("api") })
            }
        }
    }

    /// The organization-scoped search matched projects and VMs through their
    /// folder with a join declared *inside* an `.or` group. Fluent drops such a
    /// join from the emitted SQL but keeps its filter, so the statement named a
    /// table it never joined and every call answered 500. Nothing covered the
    /// route — `/api/hierarchy/search` above takes a different code path.
    @Test("Search within one organization reaches folder-scoped projects and VMs")
    func testOrganizationScopedHierarchySearch() async throws {
        try await withHierarchyTestApp { app, builder, _, testOrganization, authToken in
            let platform = try await builder.createOU(
                name: "Platform", description: "Platform group", organization: testOrganization)
            let folderProject = try await builder.createProject(
                name: "Platform Ingress", description: "Folder-scoped", ou: platform)
            _ = try await builder.createProject(
                name: "Ingress Root", description: "Organization-scoped", organization: testOrganization)
            _ = try await builder.createVM(name: "ingress-vm", project: folderProject)

            try await app.test(.GET, "/api/organizations/\(testOrganization.id!)/search?q=ingress") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .ok, "\(res.status): \(res.body.string)")

                let response = try res.content.decode(HierarchySearchResponse.self)
                let names = Set(response.results.map(\.name))
                #expect(names.contains("Platform Ingress"))
                #expect(names.contains("Ingress Root"))
                #expect(names.contains("ingress-vm"))
            }
        }
    }

    // MARK: - VM Creation with Hierarchy Tests

    // MARK: - Permission Inheritance Tests

    // MARK: - Bulk Operations Tests

    @Test("Test bulk hierarchy operations")
    func testBulkHierarchyOperations() async throws {
        try await withHierarchyTestApp { app, builder, testUser, testOrganization, authToken in
            // Create multiple OUs
            var ous: [OrganizationalUnit] = []
            for i in 1...5 {
                let ou = try await builder.createOU(
                    name: "Department \(i)",
                    description: "Department number \(i)",
                    organization: testOrganization
                )
                ous.append(ou)
            }

            // Create projects in each OU
            var projects: [Project] = []
            for ou in ous {
                let project = try await builder.createProject(
                    name: "\(ou.name) Project",
                    description: "Project for \(ou.name)",
                    ou: ou
                )
                projects.append(project)
            }

            // Test bulk retrieval
            let allProjects = try await testOrganization.getAllProjects(on: app.db)
            #expect(allProjects.count >= 5)

            // Test filtering by OU
            let firstOUProjects = try await ous[0].getAllProjects(on: app.db)
            #expect(firstOUProjects.count >= 1)
            #expect(firstOUProjects.first?.name.contains("Department 1") == true)
        }
    }
}
