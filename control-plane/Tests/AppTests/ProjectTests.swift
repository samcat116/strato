import Testing
import Vapor
import Fluent
import VaporTesting
import NIOHTTP1
@testable import App

@Suite("Project API Tests", .serialized)
final class ProjectTests {

    func withProjectTestApp(_ test: (Application, User, Organization, OrganizationalUnit, String) async throws -> Void) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            // Create test user and organization
            let testUser = User(
                username: "testuser",
                email: "test@example.com",
                displayName: "Test User",
                isSystemAdmin: false
            )
            try await testUser.save(on: app.db)

            let testOrganization = Organization(
                name: "Test Organization",
                description: "Test organization for unit tests"
            )
            try await testOrganization.save(on: app.db)

            // Create test OU
            let testOU = OrganizationalUnit(
                name: "Test OU",
                description: "Test organizational unit",
                organizationID: testOrganization.id!,
                path: "",
                depth: 0
            )
            try await testOU.save(on: app.db)
            testOU.path = try await testOU.buildPath(on: app.db)
            try await testOU.save(on: app.db)

            // Add user to organization as admin
            let userOrg = UserOrganization(
                userID: testUser.id!,
                organizationID: testOrganization.id!,
                role: "admin"
            )
            try await userOrg.save(on: app.db)

            let authToken = try await testUser.generateAPIKey(on: app.db)

