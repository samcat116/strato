import Testing
import Vapor
import Fluent
import VaporTesting
@testable import App

/// Tests project-level role grants (users and groups): the relational mirror rows are
/// written, the `role_bindings` rows follow (including revoke-old-then-grant-new on a
/// role change), and listing/mutations are gated by view_project / manage_project.
@Suite("Project Member Tests", .serialized)
final class ProjectMemberTests {

    private func withApp(
        _ test: (Application, Project, User, User, Group, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "PM Org")
            let actor = try await builder.createUser(
                username: "pmactor", email: "pmactor@example.com", displayName: "PM Actor")
            try await builder.addUserToOrganization(user: actor, organization: org, role: "admin")
            actor.currentOrganizationId = org.id
            try await actor.save(on: app.db)

            let target = try await builder.createUser(
                username: "pmtarget", email: "pmtarget@example.com", displayName: "PM Target")

            let project = try await builder.createProject(
                name: "PM Project", description: "d", organization: org)

            let group = Group(name: "PM Group", description: "d", organizationID: org.id!)
            try await group.save(on: app.db)

            let token = try await actor.generateAPIKey(on: app.db)

            try await test(app, project, actor, target, group, token)

        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test("Granting a user role writes a row and a role binding")
    func grantWritesRowAndBinding() async throws {
        try await withApp { app, project, _, target, _, token in
            try await app.test(.POST, "/api/projects/\(project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    ProjectMemberController.GrantMemberRequest(
                        userEmail: target.email, userID: nil, role: "member"))
            } afterResponse: { res in
                #expect(res.status == .created)
            }

            let count = try await ProjectMember.query(on: app.db)
                .filter(\.$project.$id == project.id!)
                .filter(\.$user.$id == target.id!)
                .count()
            #expect(count == 1)

            // The "member" project role maps to an editor binding on the
            // project node.
            let bindings = try await RoleBinding.query(on: app.db)
                .filter(\.$principalType == IAMPrincipalType.user.rawValue)
                .filter(\.$principalID == target.id!)
                .filter(\.$nodeType == IAMNodeType.project.rawValue)
                .filter(\.$nodeID == project.id!)
                .all()
            #expect(bindings.map(\.role) == [IAMRole.editor.rawValue])
        }
    }

    @Test("Changing a role revokes the old binding and grants the new one")
    func roleChangeSwapsBindings() async throws {
        try await withApp { app, project, _, target, _, token in
            // Seed a member grant (row + its editor binding) directly, then
            // PATCH to admin.
            try await ProjectMember(projectID: project.id!, userID: target.id!, role: "member")
                .save(on: app.db)
            try await RoleBindingService.grant(
                principalType: .user, principalID: target.id!, role: .editor,
                nodeType: .project, nodeID: project.id!, createdBy: nil, on: app.db)

            try await app.test(.PATCH, "/api/projects/\(project.id!)/members/\(target.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(ProjectMemberController.UpdateMemberRoleRequest(role: "admin"))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            let roles = try await RoleBinding.query(on: app.db)
                .filter(\.$principalType == IAMPrincipalType.user.rawValue)
                .filter(\.$principalID == target.id!)
                .filter(\.$nodeType == IAMNodeType.project.rawValue)
                .filter(\.$nodeID == project.id!)
                .all()
                .map(\.role)
            #expect(!roles.contains(IAMRole.editor.rawValue))
            #expect(roles == [IAMRole.admin.rawValue])
        }
    }

    @Test("Revoking removes the row and the role binding")
    func revokeRemovesRowAndBinding() async throws {
        try await withApp { app, project, _, target, _, token in
            try await ProjectMember(projectID: project.id!, userID: target.id!, role: "viewer")
                .save(on: app.db)
            try await RoleBindingService.grant(
                principalType: .user, principalID: target.id!, role: .viewer,
                nodeType: .project, nodeID: project.id!, createdBy: nil, on: app.db)

            try await app.test(.DELETE, "/api/projects/\(project.id!)/members/\(target.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let count = try await ProjectMember.query(on: app.db)
                .filter(\.$project.$id == project.id!)
                .filter(\.$user.$id == target.id!)
                .count()
            #expect(count == 0)

            let bindingCount = try await RoleBinding.query(on: app.db)
                .filter(\.$principalType == IAMPrincipalType.user.rawValue)
                .filter(\.$principalID == target.id!)
                .filter(\.$nodeType == IAMNodeType.project.rawValue)
                .filter(\.$nodeID == project.id!)
                .count()
            #expect(bindingCount == 0)
        }
    }

    @Test("Granting a group writes a group role binding")
    func grantGroupWritesBinding() async throws {
        try await withApp { app, project, _, _, group, token in
            try await app.test(.POST, "/api/projects/\(project.id!)/groups") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    ProjectMemberController.GrantGroupRequest(groupID: group.id!, role: "member"))
            } afterResponse: { res in
                #expect(res.status == .created)
            }

            let bindings = try await RoleBinding.query(on: app.db)
                .filter(\.$principalType == IAMPrincipalType.group.rawValue)
                .filter(\.$principalID == group.id!)
                .filter(\.$nodeType == IAMNodeType.project.rawValue)
                .filter(\.$nodeID == project.id!)
                .all()
            #expect(bindings.map(\.role) == [IAMRole.editor.rawValue])
        }
    }

    @Test("Listing requires view_project")
    func listRequiresViewProject() async throws {
        try await withApp { app, project, _, _, _, _ in
            // No binding anywhere: project:read is denied.
            let outsider = try await TestDataBuilder(db: app.db).createUser(
                username: "pm-outsider", email: "pm-outsider@example.com")
            let outsiderToken = try await outsider.generateAPIKey(on: app.db)
            try await app.test(.GET, "/api/projects/\(project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: outsiderToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("Granting requires manage_project")
    func grantRequiresManageProject() async throws {
        try await withApp { app, project, _, target, _, _ in
            // A viewer can list members but holds no project:update, so the
            // grant is denied.
            let viewer = try await TestDataBuilder(db: app.db).createUser(
                username: "pm-viewer", email: "pm-viewer@example.com")
            try await RoleBindingService.grant(
                principalType: .user, principalID: viewer.id!, role: .viewer,
                nodeType: .project, nodeID: project.id!, createdBy: nil, on: app.db)
            let viewerToken = try await viewer.generateAPIKey(on: app.db)
            try await app.test(.POST, "/api/projects/\(project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: viewerToken)
                try req.content.encode(
                    ProjectMemberController.GrantMemberRequest(
                        userEmail: target.email, userID: nil, role: "member"))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }
}
