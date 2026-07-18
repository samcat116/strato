import Fluent
import Testing
import Vapor
import VaporTesting

@testable import App

/// IAM phase 1 (issue #477): the role/action registry, the role_bindings
/// store, the dual-writes at controller mutation sites, and the backfills
/// (relational mirrors + SpiceDB export). SpiceDB remains authoritative; these
/// tests assert the bindings shadow it correctly.
@Suite("IAM Role Binding Tests", .serialized)
final class IAMRoleBindingTests {

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()
            try await test(app)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private func bindings(
        on db: Database, nodeType: IAMNodeType, nodeID: UUID
    ) async throws -> [RoleBinding] {
        try await RoleBinding.query(on: db)
            .filter(\.$nodeType == nodeType.rawValue)
            .filter(\.$nodeID == nodeID)
            .all()
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

    @Test("Registry sync seeds the tables and is idempotent")
    func registrySyncIdempotent() async throws {
        try await withApp { app in
            // configure() already ran the sync once; run it again.
            try await RoleRegistrySync.sync(on: app.db, logger: app.logger)

            let roles = try await IAMRoleRecord.query(on: app.db).all()
            #expect(Set(roles.map(\.name)) == Set(IAMRole.allCases.map(\.rawValue)))
            let adminRow = roles.first { $0.name == "admin" }
            #expect(adminRow?.implies == "editor")

            let actionCount = try await IAMRoleAction.query(on: app.db).count()
            let expected = IAMRole.allCases.reduce(0) { $0 + IAMRoleRegistry.actions(for: $1).count }
            #expect(actionCount == expected)
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
                nodeType: .project, nodeID: node, createdBy: nil, on: app.db)
            try await RoleBindingService.grant(
                principalType: .user, principalID: principal, role: .editor,
                nodeType: .project, nodeID: node, createdBy: nil, on: app.db)

            var rows = try await bindings(on: app.db, nodeType: .project, nodeID: node)
            #expect(rows.count == 1)

            // Re-granting with a TTL refreshes the existing row.
            let expiry = Date().addingTimeInterval(-60)
            try await RoleBindingService.grant(
                principalType: .user, principalID: principal, role: .editor,
                nodeType: .project, nodeID: node, createdBy: nil, expiresAt: expiry, on: app.db)
            rows = try await bindings(on: app.db, nodeType: .project, nodeID: node)
            #expect(rows.count == 1)
            #expect(rows.first?.expiresAt != nil)

            // The expired binding is invisible to every read path.
            let active = try await RoleBindingService.activeBindings(
                nodeType: .project, nodeID: node, on: app.db)
            #expect(active.isEmpty)

            // An unexpired binding for a second role is visible.
            try await RoleBindingService.grant(
                principalType: .user, principalID: principal, role: .viewer,
                nodeType: .project, nodeID: node, createdBy: nil,
                expiresAt: Date().addingTimeInterval(3600), on: app.db)
            let activeNow = try await RoleBindingService.activeBindings(
                principalType: .user, principalID: principal, on: app.db)
            #expect(activeNow.count == 1)
            #expect(activeNow.first?.role == IAMRole.viewer.rawValue)

            // Role-scoped revoke removes only that role; revokeAll clears the node.
            try await RoleBindingService.revoke(
                principalType: .user, principalID: principal, role: .viewer,
                nodeType: .project, nodeID: node, on: app.db)
            rows = try await bindings(on: app.db, nodeType: .project, nodeID: node)
            #expect(rows.map(\.role) == [IAMRole.editor.rawValue])

            try await RoleBindingService.revokeAll(nodeType: .project, nodeID: node, on: app.db)
            rows = try await bindings(on: app.db, nodeType: .project, nodeID: node)
            #expect(rows.isEmpty)
        }
    }

    // MARK: - Backfills