            try await test(app, testUser, testOrganization, testOU, authToken)
            try await app.autoRevert()
        } catch {
            try? await app.autoRevert()
            try await app.asyncShutdown()
            try? await Task.sleep(for: .milliseconds(100))
            app.cleanupTestDatabase()
            throw error
        }

        try await app.asyncShutdown()
        try? await Task.sleep(for: .milliseconds(100))
        app.cleanupTestDatabase()
    }

    @Test("Create project in organization")
    func testCreateProjectInOrganization() async throws {
        try await withProjectTestApp { app, _, testOrganization, _, authToken in
            try await app.test(.POST, "/organizations/\(testOrganization.id!)/projects") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(CreateProjectRequest(
                    name: "Web Application",
                    description: "Main web application project",
                    organizationalUnitId: nil,
                    defaultEnvironment: "development",
                    environments: ["development", "staging", "production"]
                ))
            } afterResponse: { res in
                #expect(res.status == .ok)

                let response = try res.content.decode(ProjectResponse.self)
                #expect(response.name == "Web Application")
                #expect(response.organizationId == testOrganization.id)
                #expect(response.organizationalUnitId == nil)
                #expect(response.environments.count == 3)
                #expect(response.defaultEnvironment == "development")
            }
        }
    }

    @Test("Create project in OU")
    func testCreateProjectInOU() async throws {
        try await withProjectTestApp { app, _, testOrganization, testOU, authToken in
            try await app.test(.POST, "/organizations/\(testOrganization.id!)/ous/\(testOU.id!)/projects") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(CreateProjectRequest(
                    name: "Backend API",
                    description: "Backend API project",
                    organizationalUnitId: nil,
                    defaultEnvironment: "dev",
                    environments: ["dev", "prod"]
                ))
            } afterResponse: { res in
                #expect(res.status == .ok)

                let response = try res.content.decode(ProjectResponse.self)
                #expect(response.name == "Backend API")
                #expect(response.organizationId == nil)
                #expect(response.organizationalUnitId == testOU.id)
                #expect(response.environments.count == 2)
            }
        }
    }

    @Test("Create project with invalid parent fails")
    func testCreateProjectWithInvalidParent() async throws {
        try await withProjectTestApp { app, _, testOrganization, testOU, authToken in
            try await app.test(.POST, "/organizations/\(testOrganization.id!)/projects") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(CreateProjectRequest(
                    name: "Invalid Project",
                    description: "Should fail - organizationalUnitId specified for organization endpoint",
                    organizationalUnitId: testOU.id,
                    defaultEnvironment: nil,
                    environments: nil
                ))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    // MARK: - Environment Management Tests

    @Test("Add environment to project")
    func testAddEnvironment() async throws {
        try await withProjectTestApp { app, _, testOrganization, _, authToken in
            let project = Project(
                name: "Environment Test",
                description: "Test project",
                organizationID: testOrganization.id,
                path: ""
            )
            try await project.save(on: app.db)
            project.path = try await project.buildPath(on: app.db)
            try await project.save(on: app.db)

            try await app.test(.POST, "/projects/\(project.id!)/environments") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(ProjectEnvironmentRequest(
                    environment: "qa"
                ))
            } afterResponse: { res in
                #expect(res.status == .ok)

                let response = try res.content.decode(ProjectResponse.self)
                #expect(response.environments.contains("qa"))
            }
        }
    }

    @Test("Remove environment from project")
    func testRemoveEnvironment() async throws {
        try await withProjectTestApp { app, _, testOrganization, _, authToken in
            let project = Project(
                name: "Environment Test",
                description: "Test project",
                organizationID: testOrganization.id,
                organizationalUnitID: nil,
                path: "",
                defaultEnvironment: "dev",
                environments: ["dev", "staging", "prod"]
            )
            try await project.save(on: app.db)
            project.path = try await project.buildPath(on: app.db)
            try await project.save(on: app.db)

            try await app.test(.DELETE, "/projects/\(project.id!)/environments/staging") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .ok)

                let response = try res.content.decode(ProjectResponse.self)
                #expect(!response.environments.contains("staging"))
                #expect(response.environments.count == 2)
            }
        }
    }

    @Test("Cannot remove default environment")
    func testCannotRemoveDefaultEnvironment() async throws {
        try await withProjectTestApp { app, _, testOrganization, _, authToken in
            let project = Project(
                name: "Environment Test",
                description: "Test project",
                organizationID: testOrganization.id,
                organizationalUnitID: nil,
                path: "",
                defaultEnvironment: "dev",
                environments: ["dev", "prod"]
            )
            try await project.save(on: app.db)

            try await app.test(.DELETE, "/projects/\(project.id!)/environments/dev") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    // MARK: - List Projects Tests

    @Test("List all projects in organization hierarchy")
    func testListProjects() async throws {
        try await withProjectTestApp { app, _, testOrganization, testOU, authToken in
            // Create projects at different levels
            let orgProject = Project(
                name: "Org Project",
                description: "Organization level project",
                organizationID: testOrganization.id,
                path: ""
            )
            try await orgProject.save(on: app.db)

            let ouProject = Project(
                name: "OU Project",
                description: "OU level project",
                organizationalUnitID: testOU.id,
                path: ""
            )
            try await ouProject.save(on: app.db)

            try await app.test(.GET, "/projects") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .ok)

                let projects = try res.content.decode([ProjectResponse].self)
                #expect(projects.count >= 2)
                #expect(projects.contains { $0.name == "Org Project" })
                #expect(projects.contains { $0.name == "OU Project" })
            }
        }
    }

    // MARK: - Transfer Project Tests

    @Test("Transfer project between OUs")
    func testTransferProject() async throws {
        try await withProjectTestApp { app, _, testOrganization, testOU, authToken in
            // Create another OU
            let targetOU = OrganizationalUnit(
                name: "Target OU",
                description: "Target organizational unit",
                organizationID: testOrganization.id!,
                path: "",
                depth: 0
            )
            try await targetOU.save(on: app.db)

            let project = Project(
                name: "Transfer Test",
                description: "Project to transfer",
                organizationalUnitID: testOU.id,
                path: ""
            )
            try await project.save(on: app.db)

            try await app.test(.POST, "/projects/\(project.id!)/transfer") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(TransferProjectRequest(
                    organizationId: nil,
                    organizationalUnitId: targetOU.id
                ))
            } afterResponse: { res in
                #expect(res.status == .ok)

                let response = try res.content.decode(ProjectResponse.self)
                #expect(response.organizationalUnitId == targetOU.id)
            }
        }
    }

    // MARK: - Update Project Tests

    @Test("Update project details")
    func testUpdateProject() async throws {
        try await withProjectTestApp { app, _, testOrganization, _, authToken in
            let project = Project(
                name: "Original Name",
                description: "Original description",
                organizationID: testOrganization.id,
                path: ""
            )
            try await project.save(on: app.db)

            try await app.test(.PUT, "/projects/\(project.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(UpdateProjectRequest(
                    name: "Updated Name",
                    description: "Updated description",
                    defaultEnvironment: "production",
                    environments: nil
                ))
            } afterResponse: { res in
                #expect(res.status == .ok)

                let response = try res.content.decode(ProjectResponse.self)
                #expect(response.name == "Updated Name")
                #expect(response.description == "Updated description")
                #expect(response.defaultEnvironment == "production")
            }
        }
    }

    // MARK: - Delete Project Tests

    @Test("Delete empty project")
    func testDeleteEmptyProject() async throws {
        try await withProjectTestApp { app, _, testOrganization, _, authToken in
            let project = Project(
                name: "Delete Test",
                description: "Project to be deleted",
                organizationID: testOrganization.id,
                path: ""
            )
            try await project.save(on: app.db)

            try await app.test(.DELETE, "/projects/\(project.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let deletedProject = try await Project.find(project.id, on: app.db)
            #expect(deletedProject == nil)
        }
    }

    @Test("Delete project with VMs fails")
    func testDeleteProjectWithVMs() async throws {
        try await withProjectTestApp { app, _, testOrganization, _, authToken in
            let project = Project(
                name: "Project with VMs",
                description: "Has VMs",
                organizationID: testOrganization.id,
                path: ""
            )
            try await project.save(on: app.db)

            // Create a VM in the project
            let vm = VM(
                name: "Test VM",
                description: "Test VM",
                image: "test-image",
                projectID: project.id!,
                environment: "development",
                cpu: 2,
                memory: 2 * 1024 * 1024 * 1024,
                disk: 10 * 1024 * 1024 * 1024
            )
            try await vm.save(on: app.db)

            try await app.test(.DELETE, "/projects/\(project.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == HTTPResponseStatus.conflict)
            }
        }
    }
}
