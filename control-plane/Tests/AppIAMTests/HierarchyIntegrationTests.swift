import Testing
import Vapor
import VaporTesting
import AppTestSupport
@testable import App

@Suite("Hierarchy Integration Tests", .serialized)
final class HierarchyIntegrationTests {

    // Helper to run tests with fresh app and test data
    func withHierarchyTestApp(_ test: (Application, TestDataBuilder, User, Organization, String) async throws -> Void)
        async throws
    {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)

            let builder = TestDataBuilder(app: app)

            // Create base test data
            let testUser = try await builder.createUser()
            let testOrganization = try await builder.createOrganization()
            try await builder.addUserToOrganization(user: testUser, organization: testOrganization, role: "admin")
            try await testUser.replacingCurrentOrganization(testOrganization.id).save(on: app.testPostgres)

            let authToken = try await testUser.generateAPIKey(on: app)

            try await test(app, builder, testUser, testOrganization, authToken)
        } catch {
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
            try await builder.addUserToGroup(user: developer1, group: backendGroup)

            // Verify hierarchy
            #expect(backend.parentOUID == engineering.id)
            #expect(backend.depth == 1)
            #expect(apiProject.organizationalUnitID == backend.id)

            // Test hierarchy navigation
            let engineeringProjects = try await engineering.getAllProjects(on: app.testPostgres)
            #expect(engineeringProjects.count == 2)
            #expect(engineeringProjects.contains { $0.name == "API Service" })
            #expect(engineeringProjects.contains { $0.name == "Web App" })
        }
    }

    @Test("Test resource quota inheritance")
    func testResourceQuotaInheritance() async throws {
        try await withHierarchyTestApp { app, builder, testUser, testOrganization, authToken in
            // Create hierarchy
            let engineering = try await builder.createOU(
                name: "Engineering",
                description: "Engineering department",
                organization: testOrganization
            )

            let project = try await builder.createProject(
                name: "Test Project",
                description: "Project for quota testing",
                ou: engineering
            )

            // Create quotas at different levels
            _ = try await builder.createResourceQuota(
                name: "Org Quota",
                maxVCPUs: 100,
                maxMemoryGB: 200.0,
                maxStorageGB: 1000.0,
                maxVMs: 50,
                organization: testOrganization
            )

            _ = try await builder.createResourceQuota(
                name: "OU Quota",
                maxVCPUs: 50,
                maxMemoryGB: 100.0,
                maxStorageGB: 500.0,
                maxVMs: 25,
                ou: engineering
            )

            _ = try await builder.createResourceQuota(
                name: "Project Quota",
                maxVCPUs: 20,
                maxMemoryGB: 40.0,
                maxStorageGB: 200.0,
                maxVMs: 10,
                project: project
            )

            // Test that quotas were created
            let savedQuota = try await LegacyResourceQuotaStore.hierarchy(
                organizationID: try testOrganization.requireID(),
                organizationalUnitIDs: [],
                projectIDs: [try project.requireID()],
                on: app.testPostgres).first { $0.projectID == project.id }
            #expect(savedQuota != nil)
            #expect(savedQuota?.maxVCPUs == 20)
        }
    }

    @Test("Test group-based project access")
    func testGroupBasedProjectAccess() async throws {
        try await withHierarchyTestApp { app, builder, testUser, testOrganization, authToken in
            // Create project
            _ = try await builder.createProject(
                name: "Group Access Project",
                description: "Test project for group access",
                organization: testOrganization
            )

            // Create group
            let developerGroup = try await builder.createGroup(
                name: "Developers",
                description: "Developer group",
                organization: testOrganization
            )

            // Create users
            let developer = try await builder.createUser(
                username: "developer",
                email: "developer@example.com",
                displayName: "Developer"
            )
            try await builder.addUserToOrganization(user: developer, organization: testOrganization)

            let nonMember = try await builder.createUser(
                username: "nonmember",
                email: "nonmember@example.com",
                displayName: "Non-member"
            )
            try await builder.addUserToOrganization(user: nonMember, organization: testOrganization)

            // Add developer to group
            try await builder.addUserToGroup(user: developer, group: developerGroup)

            // In a full authorization test against the Cedar evaluator:
            // - Add group to project with member role
            // - Verify developer has access through group membership
            // - Verify non-member doesn't have access

            #expect(
                try await app.groupsPersistence.hasMember(
                    userID: developer.requireID(),
                    groupID: developerGroup.requireID()
                )
            )
            #expect(
                try await !app.groupsPersistence.hasMember(
                    userID: nonMember.requireID(),
                    groupID: developerGroup.requireID()
                )
            )
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

    @Test("Create VM with proper hierarchy context")
    func testCreateVMWithHierarchy() async throws {
        try await withHierarchyTestApp { app, builder, testUser, testOrganization, authToken in
            // Create project
            let project = try await builder.createProject(
                name: "VM Test Project",
                description: "Project for VM testing",
                organization: testOrganization,
                environments: ["dev", "prod"],
                defaultEnvironment: "dev"
            )

            // Create VM request would normally go through VMController
            // This tests the model relationships
            let vm = try await builder.createVM(
                name: "Test VM",
                project: project,
                environment: "dev"
            )

            #expect(vm.projectID == project.id)
            #expect(vm.environment == "dev")

            // Verify the project-owned VM through the explicit foreign key.
            let projectVMs = try await VM.all(on: app.testPostgres).filter { $0.projectID == project.id! }
            #expect(projectVMs.count == 1)
            #expect(projectVMs.first?.name == "Test VM")
        }
    }

    // MARK: - Permission Inheritance Tests

    @Test("Test permission inheritance through hierarchy")
    func testPermissionInheritance() async throws {
        try await withHierarchyTestApp { app, builder, testUser, testOrganization, authToken in
            // Create hierarchy
            let parentOU = try await builder.createOU(
                name: "Parent OU",
                description: "Parent organizational unit",
                organization: testOrganization
            )

            let childOU = try await builder.createOU(
                name: "Child OU",
                description: "Child organizational unit",
                organization: testOrganization,
                parentOU: parentOU
            )

            let project = try await builder.createProject(
                name: "Child Project",
                description: "Project in child OU",
                ou: childOU
            )

            // Under the Cedar evaluator's hierarchy semantics:
            // - User with admin on parentOU should have admin on childOU and project
            // - User with member on organization should have view on all

            // Test path-based hierarchy
            #expect(childOU.path.contains(parentOU.id!.uuidString))
            #expect(project.path.contains(childOU.id!.uuidString))
        }
    }

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
            let allProjects = try await testOrganization.getAllProjects(on: app.testPostgres)
            #expect(allProjects.count >= 5)

            // Test filtering by OU
            let firstOUProjects = try await ous[0].getAllProjects(on: app.testPostgres)
            #expect(firstOUProjects.count >= 1)
            #expect(firstOUProjects.first?.name.contains("Department 1") == true)
        }
    }
}
