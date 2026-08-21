import Testing
import Vapor
import VaporTesting

import AppTestSupport
import ControlPlanePostgres
@testable import App

/// IAM phase 1 (issue #477): the role/action registry, the role_bindings
/// store, the dual-writes at controller mutation sites, and the
/// relational-mirror backfill. The bindings are what the Cedar evaluator
/// authorizes from; these tests assert they are written correctly.
@Suite("IAM Role Binding Tests", .serialized)
final class IAMRoleBindingTests {

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await test(app)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private func bindings(
        on db: PostgresStoreContext, nodeType: IAMNodeType, nodeID: UUID
    ) async throws -> [LegacyRoleBindingRecord] {
        try await LegacyRoleBindingStore.bindings(
            nodeType: nodeType.rawValue, nodeID: nodeID, on: db)
    }

    // MARK: - Registry

    @Test("Roles nest strictly: viewer ⊂ operator ⊂ editor ⊂ admin")
    func roleNesting() {
        let viewer = IAMRoleRegistry.actions(for: .viewer)
        let op = IAMRoleRegistry.actions(for: .operator)
        let editor = IAMRoleRegistry.actions(for: .editor)
        let admin = IAMRoleRegistry.actions(for: .admin)

        #expect(viewer.isStrictSubset(of: op))
        #expect(op.isStrictSubset(of: editor))
        #expect(editor.isStrictSubset(of: admin))
        // Spot-check the doc's illustrative members.
        #expect(viewer.contains("image:download"))
        #expect(op.contains("vm:start") && !viewer.contains("vm:start"))
        #expect(editor.contains("vm:viewConsole") && !op.contains("vm:viewConsole"))
        #expect(admin.contains("iam:setPolicy") && !editor.contains("iam:setPolicy"))
    }

    @Test("Registry sync seeds the managed rows and is idempotent")
    func registrySyncIdempotent() async throws {
        try await withApp { app in
            // configure() already ran the sync once; run it again.
            try await app.policySetVersion.synchronizeRoleRegistry(logger: app.logger)

            // Every managed row matches its seeded descriptor exactly:
            // fixed id, name, expanded action set, canonical Cedar text.
            let managed = try await RoleStore.legacyRoles(on: app.testPostgres).filter(\.managed)
            #expect(managed.count == IAMRole.allCases.count)
            for desired in RoleDescriptor.seededDefaults() {
                let row = managed.first { $0.id == desired.id }
                #expect(row?.name == desired.name)
                #expect(row?.actions == desired.actions)
                #expect(row?.cedarText == desired.cedarText)
                #expect(row?.ownerType == IAMRoleOwnerType.platform.rawValue)
                #expect(row?.ownerID == IAMRoleOwnerType.platformOwnerID)
            }
        }
    }

    @Test("Registry sync never touches user-created rows")
    func registrySyncLeavesUserRolesAlone() async throws {
        try await withApp { app in
            let userRole = try await RoleStore.insertLegacy(IAMRoleSnapshot(
                id: UUID(),
                name: "auditor",
                description: nil,
                ownerType: IAMRoleOwnerType.organization.rawValue,
                ownerID: UUID(),
                cedarText: "// user-authored",
                actions: ["vm:read"],
                managed: false,
                createdBy: nil), on: app.testPostgres)

            try await app.policySetVersion.synchronizeRoleRegistry(logger: app.logger)

            let survived = try await RoleStore.legacyRole(id: userRole.id, on: app.testPostgres)
            #expect(survived?.cedarText == "// user-authored")
            #expect(survived?.actions == ["vm:read"])
        }
    }

    // MARK: - Binding service

