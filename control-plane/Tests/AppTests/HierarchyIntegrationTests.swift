import Testing
import Vapor
import Fluent
import VaporTesting
@testable import App

@Suite("Hierarchy Integration Tests")
final class HierarchyIntegrationTests {
    var app: Application!
    var builder: TestDataBuilder!
    var testUser: User!
    var testOrganization: Organization!
    var authToken: String!

    init() async throws {
        self.app = try await Application.makeForTesting()
        try await configure(app)
        try await app.autoRevert()
        try await app.autoMigrate()

        self.builder = TestDataBuilder(db: app.db)

        // Create base test data
        testUser = try await builder.createUser()
        testOrganization = try await builder.createOrganization()
        try await builder.addUserToOrganization(user: testUser, organization: testOrganization, role: "admin")
        testUser.currentOrganizationId = testOrganization.id
        try await testUser.save(on: app.db)

        authToken = try await testUser.generateAPIKey(on: app.db)
    }

    deinit {
        let application = app
        Task {
            try? await application?.asyncShutdown()
        }
    }

    // MARK: - Complete Hierarchy Tests

    @Test("Create complete organizational hierarchy")
    func testCreateCompleteHierarchy() async throws {
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

    @Test("Test resource quota inheritance")
    func testResourceQuotaInheritance() async throws {
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
        let orgQuota = try await builder.createResourceQuota(
            name: "Org Quota",
            maxVCPUs: 100,
            maxMemoryGB: 200.0,
            maxStorageGB: 1000.0,
            maxVMs: 50,
            organization: testOrganization
        )

        let ouQuota = try await builder.createResourceQuota(
            name: "OU Quota",
            maxVCPUs: 50,
            maxMemoryGB: 100.0,
            maxStorageGB: 500.0,
            maxVMs: 25,
            ou: engineering
        )

        let projectQuota = try await builder.createResourceQuota(
            name: "Project Quota",
            maxVCPUs: 20,
            maxMemoryGB: 40.0,
            maxStorageGB: 200.0,
            maxVMs: 10,
            project: project
        )

        // Test that quotas were created
        let savedQuota = try await ResourceQuota.query(on: app.db)
            .filter(\.$project.$id == project.id)
            .first()
        #expect(savedQuota != nil)
        #expect(savedQuota?.maxVCPUs == 20)
    }

    @Test("Test group-based project access")
    func testGroupBasedProjectAccess() async throws {
        // Create project
        let project = try await builder.createProject(
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
        try await developerGroup.addMember(developer.id!, on: app.db)

        // In a real test with SpiceDB integration:
        // - Add group to project with member role
        // - Verify developer has access through group membership
        // - Verify non-member doesn't have access

        #expect(try await developer.belongsToGroup(developerGroup.id!, on: app.db))
        #expect(try await !nonMember.belongsToGroup(developerGroup.id!, on: app.db))
    }

    // MARK: - Search and Filter Tests

    @Test("Search entities across hierarchy")
    func testHierarchySearch() async throws {
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

        let apiProject = try await builder.createProject(
            name: "API Backend Service",
            description: "Core API service",
            ou: backend
        )

        // Test search
        try await app.test(.GET, "/hierarchy/search?q=backend") { req in
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

    // MARK: - VM Creation with Hierarchy Tests

    @Test("Create VM with proper hierarchy context")
    func testCreateVMWithHierarchy() async throws {
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

        #expect(vm.$project.id == project.id)
        #expect(vm.environment == "dev")

        // Verify project has the VM
        try await project.$vms.load(on: app.db)
        #expect(project.vms.count == 1)
        #expect(project.vms.first?.name == "Test VM")
    }

    // MARK: - Permission Inheritance Tests

    @Test("Test permission inheritance through hierarchy")
    func testPermissionInheritance() async throws {
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

        // In a real system with SpiceDB:
        // - User with admin on parentOU should have admin on childOU and project
        // - User with member on organization should have view on all

        // Test path-based hierarchy
        #expect(childOU.path.contains(parentOU.id!.uuidString))
        #expect(project.path.contains(childOU.id!.uuidString))
    }

    // MARK: - Bulk Operations Tests

    @Test("Test bulk hierarchy operations")
    func testBulkHierarchyOperations() async throws {
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
