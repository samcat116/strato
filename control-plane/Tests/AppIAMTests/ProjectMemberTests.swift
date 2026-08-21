import AppTestSupport
import ControlPlanePostgres
import Testing
import Vapor
import VaporTesting

@testable import App

/// Project membership is policy, so grants are represented only by
/// `role_bindings`. These tests pin the UUID-only API and the exclusive grant
/// invariant for users and groups.
@Suite("Project Member Tests", .serialized)
final class ProjectMemberTests {
    private struct InvalidRoleGrant: Content {
        let userEmail: String
        let role: String
    }

    private func withApp(
        _ test: (Application, Project, User, User, TestGroup, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)

            let builder = TestDataBuilder(app: app)
            let org = try await builder.createOrganization(name: "PM Org")
            let actor = try await builder.createUser(
                username: "pmactor", email: "pmactor@example.com", displayName: "PM Actor")
            try await builder.addUserToOrganization(user: actor, organization: org, role: "admin")
            try await actor.replacingCurrentOrganization(org.id).save(on: app.testPostgres)

            let target = try await builder.createUser(
                username: "pmtarget", email: "pmtarget@example.com", displayName: "PM Target")
            let project = try await builder.createProject(
                name: "PM Project", description: "d", organization: org)
            let group = try await builder.createGroup(
                name: "PM Group", description: "d", organization: org)
            let token = try await actor.generateAPIKey(on: app)

            try await test(app, project, actor, target, group, token)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private func bindings(
        principalType: IAMPrincipalType, principalID: UUID, projectID: UUID, on db: PostgresStoreContext
    ) async throws -> [LegacyRoleBindingRecord] {
        try await LegacyRoleBindingStore.bindings(
            principalType: principalType.rawValue,
            principalID: principalID,
            nodeType: IAMNodeType.project.rawValue,
            nodeID: projectID,
            on: db)
    }

    private func makeRole(
        name: String, ownerType: IAMRoleOwnerType, ownerID: UUID,
        actions: [String], on db: PostgresStoreContext
    ) async throws -> LegacyIAMRoleRecord {
        let id = UUID()
        return try await RoleStore.insertLegacy(IAMRoleSnapshot(
            id: id, name: name, description: nil,
            ownerType: ownerType.rawValue, ownerID: ownerID,
            cedarText: RoleDescriptor.canonicalPermitText(id: id, actions: actions),
            actions: actions, managed: false, createdBy: nil), on: db)
    }

    @Test("Granting a user writes one authoritative role binding")
    func grantWritesBinding() async throws {
        try await withApp { app, project, _, target, _, token in
            try await app.test(.POST, "/api/projects/\(project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    ProjectMemberController.GrantMemberRequest(
                        userEmail: target.email, userID: nil, role: IAMRole.editor.seededID))
            } afterResponse: { res in
                #expect(res.status == .created)
            }

            let rows = try await bindings(
                principalType: .user, principalID: target.id!, projectID: project.id!, on: app.testPostgres)
            #expect(rows.map(\.roleID) == [IAMRole.editor.seededID])
        }
    }

    @Test("Role names are rejected at the UUID-only request boundary")
    func grantRejectsRoleName() async throws {
        try await withApp { app, project, _, target, _, token in
            try await app.test(.POST, "/api/projects/\(project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(InvalidRoleGrant(userEmail: target.email, role: "editor"))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
            #expect(
                try await bindings(
                    principalType: .user, principalID: target.id!, projectID: project.id!, on: app.testPostgres
                ).isEmpty)
        }
    }

    @Test("Changing a role replaces the only project grant")
    func roleChangeSwapsBinding() async throws {
        try await withApp { app, project, _, target, _, token in
            try await RoleBindingService.grant(
                principalType: .user, principalID: target.id!, role: .editor,
                nodeType: .project, nodeID: project.id!, createdBy: nil, on: app.testPostgres)

            try await app.test(.PATCH, "/api/projects/\(project.id!)/members/\(target.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    ProjectMemberController.UpdateMemberRoleRequest(role: IAMRole.admin.seededID))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            let rows = try await bindings(
                principalType: .user, principalID: target.id!, projectID: project.id!, on: app.testPostgres)
            #expect(rows.map(\.roleID) == [IAMRole.admin.seededID])
        }
    }

    @Test("Revoking removes the authoritative project grant")
    func revokeRemovesBinding() async throws {
        try await withApp { app, project, _, target, _, token in
            try await RoleBindingService.grant(
                principalType: .user, principalID: target.id!, role: .viewer,
                nodeType: .project, nodeID: project.id!, createdBy: nil, on: app.testPostgres)

            try await app.test(.DELETE, "/api/projects/\(project.id!)/members/\(target.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            #expect(
                try await bindings(
                    principalType: .user, principalID: target.id!, projectID: project.id!, on: app.testPostgres
                ).isEmpty)
        }
    }

    @Test("Granting and revoking a group writes only the authoritative binding")
    func grantAndRevokeGroup() async throws {
        try await withApp { app, project, _, _, group, token in
            try await app.test(.POST, "/api/projects/\(project.id!)/groups") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    ProjectMemberController.GrantGroupRequest(
                        groupID: group.id!, role: IAMRole.editor.seededID))
            } afterResponse: { res in
                #expect(res.status == .created)
            }

            let rows = try await bindings(
                principalType: .group, principalID: group.id!, projectID: project.id!, on: app.testPostgres)
            #expect(rows.map(\.roleID) == [IAMRole.editor.seededID])

            try await app.test(.DELETE, "/api/projects/\(project.id!)/groups/\(group.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
            #expect(
                try await bindings(
                    principalType: .group, principalID: group.id!, projectID: project.id!, on: app.testPostgres
                ).isEmpty)
        }
    }

    @Test("A custom role UUID is accepted only when bindable on the project")
    func customRoleScope() async throws {
        try await withApp { app, project, _, target, _, token in
            let allowed = try await makeRole(
                name: "deployer", ownerType: .project, ownerID: project.id!,
                actions: ["vm:read", "vm:start"], on: app.testPostgres)

            try await app.test(.POST, "/api/projects/\(project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    ProjectMemberController.GrantMemberRequest(
                        userEmail: target.email, userID: nil, role: allowed.id))
            } afterResponse: { res in
                #expect(res.status == .created)
            }
            let rows = try await bindings(
                principalType: .user, principalID: target.id!, projectID: project.id!, on: app.testPostgres)
            #expect(rows.map(\.roleID) == [allowed.id])
        }
    }

    @Test("An out-of-scope custom role UUID is rejected")
    func customRoleOutOfScope() async throws {
        try await withApp { app, project, _, target, _, token in
            let otherOrg = try await TestDataBuilder(db: app.testPostgres).createOrganization(name: "Other Org")
            let foreign = try await makeRole(
                name: "foreign", ownerType: .organization, ownerID: otherOrg.id!,
                actions: ["vm:read"], on: app.testPostgres)

            try await app.test(.POST, "/api/projects/\(project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    ProjectMemberController.GrantMemberRequest(
                        userEmail: target.email, userID: nil, role: foreign.id))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("Listing reads bindings and resolves role display names")
    func listReturnsRoleDisplayName() async throws {
        try await withApp { app, project, _, target, _, token in
            try await RoleBindingService.grant(
                principalType: .user, principalID: target.id!, role: .editor,
                nodeType: .project, nodeID: project.id!, createdBy: nil, on: app.testPostgres)

            try await app.test(.GET, "/api/projects/\(project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(ProjectMemberController.ProjectMembersResponse.self)
                let member = try #require(body.users.first { $0.userId == target.id })
                #expect(member.role == IAMRole.editor.seededID)
                #expect(member.roleDisplayName == "editor")
            }
        }
    }

    @Test("Listing requires view_project")
    func listRequiresViewProject() async throws {
        try await withApp { app, project, _, _, _, _ in
            let outsider = try await TestDataBuilder(db: app.testPostgres).createUser(
                username: "pm-outsider", email: "pm-outsider@example.com")
            let outsiderToken = try await outsider.generateAPIKey(on: app)
            try await app.test(.GET, "/api/projects/\(project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: outsiderToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("An editor cannot promote themselves to project admin")
    func editorCannotSelfPromote() async throws {
        try await withApp { app, project, _, _, _, _ in
            let editor = try await TestDataBuilder(db: app.testPostgres).createUser(
                username: "pm-editor", email: "pm-editor@example.com")
            try await RoleBindingService.grant(
                principalType: .user, principalID: editor.id!, role: .editor,
                nodeType: .project, nodeID: project.id!, createdBy: nil, on: app.testPostgres)
            let editorToken = try await editor.generateAPIKey(on: app)

            try await app.test(.PATCH, "/api/projects/\(project.id!)/members/\(editor.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: editorToken)
                try req.content.encode(
                    ProjectMemberController.UpdateMemberRoleRequest(role: IAMRole.admin.seededID))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            let rows = try await bindings(
                principalType: .user, principalID: editor.id!, projectID: project.id!, on: app.testPostgres)
            #expect(rows.map(\.roleID) == [IAMRole.editor.seededID])
        }
    }

    @Test("A grant narrowed by a ceiling still lands and reports the ceiling")
    func grantNarrowedByCeilingStillLands() async throws {
        try await withApp { app, project, _, target, _, token in
            app.guardrailAnalyzer = OverlappingGuardrailAnalyzer()
            _ = try await GuardrailStore.create(
                name: "no-vm-stop-org-wide", description: nil, effect: nil,
                node: IAMNode(type: .organization, id: try #require(project.organizationID)),
                actions: ["vm:stop"], principalMatch: .any, resourceMatch: .any,
                createdBy: nil, on: app.testPostgres)

            try await app.test(.POST, "/api/projects/\(project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    ProjectMemberController.GrantMemberRequest(
                        userEmail: target.email, userID: nil, role: IAMRole.editor.seededID))
            } afterResponse: { res in
                #expect(res.status == .created)
                let body = try res.content.decode(GrantWriteResponse.self)
                #expect(body.ceilings.first?.ceilingedActions == ["vm:stop"])
            }
        }
    }
}