    @Test("Grant is an idempotent upsert; revoke and expiry filtering work")
    func grantRevokeExpiry() async throws {
        try await withApp { app in
            let principal = UUID()
            let node = UUID()

            try await RoleBindingService.grant(
                principalType: .user, principalID: principal, role: .editor,
                nodeType: .project, nodeID: node, createdBy: nil, on: app.testPostgres)
            try await RoleBindingService.grant(
                principalType: .user, principalID: principal, role: .editor,
                nodeType: .project, nodeID: node, createdBy: nil, on: app.testPostgres)

            var rows = try await bindings(on: app.testPostgres, nodeType: .project, nodeID: node)
            #expect(rows.count == 1)

            // Re-granting with a TTL refreshes the existing row.
            let expiry = Date().addingTimeInterval(-60)
            try await RoleBindingService.grant(
                principalType: .user, principalID: principal, role: .editor,
                nodeType: .project, nodeID: node, createdBy: nil, expiresAt: expiry, on: app.testPostgres)
            rows = try await bindings(on: app.testPostgres, nodeType: .project, nodeID: node)
            #expect(rows.count == 1)
            #expect(rows.first?.expiresAt != nil)

            // The expired binding is invisible to every read path.
            let active = try await RoleBindingService.activeBindings(
                nodeType: .project, nodeID: node, on: app.testPostgres)
            #expect(active.isEmpty)

            // An unexpired binding for a second role is visible.
            try await RoleBindingService.grant(
                principalType: .user, principalID: principal, role: .viewer,
                nodeType: .project, nodeID: node, createdBy: nil,
                expiresAt: Date().addingTimeInterval(3600), on: app.testPostgres)
            let activeNow = try await RoleBindingService.activeBindings(
                principalType: .user, principalID: principal, on: app.testPostgres)
            #expect(activeNow.count == 1)
            #expect(activeNow.first?.roleID == IAMRole.viewer.seededID)

            // Role-scoped revoke removes only that role; revokeAll clears the node.
            try await RoleBindingService.revoke(
                principalType: .user, principalID: principal, role: .viewer,
                nodeType: .project, nodeID: node, on: app.testPostgres)
            rows = try await bindings(on: app.testPostgres, nodeType: .project, nodeID: node)
            #expect(rows.map(\.roleID) == [IAMRole.editor.seededID])

            try await RoleBindingService.revokeAll(nodeType: .project, nodeID: node, on: app.testPostgres)
            rows = try await bindings(on: app.testPostgres, nodeType: .project, nodeID: node)
            #expect(rows.isEmpty)
        }
    }

    // MARK: - Conditions (STR-108)

    @Test("A conditioned binding is refused at write time, not silently accepted")
    func conditionedBindingRefusedAtWrite() async throws {
        try await withApp { app in
            let refused = try await conditionedRoleBindingsAreRefused(on: app.testPostgres)
            #expect(refused)

            // Conditions are not compiled, so the evaluator skips a conditioned
            // row and it grants nothing. A row that looks like a live grant in
            // every listing and confers no access is the hazard; the schema
            // says no rather than letting one be written.
            await #expect(throws: (any Error).self) {
                try await LegacyRoleBindingStore.insert(
                    LegacyRoleBindingWrite(
                        principalType: IAMPrincipalType.user.rawValue,
                        principalID: UUID(),
                        roleID: IAMRole.editor.seededID,
                        nodeType: IAMNodeType.project.rawValue,
                        nodeID: UUID(),
                        condition: #"{"mfa": true}"#),
                    on: app.testPostgres)
            }

            let rows = try await LegacyRoleBindingStore.bindings(on: app.testPostgres)
            #expect(rows.isEmpty)
        }
    }

    // MARK: - Authoritative API writes

    @Test("Organization create dual-writes admin + default-project creator bindings")
    func orgCreateWritesBindings() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(app: app)
            let creator = try await builder.createUser(username: "orgcreator", email: "orgcreator@example.com")
            let token = try await creator.generateAPIKey(on: app)

