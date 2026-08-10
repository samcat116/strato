import Testing
import Vapor
import Fluent
import VaporTesting
import NIOHTTP1
import AppTestSupport
@testable import App

@Suite("Project API Tests", .serialized)
final class ProjectTests {

    func withProjectTestApp(_ test: (Application, User, Organization, OrganizationalUnit, String) async throws -> Void)
        async throws
    {
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
                roleID: IAMRole.admin.seededID
            )
            try await userOrg.save(on: app.db)

            // The admin role binding the API/backfill would have written
            // alongside the membership row — the Cedar evaluator (#482)
            // answers from `role_bindings`.
            try await RoleBindingService.grant(
                principalType: .user, principalID: testUser.id!, role: .admin,
                nodeType: .organization, nodeID: testOrganization.id!, createdBy: nil, on: app.db)

            let authToken = try await testUser.generateAPIKey(on: app.db)

            try await test(app, testUser, testOrganization, testOU, authToken)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    @Test("Create project in organization")
    func testCreateProjectInOrganization() async throws {
        try await withProjectTestApp { app, _, testOrganization, _, authToken in
            try await app.test(.POST, "/api/organizations/\(testOrganization.id!)/projects") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    CreateProjectRequest(
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
            try await app.test(.POST, "/api/organizations/\(testOrganization.id!)/ous/\(testOU.id!)/projects") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    CreateProjectRequest(
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

    @Test("Create project in organization persists org parentage and grants the creator admin")
    func testCreateProjectPersistsOrganizationParentage() async throws {
        try await withProjectTestApp { app, testUser, testOrganization, _, authToken in
            var createdProjectId: UUID?
            try await app.test(.POST, "/api/organizations/\(testOrganization.id!)/projects") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    CreateProjectRequest(
                        name: "Perms Project",
                        description: "Project that should get an org tuple",
                        organizationalUnitId: nil,
                        defaultEnvironment: "development",
                        environments: ["development"]
                    ))
            } afterResponse: { res in
                #expect(res.status == .ok)
                createdProjectId = try res.content.decode(ProjectResponse.self).id
            }

            // Parentage must reference the *persisted* project id (issue #267):
            // a mismatch here means project-scoped permissions can't resolve
            // via the org hierarchy and the creating admin gets 403s.
            let projectId = try #require(createdProjectId)
            let savedProject = try await Project.find(projectId, on: app.db)
            let saved = try #require(savedProject)
            #expect(saved.$organization.id == testOrganization.id)
            #expect(saved.path == "/\(testOrganization.id!.uuidString)/\(projectId.uuidString)")

            // The creator gets an explicit admin binding on the new project.
            let bindingCount = try await RoleBinding.query(on: app.db)
                .filter(\.$principalType == IAMPrincipalType.user.rawValue)
                .filter(\.$principalID == testUser.id!)
                .filter(\.$roleID == IAMRole.admin.seededID)
                .filter(\.$nodeType == IAMNodeType.project.rawValue)
                .filter(\.$nodeID == projectId)
                .count()
            #expect(bindingCount == 1)
        }
    }

    @Test("Create project in OU persists the OU as the immediate parent")
    func testCreateProjectInOUPersistsOUParentage() async throws {
        try await withProjectTestApp { app, _, testOrganization, testOU, authToken in
            var createdProjectId: UUID?
            try await app.test(.POST, "/api/organizations/\(testOrganization.id!)/ous/\(testOU.id!)/projects") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    CreateProjectRequest(
                        name: "OU Perms Project",
                        description: "OU project that should get an OU parent tuple",
                        organizationalUnitId: nil,
                        defaultEnvironment: "development",
                        environments: ["development"]
                    ))
            } afterResponse: { res in
                #expect(res.status == .ok)
                createdProjectId = try res.content.decode(ProjectResponse.self).id
            }

            let projectId = try #require(createdProjectId)
            let savedProject = try await Project.find(projectId, on: app.db)
            let saved = try #require(savedProject)
            // The parent must be the *immediate* parent — the OU, not the root
            // organization — so OU-scoped projects inherit up the OU chain (and
            // OU admins, not just org admins, can manage them). The Cedar
            // hierarchy is built from these columns and the materialized path.
            #expect(saved.$organizationalUnit.id == testOU.id)
            #expect(saved.$organization.id == nil)
            #expect(saved.path == "\(testOU.path)/\(projectId.uuidString)")
        }
    }