    @Test("Mirror backfill maps org admins and project roles; bare members get no binding")
    func backfillFromMirrors() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "BF Org")
            let admin = try await builder.createUser(username: "bfadmin", email: "bfadmin@example.com")
            let member = try await builder.createUser(username: "bfmember", email: "bfmember@example.com")
            try await builder.addUserToOrganization(user: admin, organization: org, role: "admin")
            try await builder.addUserToOrganization(user: member, organization: org, role: "member")
            let project = try await builder.createProject(name: "BF Project", description: "d", organization: org)
            try await ProjectMember(projectID: project.id!, userID: member.id!, role: "member").save(on: app.db)
            let group = Group(name: "BF Group", description: "d", organizationID: org.id!)
            try await group.save(on: app.db)
            try await ProjectGroupGrant(projectID: project.id!, groupID: group.id!, role: "viewer").save(on: app.db)

            try await RoleBindingBackfill.backfillFromMirrors(app)
            // Idempotent: a second run inserts nothing new.
            try await RoleBindingBackfill.backfillFromMirrors(app)

            let orgBindings = try await bindings(on: app.db, nodeType: .organization, nodeID: org.id!)
            #expect(orgBindings.count == 1)
            #expect(orgBindings.first?.principalID == admin.id)
            #expect(orgBindings.first?.role == IAMRole.admin.rawValue)

            let projectBindings = try await bindings(on: app.db, nodeType: .project, nodeID: project.id!)
            #expect(projectBindings.count == 2)
            let userBinding = projectBindings.first { $0.principalType == IAMPrincipalType.user.rawValue }
            #expect(userBinding?.role == IAMRole.editor.rawValue)
            let groupBinding = projectBindings.first { $0.principalType == IAMPrincipalType.group.rawValue }
            #expect(groupBinding?.principalID == group.id)
            #expect(groupBinding?.role == IAMRole.viewer.rawValue)
        }
    }

    @Test("SpiceDB export backfill converts resource owner/editor/viewer tuples to bindings")
    func backfillFromSpiceDBExport() async throws {
        try await withApp { app in
            let vmID = UUID()
            let volumeID = UUID()
            let owner = UUID()
            let viewer = UUID()
            app.spicedbMockRelationships = [
                RelationshipTuple(
                    entity: "virtual_machine", entityId: vmID.uuidString.uppercased(),
                    relation: "owner", subject: "user", subjectId: owner.uuidString.uppercased()),
                RelationshipTuple(
                    entity: "virtual_machine", entityId: vmID.uuidString,
                    relation: "viewer", subject: "user", subjectId: viewer.uuidString),
                RelationshipTuple(
                    entity: "volume", entityId: volumeID.uuidString,
                    relation: "owner", subject: "user", subjectId: owner.uuidString),
                // Structural tuple: subject isn't a user, must be skipped.
                RelationshipTuple(
                    entity: "volume", entityId: volumeID.uuidString,
                    relation: "owner", subject: "project", subjectId: UUID().uuidString),
            ]

            try await RoleBindingBackfill.backfillFromSpiceDB(app)
            try await RoleBindingBackfill.backfillFromSpiceDB(app)

            let vmBindings = try await bindings(on: app.db, nodeType: .virtualMachine, nodeID: vmID)
            #expect(vmBindings.count == 2)
            let ownerBinding = vmBindings.first { $0.principalID == owner }
            #expect(ownerBinding?.role == IAMRole.admin.rawValue)
            let viewerBinding = vmBindings.first { $0.principalID == viewer }
            #expect(viewerBinding?.role == IAMRole.viewer.rawValue)

            let volumeBindings = try await bindings(on: app.db, nodeType: .volume, nodeID: volumeID)
            #expect(volumeBindings.count == 1)
            #expect(volumeBindings.first?.principalID == owner)
        }
    }

    // MARK: - Dual-writes through the API

    @Test("Organization create dual-writes admin + default-project creator bindings")
    func orgCreateWritesBindings() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let creator = try await builder.createUser(username: "orgcreator", email: "orgcreator@example.com")
            let token = try await creator.generateAPIKey(on: app.db)

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
            let orgBindings = try await bindings(on: app.db, nodeType: .organization, nodeID: createdOrgID)
            #expect(orgBindings.count == 1)
            #expect(orgBindings.first?.principalID == creator.id)
            #expect(orgBindings.first?.role == IAMRole.admin.rawValue)
            #expect(orgBindings.first?.createdBy == creator.id)

            // The auto-created default project carries a creator binding.
            let defaultProject = try await Project.query(on: app.db)
                .filter(\.$organization.$id == createdOrgID)
                .first()
            let projectID = try #require(defaultProject?.id)
            let projectBindings = try await bindings(on: app.db, nodeType: .project, nodeID: projectID)
            #expect(projectBindings.count == 1)
            #expect(projectBindings.first?.principalID == creator.id)
            #expect(projectBindings.first?.role == IAMRole.admin.rawValue)
        }
    }

    @Test("Project member grant/update/revoke keeps bindings in lockstep")
    func projectMemberBindingLifecycle() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "PMB Org")
            let actor = try await builder.createUser(username: "pmbactor", email: "pmbactor@example.com")
            try await builder.addUserToOrganization(user: actor, organization: org, role: "admin")
            actor.currentOrganizationId = org.id
            try await actor.save(on: app.db)
            let target = try await builder.createUser(username: "pmbtarget", email: "pmbtarget@example.com")
            let project = try await builder.createProject(name: "PMB Project", description: "d", organization: org)
            let token = try await actor.generateAPIKey(on: app.db)

            // Grant member → editor binding.
            try await app.test(.POST, "/api/projects/\(project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    ProjectMemberController.GrantMemberRequest(
                        userEmail: target.email, userID: nil, role: "member"))
            } afterResponse: { res in
                #expect(res.status == .created)
            }
            var rows = try await bindings(on: app.db, nodeType: .project, nodeID: project.id!)
            #expect(rows.count == 1)
            #expect(rows.first?.role == IAMRole.editor.rawValue)
            #expect(rows.first?.principalID == target.id)
            #expect(rows.first?.createdBy == actor.id)

            // Role change → the editor binding is replaced by admin.
            try await app.test(.PATCH, "/api/projects/\(project.id!)/members/\(target.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(ProjectMemberController.UpdateMemberRoleRequest(role: "admin"))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
            rows = try await bindings(on: app.db, nodeType: .project, nodeID: project.id!)
            #expect(rows.count == 1)
            #expect(rows.first?.role == IAMRole.admin.rawValue)

            // Revoke → no bindings left on the node.
            try await app.test(.DELETE, "/api/projects/\(project.id!)/members/\(target.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
            rows = try await bindings(on: app.db, nodeType: .project, nodeID: project.id!)
            #expect(rows.isEmpty)
        }
    }

    @Test("Group grant/revoke dual-writes group-principal bindings")
    func groupGrantBindingLifecycle() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "GGB Org")
            let actor = try await builder.createUser(username: "ggbactor", email: "ggbactor@example.com")
            try await builder.addUserToOrganization(user: actor, organization: org, role: "admin")
            actor.currentOrganizationId = org.id
            try await actor.save(on: app.db)
            let project = try await builder.createProject(name: "GGB Project", description: "d", organization: org)
            let group = Group(name: "GGB Group", description: "d", organizationID: org.id!)
            try await group.save(on: app.db)
            let token = try await actor.generateAPIKey(on: app.db)

            try await app.test(.POST, "/api/projects/\(project.id!)/groups") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    ProjectMemberController.GrantGroupRequest(groupID: group.id!, role: "viewer"))
            } afterResponse: { res in
                #expect(res.status == .created)
            }
            var rows = try await bindings(on: app.db, nodeType: .project, nodeID: project.id!)
            #expect(rows.count == 1)
            #expect(rows.first?.principalType == IAMPrincipalType.group.rawValue)
            #expect(rows.first?.principalID == group.id)
            #expect(rows.first?.role == IAMRole.viewer.rawValue)

            try await app.test(.DELETE, "/api/projects/\(project.id!)/groups/\(group.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
            rows = try await bindings(on: app.db, nodeType: .project, nodeID: project.id!)
            #expect(rows.isEmpty)
        }
    }

    @Test("Project create writes an explicit creator-admin binding")
    func projectCreateWritesCreatorBinding() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "PCB Org")
            let creator = try await builder.createUser(username: "pcbcreator", email: "pcbcreator@example.com")
            try await builder.addUserToOrganization(user: creator, organization: org, role: "member")
            creator.currentOrganizationId = org.id
            try await creator.save(on: app.db)
            let token = try await creator.generateAPIKey(on: app.db)

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
            let rows = try await bindings(on: app.db, nodeType: .project, nodeID: createdID)
            #expect(rows.count == 1)
            #expect(rows.first?.principalID == creator.id)
            #expect(rows.first?.role == IAMRole.admin.rawValue)
        }
    }
}