            var orgID: UUID?
            try await app.test(.POST, "/api/organizations") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(CreateOrganizationRequest(name: "IAM Org", description: "d"))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(OrganizationResponse.self)
                orgID = body.id
            }

            let createdOrgID = try #require(orgID)
            let orgBindings = try await bindings(on: app.testPostgres, nodeType: .organization, nodeID: createdOrgID)
            #expect(orgBindings.count == 1)
            #expect(orgBindings.first?.principalID == creator.id)
            #expect(orgBindings.first?.roleID == IAMRole.admin.seededID)
            #expect(orgBindings.first?.createdBy == creator.id)

            // The auto-created default project carries a creator binding.
            let defaultProject = try await LegacyProjectStore.projects(
                organizationIDs: [createdOrgID], on: app.testPostgres
            ).first
            let projectID = try #require(defaultProject?.id)
            let projectBindings = try await bindings(on: app.testPostgres, nodeType: .project, nodeID: projectID)
            #expect(projectBindings.count == 1)
            #expect(projectBindings.first?.principalID == creator.id)
            #expect(projectBindings.first?.roleID == IAMRole.admin.seededID)

            // The org also gets a default site so it can enroll agents right
            // away (enrollment requires one).
            let sites = try await LegacySiteStore.sites(
                organizationID: createdOrgID,
                on: app.testPostgres)
            #expect(sites.count == 1)
            #expect(sites.first?.name == Site.defaultName(forOrganizationNamed: "IAM Org"))
            #expect(sites.first?.organizationalUnitID == nil)
        }
    }

    @Test("Project member grant/update/revoke keeps bindings in lockstep")
    func projectMemberBindingLifecycle() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.testPostgres)
            let org = try await builder.createOrganization(name: "PMB Org")
            let actor = try await builder.createUser(username: "pmbactor", email: "pmbactor@example.com")
            try await builder.addUserToOrganization(user: actor, organization: org, role: "admin")
            try await actor.replacingCurrentOrganization(org.id).save(on: app.testPostgres)
            let target = try await builder.createUser(username: "pmbtarget", email: "pmbtarget@example.com")
            let project = try await builder.createProject(name: "PMB Project", description: "d", organization: org)
            let token = try await actor.generateAPIKey(on: app)

            // Grant member → editor binding.
            try await app.test(.POST, "/api/projects/\(project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    ProjectMemberController.GrantMemberRequest(
                        userEmail: target.email, userID: nil, role: IAMRole.editor.seededID))
            } afterResponse: { res in
                #expect(res.status == .created)
            }
            var rows = try await bindings(on: app.testPostgres, nodeType: .project, nodeID: project.id!)
            #expect(rows.count == 1)
            #expect(rows.first?.roleID == IAMRole.editor.seededID)
            #expect(rows.first?.principalID == target.id)
            #expect(rows.first?.createdBy == actor.id)

            // Role change → the editor binding is replaced by admin.
            try await app.test(.PATCH, "/api/projects/\(project.id!)/members/\(target.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    ProjectMemberController.UpdateMemberRoleRequest(role: IAMRole.admin.seededID))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
            rows = try await bindings(on: app.testPostgres, nodeType: .project, nodeID: project.id!)
            #expect(rows.count == 1)
            #expect(rows.first?.roleID == IAMRole.admin.seededID)

            // Revoke → no bindings left on the node.
            try await app.test(.DELETE, "/api/projects/\(project.id!)/members/\(target.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
            rows = try await bindings(on: app.testPostgres, nodeType: .project, nodeID: project.id!)
            #expect(rows.isEmpty)
        }
    }

    @Test("Group grant/revoke dual-writes group-principal bindings")
    func groupGrantBindingLifecycle() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(app: app)
            let org = try await builder.createOrganization(name: "GGB Org")
            let actor = try await builder.createUser(username: "ggbactor", email: "ggbactor@example.com")
            try await builder.addUserToOrganization(user: actor, organization: org, role: "admin")
            try await actor.replacingCurrentOrganization(org.id).save(on: app.testPostgres)
            let project = try await builder.createProject(name: "GGB Project", description: "d", organization: org)
            let group = try await builder.createGroup(
                name: "GGB Group", description: "d", organization: org)
            let token = try await actor.generateAPIKey(on: app)

            try await app.test(.POST, "/api/projects/\(project.id!)/groups") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    ProjectMemberController.GrantGroupRequest(
                        groupID: group.id!, role: IAMRole.viewer.seededID))
            } afterResponse: { res in
                #expect(res.status == .created)
            }
            var rows = try await bindings(on: app.testPostgres, nodeType: .project, nodeID: project.id!)
            #expect(rows.count == 1)
            #expect(rows.first?.principalType == IAMPrincipalType.group.rawValue)
            #expect(rows.first?.principalID == group.id)
            #expect(rows.first?.roleID == IAMRole.viewer.seededID)

            try await app.test(.DELETE, "/api/projects/\(project.id!)/groups/\(group.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
            rows = try await bindings(on: app.testPostgres, nodeType: .project, nodeID: project.id!)
            #expect(rows.isEmpty)
        }
    }

    @Test("Project create writes an explicit creator-admin binding")
    func projectCreateWritesCreatorBinding() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.testPostgres)
            let org = try await builder.createOrganization(name: "PCB Org")
            let creator = try await builder.createUser(username: "pcbcreator", email: "pcbcreator@example.com")
            try await builder.addUserToOrganization(user: creator, organization: org, role: "member")
            try await creator.replacingCurrentOrganization(org.id).save(on: app.testPostgres)
            let token = try await creator.generateAPIKey(on: app)

            var projectID: UUID?
            try await app.test(.POST, "/api/organizations/\(org.id!)/projects") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateProjectRequest(
                        name: "Created By Member", description: "d",
                        organizationalUnitId: nil, defaultEnvironment: nil, environments: nil))
            } afterResponse: { res in
                #expect(res.status == .ok || res.status == .created)
                if res.status == .ok || res.status == .created {
                    let body = try res.content.decode(ProjectResponse.self)
                    projectID = body.id
                }
            }

            let createdID = try #require(projectID)
            let rows = try await bindings(on: app.testPostgres, nodeType: .project, nodeID: createdID)
            #expect(rows.count == 1)
            #expect(rows.first?.principalID == creator.id)
            #expect(rows.first?.roleID == IAMRole.admin.seededID)
        }
    }
}