    @Test("Create project with invalid parent fails")
    func testCreateProjectWithInvalidParent() async throws {
        try await withProjectTestApp { app, _, testOrganization, testOU, authToken in
            try await app.test(.POST, "/api/organizations/\(testOrganization.id!)/projects") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    CreateProjectRequest(
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

            try await app.test(.POST, "/api/projects/\(project.id!)/environments") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    ProjectEnvironmentRequest(
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

            try await app.test(.DELETE, "/api/projects/\(project.id!)/environments/staging") { req in
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

            try await app.test(.DELETE, "/api/projects/\(project.id!)/environments/dev") { req in
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

            try await app.test(.GET, "/api/projects") { req in
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

    @Test("List organization projects includes OU-scoped projects")
    func testListOrganizationProjectsIncludesOUProjects() async throws {
        try await withProjectTestApp { app, _, testOrganization, testOU, authToken in
            // A project directly on the organization...
            let orgProject = Project(
                name: "Org Project",
                description: "Organization level project",
                organizationID: testOrganization.id,
                path: ""
            )
            try await orgProject.save(on: app.db)

            // ...and one nested under an OU within the same organization.
            let ouProject = Project(
                name: "OU Project",
                description: "OU level project",
                organizationalUnitID: testOU.id,
                path: ""
            )
            try await ouProject.save(on: app.db)

            try await app.test(.GET, "/api/organizations/\(testOrganization.id!)/projects") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .ok)

                let projects = try res.content.decode([ProjectResponse].self)
                // The org-scoped endpoint must surface OU projects too so the
                // project switcher can reach them.
                #expect(projects.contains { $0.name == "Org Project" })
                #expect(projects.contains { $0.name == "OU Project" })
            }
        }
    }

    @Test("Project list returns only projects the caller may read, not the org inventory")
    func testListProjectsFiltersPerRow() async throws {
        try await withProjectTestApp { app, _, testOrganization, testOU, _ in
            // Two projects directly in the org.
            let visibleProject = Project(
                name: "Visible Project", description: "member has a binding here",
                organizationID: testOrganization.id, path: "")
            try await visibleProject.save(on: app.db)
            let hiddenProject = Project(
                name: "Hidden Project", description: "member has no binding here",
                organizationID: testOrganization.id, path: "")
            try await hiddenProject.save(on: app.db)

            // A folder project the member also has no binding on — covers the
            // folder-scoped list endpoint (`listFolderProjects`).
            let hiddenFolderProject = Project(
                name: "Hidden Folder Project", description: "member has no binding here",
                organizationalUnitID: testOU.id, path: "")
            try await hiddenFolderProject.save(on: app.db)

            // A bare org member: a membership row and nothing else —
            // under the redesign that grants `org:read` + `project:create`, no
            // project visibility (docs/architecture/iam.md).
            let member = User(
                username: "bare-member", email: "member@example.com",
                displayName: "Bare Member", isSystemAdmin: false)
            try await member.save(on: app.db)
            try await UserOrganization(
                userID: member.id!, organizationID: testOrganization.id!, roleID: nil
            ).save(on: app.db)
            // One explicit project binding — the only project they may read.
            try await RoleBindingService.grant(
                principalType: .user, principalID: member.id!, role: .viewer,
                nodeType: .project, nodeID: visibleProject.id!, createdBy: nil, on: app.db)
            let memberToken = try await member.generateAPIKey(on: app.db)

            // Before STR-113 this handed back every project in the org; now the
            // evaluator decides per row, so the unbound project never appears.
            try await app.test(.GET, "/api/projects") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: memberToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let projects = try res.content.decode([ProjectResponse].self)
                #expect(projects.contains { $0.name == "Visible Project" })
                #expect(!projects.contains { $0.name == "Hidden Project" })
            }

            // Same story on the org-scoped list.
            try await app.test(.GET, "/api/organizations/\(testOrganization.id!)/projects") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: memberToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let projects = try res.content.decode([ProjectResponse].self)
                #expect(projects.contains { $0.name == "Visible Project" })
                #expect(!projects.contains { $0.name == "Hidden Project" })
            }

            // ...and on the folder-scoped list: the member has no binding in
            // the folder, so it comes back empty rather than leaking the
            // folder's projects.
            try await app.test(
                .GET, "/api/organizations/\(testOrganization.id!)/ous/\(testOU.id!)/projects"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: memberToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let projects = try res.content.decode([ProjectResponse].self)
                #expect(!projects.contains { $0.name == "Hidden Folder Project" })
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

            try await app.test(.POST, "/api/projects/\(project.id!)/transfer") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    TransferProjectRequest(
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

    @Test("Transfer to another organization reparents the project")
    func testTransferAcrossOrganizationsReparents() async throws {
        try await withProjectTestApp { app, testUser, testOrganization, _, authToken in
            // A second organization the user also administers.
            let destinationOrg = Organization(name: "Destination Org", description: "Transfer target")
            try await destinationOrg.save(on: app.db)
            try await UserOrganization(
                userID: testUser.id!,
                organizationID: destinationOrg.id!,
                roleID: IAMRole.admin.seededID
            ).save(on: app.db)
            try await RoleBindingService.grant(
                principalType: .user, principalID: testUser.id!, role: .admin,
                nodeType: .organization, nodeID: destinationOrg.id!, createdBy: nil, on: app.db)

            let project = Project(
                name: "Cross Org Project",
                description: "Project to move between orgs",
                organizationID: testOrganization.id,
                path: ""
            )
            try await project.save(on: app.db)

            try await app.test(.POST, "/api/projects/\(project.id!)/transfer") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    TransferProjectRequest(
                        organizationId: destinationOrg.id,
                        organizationalUnitId: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let response = try res.content.decode(ProjectResponse.self)
                #expect(response.organizationId == destinationOrg.id)
            }

            // The persisted parentage must now point at the destination org,
            // otherwise destination admins can't resolve project-scoped
            // permissions through the hierarchy the Cedar evaluator builds.
            let movedProject = try await Project.find(project.id!, on: app.db)
            let moved = try #require(movedProject)
            #expect(moved.$organization.id == destinationOrg.id)
            #expect(moved.path == "/\(destinationOrg.id!.uuidString)/\(project.id!.uuidString)")
        }
    }

    @Test("Transfer to an org where the user is only a member is forbidden")
    func testTransferToNonAdminOrganizationForbidden() async throws {
        try await withProjectTestApp { app, testUser, testOrganization, _, authToken in
            let destinationOrg = Organization(name: "Member Only Org", description: "User is only a member")
            try await destinationOrg.save(on: app.db)
            try await UserOrganization(
                userID: testUser.id!,
                organizationID: destinationOrg.id!,
                roleID: nil
            ).save(on: app.db)

            // The user holds no admin binding on the destination org (only a
            // bare membership row), so the destination-org admin check fails;
            // the project-scoped check on the source still passes.

            let project = Project(
                name: "Guarded Project",
                description: "Should not move to a non-admin org",
                organizationID: testOrganization.id,
                path: ""
            )
            try await project.save(on: app.db)

            try await app.test(.POST, "/api/projects/\(project.id!)/transfer") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    TransferProjectRequest(
                        organizationId: destinationOrg.id,
                        organizationalUnitId: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
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

            try await app.test(.PUT, "/api/projects/\(project.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    UpdateProjectRequest(
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

            try await app.test(.DELETE, "/api/projects/\(project.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let deletedProject = try await Project.find(project.id, on: app.db)
            #expect(deletedProject == nil)
        }
    }

    @Test("Deleting a project refreshes ancestor quotas after its networks cascade")
    func testDeleteProjectRefreshesAncestorNetworkQuotas() async throws {
        try await withProjectTestApp { app, _, testOrganization, testOU, authToken in
            let builder = TestDataBuilder(db: app.db)
            let project = try await builder.createProject(
                name: "Delete Network Project",
                description: "Its networks cascade with it",
                ou: testOU)
            let network = try await builder.createNetwork(
                name: "cascaded-network", project: project)
            let organizationQuota = try await builder.createResourceQuota(
                name: "organization-network-count", organization: testOrganization)
            let ouQuota = try await builder.createResourceQuota(
                name: "ou-network-count", ou: testOU)
            let projectQuota = try await builder.createResourceQuota(
                name: "project-network-count", project: project)

            for quota in [organizationQuota, ouQuota, projectQuota] {
                try await QuotaEnforcementService.resyncReservations(quota, on: app.db)
                try await quota.save(on: app.db)
                #expect(quota.networkCount == 1)
            }

            try await app.test(.DELETE, "/api/projects/\(try project.requireID())") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            #expect(try await LogicalNetwork.find(network.id, on: app.db) == nil)
            #expect(try await ResourceQuota.find(projectQuota.id, on: app.db) == nil)
            let refreshedOrganizationQuota = try #require(
                try await ResourceQuota.find(organizationQuota.id, on: app.db))
            let refreshedOUQuota = try #require(
                try await ResourceQuota.find(ouQuota.id, on: app.db))
            #expect(refreshedOrganizationQuota.networkCount == 0)
            #expect(refreshedOUQuota.networkCount == 0)
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

            try await app.test(.DELETE, "/api/projects/\(project.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == HTTPResponseStatus.conflict)
            }
        }
    }

    @Test("The database refuses to cascade a project delete over a live VM (STR-98)")
    func testProjectDeleteCannotCascadeOverVMs() async throws {
        try await withProjectTestApp { app, _, testOrganization, _, _ in
            let project = Project(
                name: "Racing Project",
                description: "A VM appears between the check and the delete",
                organizationID: testOrganization.id,
                path: ""
            )
            try await project.save(on: app.db)

            // `deleteProject` counts VMs and refuses when any exist, but the
            // count and the delete are not one atomic step and read-committed
            // Postgres will happily commit a VM created in between. This is
            // that VM: the endpoint's guard has already passed, and the delete
            // is about to run. It used to CASCADE — hard-deleting a running
            // VM's row with no `.absent`, no operation, and no audit — and the
            // agent then learned of it only as an absence from the next sync,
            // which meant "destroy". The FK is RESTRICT now, so the delete
            // fails instead and the VM survives.
            let vm = VM(
                name: "Raced VM",
                description: "Created inside the delete window",
                image: "test-image",
                projectID: project.id!,
                environment: "development",
                cpu: 2,
                memory: 2 * 1024 * 1024 * 1024,
                disk: 10 * 1024 * 1024 * 1024
            )
            try await vm.save(on: app.db)

            await #expect(throws: (any Error).self) {
                try await project.delete(on: app.db)
            }

            #expect(try await VM.find(vm.id, on: app.db) != nil)
            #expect(try await Project.find(project.id, on: app.db) != nil)
        }
    }

    @Test("Deleting an organization can't cascade its projects' VMs away either (STR-98)")
    func testOrganizationDeleteCannotCascadeOverVMs() async throws {
        try await withProjectTestApp { app, user, _, _, authToken in
            // A fresh org, since the fixture org is the caller's current one.
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Doomed Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            let project = try await builder.createProject(
                name: "Doomed Project", description: "Has a VM", organization: org)
            let vm = try await builder.createVM(name: "survivor-vm", project: project)
            // Pointed at the doomed org, so the refusal can be checked to have
            // happened *before* the delete path clears this.
            user.currentOrganizationId = try org.requireID()
            try await user.save(on: app.db)

            // `projects.organization_id` cascades, so before STR-98 this
            // deleted the VM row outright — one level further up the same
            // silent-destruction path the project endpoint guards.
            try await app.test(.DELETE, "/api/organizations/\(try org.requireID())") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == HTTPResponseStatus.conflict)
                // The refusal names what is blocking it: an operator hunting
                // for the workload across a whole org's projects is the
                // difference between a usable error and a constraint dump.
                #expect(res.body.string.contains("Doomed Project"))
            }

            #expect(try await VM.find(vm.id, on: app.db) != nil)
            #expect(try await Organization.find(org.id, on: app.db) != nil)
            // The pre-check runs before the user updates, which are not in the
            // delete's transaction and would otherwise persist through it.
            let refreshed = try await User.find(user.id, on: app.db)
            #expect(refreshed?.currentOrganizationId != nil)
        }
    }

    // MARK: - Generated-handler wire compatibility (#583)

    /// The projects surface is served by handlers generated from `openapi.yaml`
    /// rather than a hand-written controller. These two tests pin the parts of
    /// the wire format that the migration could plausibly have changed:
    /// serialization of dates, and the error envelope.

    @Test("Generated handlers encode timestamps as ISO-8601, like the rest of the API")
    func testProjectTimestampEncoding() async throws {
        try await withProjectTestApp { app, _, testOrganization, _, authToken in
            let project = Project(
                name: "Timestamp Project",
                description: "Checks date encoding",
                organizationID: testOrganization.id,
                path: ""
            )
            try await project.save(on: app.db)

            try await app.test(.GET, "/api/projects/\(project.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = res.body.string
                let json = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
                let createdAt = json?["createdAt"] as? String
                #expect(createdAt != nil, "createdAt should serialize as an ISO-8601 string, got: \(body)")
                if let createdAt {
                    #expect(ISO8601DateFormatter().date(from: createdAt) != nil)
                }
            }
        }
    }

    @Test("Generated handlers return the standard error envelope")
    func testProjectErrorEnvelope() async throws {
        try await withProjectTestApp { app, _, _, _, authToken in
            try await app.test(.GET, "/api/projects/\(UUID())") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .notFound)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.string.utf8)) as? [String: Any]
                #expect(json?["error"] as? Bool == true)
                #expect(json?["reason"] as? String == "Project not found")
            }
        }
    }

    @Test("A malformed project id is rejected with 400, not 500")
    func testProjectMalformedID() async throws {
        try await withProjectTestApp { app, _, _, _, authToken in
            try await app.test(.GET, "/api/projects/not-a-uuid") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }
}
