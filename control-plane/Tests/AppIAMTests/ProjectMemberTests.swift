import Testing
import Vapor
import Fluent
import VaporTesting
import AppTestSupport
@testable import App

/// Tests project-level role grants (users and groups): the relational mirror rows are
/// written, the `role_bindings` rows follow (including revoke-old-then-grant-new on a
/// role change), and listing/mutations are gated by view_project / iam:setPolicy.
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
            #expect(bindings.map(\.role) == [IAMRole.editor.seededID.uuidString])
        }
    }

    @Test("A grant a ceiling narrows still lands, and the response names the ceiling")
    func grantNarrowedByCeilingStillLands() async throws {
        try await withApp { app, project, _, target, _, token in
            // The regression from STR-110, on the path it was reported on: one
            // narrow ceiling org-wide used to make every role above `viewer`
            // ungrantable everywhere beneath it.
            app.guardrailAnalyzer = OverlappingGuardrailAnalyzer()
            _ = try await GuardrailStore.create(
                name: "no-vm-stop-org-wide",
                description: nil,
                effect: nil,
                node: IAMNode(type: .organization, id: try #require(project.$organization.id)),
                actions: ["vm:stop"],
                principalMatch: .any,
                resourceMatch: .any,
                createdBy: nil,
                on: app.db
            )

            try await app.test(.POST, "/api/projects/\(project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    ProjectMemberController.GrantMemberRequest(
                        userEmail: target.email, userID: nil, role: "member"))
            } afterResponse: { res in
                #expect(res.status == .created)
                let body = try res.content.decode(GrantWriteResponse.self)
                // Named, so the grantor knows what the role will not do here —
                // and scoped to the one action, so they can see the other
                // thirty-odd still work.
                #expect(body.ceilings.count == 1)
                #expect(body.ceilings.first?.guardrail.contains("no-vm-stop-org-wide") == true)
                #expect(body.ceilings.first?.ceilingedActions == ["vm:stop"])
                #expect(body.analysisUnavailable == nil)
            }

            let bindings = try await RoleBinding.query(on: app.db)
                .filter(\.$principalType == IAMPrincipalType.user.rawValue)
                .filter(\.$principalID == target.id!)
                .filter(\.$nodeID == project.id!)
                .count()
            #expect(bindings == 1)
        }
    }

    @Test("Without a solver the grant still lands, and says the analysis could not run")
    func grantWithoutSolverSaysSo() async throws {
        try await withApp { app, project, _, target, _, token in
            app.guardrailAnalyzer = UnavailableGuardrailAnalyzer(reason: "no solver in this test")
            _ = try await GuardrailStore.create(
                name: "some-ceiling",
                description: nil,
                effect: nil,
                node: IAMNode(type: .organization, id: try #require(project.$organization.id)),
                actions: ["vm:*"],
                principalMatch: .any,
                resourceMatch: .any,
                createdBy: nil,
                on: app.db
            )

            try await app.test(.POST, "/api/projects/\(project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    ProjectMemberController.GrantMemberRequest(
                        userEmail: target.email, userID: nil, role: "member"))
            } afterResponse: { res in
                // The behavioural heart of the best-effort posture: a missing
                // solver costs the explanation, not the grant.
                #expect(res.status == .created)
                let body = try res.content.decode(GrantWriteResponse.self)
                #expect(body.ceilings.isEmpty)
                // And says so, rather than letting an empty list read as "no
                // ceiling narrows this" — the one thing the caller cannot tell
                // from the list alone.
                #expect(body.analysisUnavailable?.contains("no solver in this test") == true)
            }

            let bindings = try await RoleBinding.query(on: app.db)
                .filter(\.$principalType == IAMPrincipalType.user.rawValue)
                .filter(\.$principalID == target.id!)
                .filter(\.$nodeID == project.id!)
                .count()
            #expect(bindings == 1)
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
            #expect(!roles.contains(IAMRole.editor.seededID.uuidString))
            #expect(roles == [IAMRole.admin.seededID.uuidString])
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
            #expect(bindings.map(\.role) == [IAMRole.editor.seededID.uuidString])
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

    // MARK: - Unified role vocabulary (issue #608)

    /// A user-created role owned by `ownerType`/`ownerID`, saved directly. The
    /// resolver reads only its name/actions/owner, and the canonical permit
    /// keeps any policy-set rebuild happy.
    private func makeRole(
        name: String,
        ownerType: IAMRoleOwnerType,
        ownerID: UUID,
        actions: [String],
        on db: Database
    ) async throws -> IAMRoleDefinition {
        let id = UUID()
        let role = IAMRoleDefinition(
            id: id,
            name: name,
            ownerType: ownerType,
            ownerID: ownerID,
            cedarText: RoleDescriptor.canonicalPermitText(id: id, actions: actions),
            actions: actions,
            managed: false
        )
        try await role.save(on: db)
        return role
    }

    @Test("Granting by IAM role name binds the seeded role and stores its id")
    func grantByIAMRoleName() async throws {
        try await withApp { app, project, _, target, _, token in
            try await app.test(.POST, "/api/projects/\(project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    ProjectMemberController.GrantMemberRequest(
                        userEmail: target.email, userID: nil, role: "operator"))
            } afterResponse: { res in
                #expect(res.status == .created)
            }

            // Mirror row stores the seeded operator id, and the binding matches.
            let member = try await ProjectMember.query(on: app.db)
                .filter(\.$project.$id == project.id!)
                .filter(\.$user.$id == target.id!)
                .first()
            #expect(member?.role == IAMRole.operator.seededID.uuidString)

            let bindings = try await RoleBinding.query(on: app.db)
                .filter(\.$principalType == IAMPrincipalType.user.rawValue)
                .filter(\.$principalID == target.id!)
                .filter(\.$nodeType == IAMNodeType.project.rawValue)
                .filter(\.$nodeID == project.id!)
                .all()
            #expect(bindings.map(\.role) == [IAMRole.operator.seededID.uuidString])
        }
    }

    @Test("Granting by an in-scope role UUID binds that role")
    func grantByRoleUUIDInScope() async throws {
        try await withApp { app, project, _, target, _, token in
            let role = try await makeRole(
                name: "deployer", ownerType: .project, ownerID: project.id!,
                actions: ["vm:read", "vm:start"], on: app.db)

            try await app.test(.POST, "/api/projects/\(project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    ProjectMemberController.GrantMemberRequest(
                        userEmail: target.email, userID: nil, role: role.id!.uuidString))
            } afterResponse: { res in
                #expect(res.status == .created)
            }

            let bindings = try await RoleBinding.query(on: app.db)
                .filter(\.$principalType == IAMPrincipalType.user.rawValue)
                .filter(\.$principalID == target.id!)
                .filter(\.$nodeType == IAMNodeType.project.rawValue)
                .filter(\.$nodeID == project.id!)
                .all()
            #expect(bindings.map(\.role) == [role.id!.uuidString])
        }
    }

    // MARK: - Granting a custom role by name (STR-111)

    @Test("Granting by a project-owned role's name binds that role")
    func grantByProjectOwnedRoleName() async throws {
        try await withApp { app, project, _, target, _, token in
            let role = try await makeRole(
                name: "vm-restarter", ownerType: .project, ownerID: project.id!,
                actions: ["vm:read", "vm:restart"], on: app.db)

            try await app.test(.POST, "/api/projects/\(project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    ProjectMemberController.GrantMemberRequest(
                        userEmail: target.email, userID: nil, role: "vm-restarter"))
            } afterResponse: { res in
                #expect(res.status == .created)
            }

            // The name resolves to the same row the id would have: mirror row
            // and binding both store the role id.
            let member = try await ProjectMember.query(on: app.db)
                .filter(\.$project.$id == project.id!)
                .filter(\.$user.$id == target.id!)
                .first()
            #expect(member?.role == role.id!.uuidString)

            let bindings = try await RoleBinding.query(on: app.db)
                .filter(\.$principalType == IAMPrincipalType.user.rawValue)
                .filter(\.$principalID == target.id!)
                .filter(\.$nodeType == IAMNodeType.project.rawValue)
                .filter(\.$nodeID == project.id!)
                .all()
            #expect(bindings.map(\.role) == [role.id!.uuidString])
        }
    }

    @Test("An org-owned role's name is grantable on a project beneath it")
    func grantByInheritedRoleName() async throws {
        try await withApp { app, project, _, target, _, token in
            let role = try await makeRole(
                name: "auditor", ownerType: .organization, ownerID: project.$organization.id!,
                actions: ["vm:read"], on: app.db)

            try await app.test(.POST, "/api/projects/\(project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    ProjectMemberController.GrantMemberRequest(
                        userEmail: target.email, userID: nil, role: "auditor"))
            } afterResponse: { res in
                #expect(res.status == .created)
            }

            let bindings = try await RoleBinding.query(on: app.db)
                .filter(\.$principalType == IAMPrincipalType.user.rawValue)
                .filter(\.$principalID == target.id!)
                .filter(\.$nodeType == IAMNodeType.project.rawValue)
                .filter(\.$nodeID == project.id!)
                .all()
            #expect(bindings.map(\.role) == [role.id!.uuidString])
        }
    }

    @Test("A name owned outside the chain resolves to nothing, not to that role")
    func grantByOutOfScopeRoleName() async throws {
        try await withApp { app, project, _, target, _, token in
            let otherOrg = try await TestDataBuilder(db: app.db).createOrganization(name: "Other Name Org")
            _ = try await makeRole(
                name: "foreign", ownerType: .organization, ownerID: otherOrg.id!,
                actions: ["vm:read"], on: app.db)

            try await app.test(.POST, "/api/projects/\(project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    ProjectMemberController.GrantMemberRequest(
                        userEmail: target.email, userID: nil, role: "foreign"))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("Invalid role 'foreign'"))
            }

            let count = try await ProjectMember.query(on: app.db)
                .filter(\.$project.$id == project.id!)
                .filter(\.$user.$id == target.id!)
                .count()
            #expect(count == 0)
        }
    }

    @Test("A name two bindable roles share is a 400 naming both ids")
    func grantByAmbiguousRoleName() async throws {
        try await withApp { app, project, _, target, _, token in
            // Names are unique per owner, so the org and the project beneath it
            // can each define "deployer" — and neither is the obvious pick.
            let orgRole = try await makeRole(
                name: "deployer", ownerType: .organization, ownerID: project.$organization.id!,
                actions: ["vm:read"], on: app.db)
            let projectRole = try await makeRole(
                name: "deployer", ownerType: .project, ownerID: project.id!,
                actions: ["vm:read", "vm:start"], on: app.db)

            try await app.test(.POST, "/api/projects/\(project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    ProjectMemberController.GrantMemberRequest(
                        userEmail: target.email, userID: nil, role: "deployer"))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("ambiguous"))
                #expect(res.body.string.contains(orgRole.id!.uuidString))
                #expect(res.body.string.contains(projectRole.id!.uuidString))
            }

            let count = try await ProjectMember.query(on: app.db)
                .filter(\.$project.$id == project.id!)
                .filter(\.$user.$id == target.id!)
                .count()
            #expect(count == 0)
        }
    }

    @Test("updateRole takes a custom role's name too")
    func updateRoleByRoleName() async throws {
        try await withApp { app, project, _, target, _, token in
            try await ProjectMember(
                projectID: project.id!, userID: target.id!, role: IAMRole.viewer.seededID.uuidString
            ).save(on: app.db)
            try await RoleBindingService.grant(
                principalType: .user, principalID: target.id!, role: .viewer,
                nodeType: .project, nodeID: project.id!, createdBy: nil, on: app.db)

            let role = try await makeRole(
                name: "vm-restarter", ownerType: .project, ownerID: project.id!,
                actions: ["vm:read", "vm:restart"], on: app.db)

            try await app.test(.PATCH, "/api/projects/\(project.id!)/members/\(target.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    ProjectMemberController.UpdateMemberRoleRequest(role: "vm-restarter"))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            // The old viewer binding is revoked and the named role bound in its
            // place — the same handling the by-id form gets.
            let roles = try await RoleBinding.query(on: app.db)
                .filter(\.$principalType == IAMPrincipalType.user.rawValue)
                .filter(\.$principalID == target.id!)
                .filter(\.$nodeType == IAMNodeType.project.rawValue)
                .filter(\.$nodeID == project.id!)
                .all()
                .map(\.role)
            #expect(roles == [role.id!.uuidString])

            let member = try await ProjectMember.query(on: app.db)
                .filter(\.$project.$id == project.id!)
                .filter(\.$user.$id == target.id!)
                .first()
            #expect(member?.role == role.id!.uuidString)
        }
    }

    @Test("A custom role named 'viewer' does not shadow the seeded viewer")
    func fixedVocabularyWinsOverCustomName() async throws {
        try await withApp { app, project, _, target, _, token in
            _ = try await makeRole(
                name: "viewer", ownerType: .project, ownerID: project.id!,
                actions: ["vm:read", "vm:delete"], on: app.db)

            try await app.test(.POST, "/api/projects/\(project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    ProjectMemberController.GrantMemberRequest(
                        userEmail: target.email, userID: nil, role: "viewer"))
            } afterResponse: { res in
                #expect(res.status == .created)
            }

            // "viewer" still means the seeded viewer; the project's own role of
            // that name is reachable by id.
            let bindings = try await RoleBinding.query(on: app.db)
                .filter(\.$principalType == IAMPrincipalType.user.rawValue)
                .filter(\.$principalID == target.id!)
                .filter(\.$nodeType == IAMNodeType.project.rawValue)
                .filter(\.$nodeID == project.id!)
                .all()
            #expect(bindings.map(\.role) == [IAMRole.viewer.seededID.uuidString])
        }
    }

    @Test("Granting by an out-of-scope role UUID is a 400 naming the mismatch")
    func grantByRoleUUIDOutOfScope() async throws {
        try await withApp { app, project, _, target, _, token in
            // A role owned by a different, unrelated organization: not on this
            // project's ancestor chain.
            let otherOrg = try await TestDataBuilder(db: app.db).createOrganization(name: "Other Org")
            let role = try await makeRole(
                name: "foreign", ownerType: .organization, ownerID: otherOrg.id!,
                actions: ["vm:read"], on: app.db)

            try await app.test(.POST, "/api/projects/\(project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    ProjectMemberController.GrantMemberRequest(
                        userEmail: target.email, userID: nil, role: role.id!.uuidString))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("not in the hierarchy"))
            }

            let count = try await ProjectMember.query(on: app.db)
                .filter(\.$project.$id == project.id!)
                .filter(\.$user.$id == target.id!)
                .count()
            #expect(count == 0)
        }
    }

    @Test("Listing normalizes legacy rows to a role id and a display name")
    func listReturnsRoleDisplayName() async throws {
        try await withApp { app, project, _, target, _, token in
            // A legacy mirror row storing the relational name "member".
            try await ProjectMember(projectID: project.id!, userID: target.id!, role: "member")
                .save(on: app.db)
            try await RoleBindingService.grant(
                principalType: .user, principalID: target.id!, role: .editor,
                nodeType: .project, nodeID: project.id!, createdBy: nil, on: app.db)

            try await app.test(.GET, "/api/projects/\(project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(ProjectMemberController.ProjectMembersResponse.self)
                let member = try #require(body.users.first { $0.userId == target.id })
                // Legacy "member" is normalized to the editor id + name.
                #expect(member.role == IAMRole.editor.seededID.uuidString)
                #expect(member.roleDisplayName == "editor")
            }
        }
    }

    @Test("updateRole revokes the old binding across legacy and UUID formats")
    func updateRoleRevokesAcrossStoredFormats() async throws {
        try await withApp { app, project, _, target, _, token in
            // Seed a legacy "member" row + its editor binding, then PATCH to a
            // custom role by UUID.
            try await ProjectMember(projectID: project.id!, userID: target.id!, role: "member")
                .save(on: app.db)
            try await RoleBindingService.grant(
                principalType: .user, principalID: target.id!, role: .editor,
                nodeType: .project, nodeID: project.id!, createdBy: nil, on: app.db)

            let role = try await makeRole(
                name: "deployer", ownerType: .project, ownerID: project.id!,
                actions: ["vm:read", "vm:start"], on: app.db)

            try await app.test(.PATCH, "/api/projects/\(project.id!)/members/\(target.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    ProjectMemberController.UpdateMemberRoleRequest(role: role.id!.uuidString))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            // Old editor binding gone, new custom-role binding present, and the
            // mirror row now stores the custom role id.
            let roles = try await RoleBinding.query(on: app.db)
                .filter(\.$principalType == IAMPrincipalType.user.rawValue)
                .filter(\.$principalID == target.id!)
                .filter(\.$nodeType == IAMNodeType.project.rawValue)
                .filter(\.$nodeID == project.id!)
                .all()
                .map(\.role)
            #expect(roles == [role.id!.uuidString])

            let member = try await ProjectMember.query(on: app.db)
                .filter(\.$project.$id == project.id!)
                .filter(\.$user.$id == target.id!)
                .first()
            #expect(member?.role == role.id!.uuidString)
        }
    }

    @Test("An editor cannot promote themselves to project admin")
    func editorCannotSelfPromote() async throws {
        try await withApp { app, project, _, _, _, _ in
            let editor = try await TestDataBuilder(db: app.db).createUser(
                username: "pm-editor", email: "pm-editor@example.com")
            try await RoleBindingService.grant(
                principalType: .user, principalID: editor.id!, role: .editor,
                nodeType: .project, nodeID: project.id!, createdBy: nil, on: app.db)
            try await ProjectMember(
                projectID: project.id!, userID: editor.id!, role: IAMRole.editor.seededID.uuidString
            ).save(on: app.db)
            let editorToken = try await editor.generateAPIKey(on: app.db)

            try await app.test(.PATCH, "/api/projects/\(project.id!)/members/\(editor.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: editorToken)
                try req.content.encode(ProjectMemberController.UpdateMemberRoleRequest(role: "admin"))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            let membership = try await ProjectMember.query(on: app.db)
                .filter(\.$project.$id == project.id!)
                .filter(\.$user.$id == editor.id!)
                .first()
            #expect(membership?.role == IAMRole.editor.seededID.uuidString)
        }
    }
}
