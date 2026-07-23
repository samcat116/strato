import Fluent
import Testing
import Vapor
import VaporTesting

@testable import App

/// Cross-org bindings (issue #485): granting a role to a principal outside the
/// resource's organization is allowed — explicit bindings only — but gated at
/// write time on `iam:grantExternal`, recorded with distinct audit events, and
/// marked wherever grants are listed. Offboarding sweeps are external-aware in
/// both directions: leaving an org revokes everything inside that org's
/// subtree (and nothing outside it), while deleting a principal sweeps its
/// bindings across all orgs.
@Suite("Cross-Org Binding Tests", .serialized)
final class CrossOrgBindingTests {

    struct Fixture {
        let homeOrg: Organization
        let otherOrg: Organization
        let project: Project
        /// Admin of `homeOrg` — carries `iam:grantExternal` via the admin role.
        let actor: User
        let actorToken: String
        /// Member of `otherOrg` only.
        let externalUser: User
        /// Member of `homeOrg`.
        let internalUser: User
        /// Owned by `otherOrg`.
        let externalGroup: Group
    }

    private func withApp(_ test: (Application, Fixture) async throws -> Void) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let homeOrg = try await builder.createOrganization(name: "XOrg Home")
            let otherOrg = try await builder.createOrganization(name: "XOrg Other")

            let actor = try await builder.createUser(
                username: "xorg-actor", email: "xorg-actor@example.com", displayName: "XOrg Actor")
            try await builder.addUserToOrganization(user: actor, organization: homeOrg, role: "admin")
            actor.currentOrganizationId = homeOrg.id
            try await actor.save(on: app.db)

            let externalUser = try await builder.createUser(
                username: "xorg-external", email: "xorg-external@example.com", displayName: "XOrg External")
            try await builder.addUserToOrganization(user: externalUser, organization: otherOrg)

            let internalUser = try await builder.createUser(
                username: "xorg-internal", email: "xorg-internal@example.com", displayName: "XOrg Internal")
            try await builder.addUserToOrganization(user: internalUser, organization: homeOrg)

            let project = try await builder.createProject(
                name: "XOrg Project", description: "d", organization: homeOrg)

            let externalGroup = try await builder.createGroup(
                name: "XOrg External Group", description: "d", organization: otherOrg)

            let token = try await actor.generateAPIKey(on: app.db)
            let fixture = Fixture(
                homeOrg: homeOrg, otherOrg: otherOrg, project: project,
                actor: actor, actorToken: token,
                externalUser: externalUser, internalUser: internalUser,
                externalGroup: externalGroup)

            try await test(app, fixture)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private func crossOrgAuditEvents(_ app: Application, type: AuditEventType) async throws -> [AuditEvent] {
        try await AuditEvent.query(on: app.db)
            .filter(\.$eventType == type.rawValue)
            .all()
    }

    @Test("The admin role carries iam:grantExternal; lower roles do not")
    func registryCarriesGrantExternal() {
        #expect(IAMRoleRegistry.actions(for: .admin).contains("iam:grantExternal"))
        #expect(!IAMRoleRegistry.actions(for: .editor).contains("iam:grantExternal"))
        #expect(IAMRoleRegistry.allActions.contains("iam:grantExternal"))
    }

    @Test("Granting an external user succeeds for an admin, is audited, and is marked in the list")
    func externalUserGrantGatedAndLoud() async throws {
        try await withApp { app, fx in
            try await app.test(.POST, "/api/projects/\(fx.project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fx.actorToken)
                try req.content.encode(
                    ProjectMemberController.GrantMemberRequest(
                        userEmail: fx.externalUser.email, userID: nil, role: "viewer"))
            } afterResponse: { res in
                #expect(res.status == .created)
            }

            let bindings = try await RoleBinding.query(on: app.db)
                .filter(\.$principalID == fx.externalUser.id!)
                .filter(\.$nodeID == fx.project.id!)
                .count()
            #expect(bindings == 1)

            // The distinct, filterable audit event is the loudness contract.
            let events = try await crossOrgAuditEvents(app, type: .crossOrgGrant)
            #expect(events.count == 1)
            let event = try #require(events.first)
            #expect(event.userID == fx.actor.id)
            #expect(event.resourceType == "project")
            #expect(event.resourceID == fx.project.id!.uuidString)
            #expect(event.organizationID == fx.homeOrg.id)
            #expect(event.metadata?["principalId"] == fx.externalUser.id!.uuidString)
            #expect(event.metadata?["principalType"] == "user")
            #expect(event.metadata?["role"] == "viewer")

            // The members list marks the external principal.
            try await app.test(.GET, "/api/projects/\(fx.project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fx.actorToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let members = try res.content.decode(ProjectMemberController.ProjectMembersResponse.self)
                let external = members.users.first { $0.userId == fx.externalUser.id }
                #expect(external?.external == true)
            }
        }
    }

    @Test("An internal grant is neither gated nor audited as cross-org")
    func internalGrantNotAudited() async throws {
        try await withApp { app, fx in
            try await app.test(.POST, "/api/projects/\(fx.project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fx.actorToken)
                try req.content.encode(
                    ProjectMemberController.GrantMemberRequest(
                        userEmail: fx.internalUser.email, userID: nil, role: "member"))
            } afterResponse: { res in
                #expect(res.status == .created)
            }

            let events = try await crossOrgAuditEvents(app, type: .crossOrgGrant)
            #expect(events.isEmpty)

            try await app.test(.GET, "/api/projects/\(fx.project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fx.actorToken)
            } afterResponse: { res in
                let members = try res.content.decode(ProjectMemberController.ProjectMembersResponse.self)
                let entry = members.users.first { $0.userId == fx.internalUser.id }
                #expect(entry?.external == false)
            }
        }
    }

    @Test("A guardrail ceiling over iam:grantExternal refuses the external grant at write time")
    func guardrailCeilingRefusesExternalGrant() async throws {
        try await withApp { app, fx in
            _ = try await GuardrailStore.create(
                name: "no-external-grants", description: nil, effect: nil,
                node: IAMNode(type: .organization, id: fx.homeOrg.id!),
                actions: ["iam:grantExternal"], principalMatch: .any, resourceMatch: .any,
                createdBy: nil, on: app.db)
            let version = try await PolicySetVersionService.current(on: app.db)
            await app.cedarPolicySet.rebuild(version: version, on: app.db)

            try await app.test(.POST, "/api/projects/\(fx.project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fx.actorToken)
                try req.content.encode(
                    ProjectMemberController.GrantMemberRequest(
                        userEmail: fx.externalUser.email, userID: nil, role: "viewer"))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            let bindings = try await RoleBinding.query(on: app.db)
                .filter(\.$principalID == fx.externalUser.id!)
                .filter(\.$nodeID == fx.project.id!)
                .count()
            #expect(bindings == 0)
            let mirrors = try await ProjectMember.query(on: app.db)
                .filter(\.$user.$id == fx.externalUser.id!)
                .count()
            #expect(mirrors == 0)
            // The internal grant is untouched by the ceiling.
            try await app.test(.POST, "/api/projects/\(fx.project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fx.actorToken)
                try req.content.encode(
                    ProjectMemberController.GrantMemberRequest(
                        userEmail: fx.internalUser.email, userID: nil, role: "viewer"))
            } afterResponse: { res in
                #expect(res.status == .created)
            }
        }
    }

    @Test("A group from another org is grantable through the gate and marked in the list")
    func externalGroupGrantAllowedAndMarked() async throws {
        try await withApp { app, fx in
            try await app.test(.POST, "/api/projects/\(fx.project.id!)/groups") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fx.actorToken)
                try req.content.encode(
                    ProjectMemberController.GrantGroupRequest(
                        groupID: fx.externalGroup.id!, role: "viewer"))
            } afterResponse: { res in
                #expect(res.status == .created)
            }

            let bindings = try await RoleBinding.query(on: app.db)
                .filter(\.$principalType == IAMPrincipalType.group.rawValue)
                .filter(\.$principalID == fx.externalGroup.id!)
                .filter(\.$nodeID == fx.project.id!)
                .count()
            #expect(bindings == 1)

            let events = try await crossOrgAuditEvents(app, type: .crossOrgGrant)
            #expect(events.count == 1)
            #expect(events.first?.metadata?["principalType"] == "group")

            try await app.test(.GET, "/api/projects/\(fx.project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fx.actorToken)
            } afterResponse: { res in
                let members = try res.content.decode(ProjectMemberController.ProjectMembersResponse.self)
                let grant = members.groups.first { $0.groupId == fx.externalGroup.id }
                #expect(grant?.external == true)
            }
        }
    }

    @Test("Revoking an external principal's grant records the distinct revoke event")
    func revokeExternalIsLoud() async throws {
        try await withApp { app, fx in
            try await app.test(.POST, "/api/projects/\(fx.project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fx.actorToken)
                try req.content.encode(
                    ProjectMemberController.GrantMemberRequest(
                        userEmail: fx.externalUser.email, userID: nil, role: "viewer"))
            } afterResponse: { res in
                #expect(res.status == .created)
            }

            try await app.test(
                .DELETE, "/api/projects/\(fx.project.id!)/members/\(fx.externalUser.id!)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fx.actorToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let events = try await crossOrgAuditEvents(app, type: .crossOrgRevoke)
            #expect(events.count == 1)
            #expect(events.first?.metadata?["principalId"] == fx.externalUser.id!.uuidString)
        }
    }

    @Test("who-can marks principals from other orgs, and only those")
    func whoCanMarksExternal() async throws {
        try await withApp { app, fx in
            try await RoleBindingService.grant(
                principalType: .user, principalID: fx.externalUser.id!, role: .viewer,
                nodeType: .project, nodeID: fx.project.id!, createdBy: nil, on: app.db)
            try await RoleBindingService.grant(
                principalType: .user, principalID: fx.internalUser.id!, role: .viewer,
                nodeType: .project, nodeID: fx.project.id!, createdBy: nil, on: app.db)
            try await RoleBindingService.grant(
                principalType: .group, principalID: fx.externalGroup.id!, role: .viewer,
                nodeType: .project, nodeID: fx.project.id!, createdBy: nil, on: app.db)

            let result = try await WhoCanService.whoCan(
                action: "vm:read", node: IAMNode(type: .project, id: fx.project.id!), app: app, on: app.db)

            func entry(_ type: IAMPrincipalType, _ id: UUID) -> WhoCanEntry? {
                result.principals.first { $0.principal.type == type && $0.principal.id == id && $0.via == nil }
            }
            #expect(entry(.user, fx.externalUser.id!)?.principalExternalToOrg == true)
            #expect(entry(.user, fx.internalUser.id!)?.principalExternalToOrg == false)
            #expect(entry(.group, fx.externalGroup.id!)?.principalExternalToOrg == true)
        }
    }

    @Test("Removing an org member sweeps the org's subtree and nothing beyond it")
    func removeMemberSweepsSubtree() async throws {
        try await withApp { app, fx in
            let builder = TestDataBuilder(db: app.db)
            let user = fx.internalUser

            // Inside the home org: a project role (mirror row + binding) and a
            // group membership.
            try await app.test(.POST, "/api/projects/\(fx.project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fx.actorToken)
                try req.content.encode(
                    ProjectMemberController.GrantMemberRequest(
                        userEmail: user.email, userID: nil, role: "member"))
            } afterResponse: { res in
                #expect(res.status == .created)
            }
            let homeGroup = try await builder.createGroup(
                name: "XOrg Home Group", description: "d", organization: fx.homeOrg)
            try await UserGroup(userID: user.id!, groupID: homeGroup.id!).save(on: app.db)

            // Outside it: a cross-org binding on the other org's project —
            // that org's explicit grant, which this offboarding must not touch.
            let otherProject = try await builder.createProject(
                name: "XOrg Other Project", description: "d", organization: fx.otherOrg)
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .viewer,
                nodeType: .project, nodeID: otherProject.id!, createdBy: nil, on: app.db)

            try await app.test(
                .DELETE, "/api/organizations/\(fx.homeOrg.id!)/members/\(user.id!)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fx.actorToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let homeBindings = try await RoleBinding.query(on: app.db)
                .filter(\.$principalID == user.id!)
                .filter(\.$nodeID == fx.project.id!)
                .count()
            #expect(homeBindings == 0)
            let mirrors = try await ProjectMember.query(on: app.db)
                .filter(\.$user.$id == user.id!)
                .count()
            #expect(mirrors == 0)
            let groupMemberships = try await UserGroup.query(on: app.db)
                .filter(\.$user.$id == user.id!)
                .count()
            #expect(groupMemberships == 0)

            let otherBindings = try await RoleBinding.query(on: app.db)
                .filter(\.$principalID == user.id!)
                .filter(\.$nodeID == otherProject.id!)
                .count()
            #expect(otherBindings == 1)
        }
    }

    @Test("Deleting a user sweeps their bindings across every org")
    func userDeleteSweepsAllBindings() async throws {
        try await withApp { app, fx in
            let builder = TestDataBuilder(db: app.db)
            let sysadmin = try await builder.createUser(
                username: "xorg-sysadmin", email: "xorg-sysadmin@example.com", isSystemAdmin: true)
            let sysadminToken = try await sysadmin.generateAPIKey(on: app.db)

            let user = fx.externalUser
            let otherProject = try await builder.createProject(
                name: "XOrg Sweep Project", description: "d", organization: fx.otherOrg)
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .viewer,
                nodeType: .project, nodeID: fx.project.id!, createdBy: nil, on: app.db)
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .editor,
                nodeType: .project, nodeID: otherProject.id!, createdBy: nil, on: app.db)

            try await app.test(.DELETE, "/api/users/\(user.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: sysadminToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let remaining = try await RoleBinding.query(on: app.db)
                .filter(\.$principalType == IAMPrincipalType.user.rawValue)
                .filter(\.$principalID == user.id!)
                .count()
            #expect(remaining == 0)
        }
    }

    @Test("Deleting a group sweeps its bindings across every org")
    func groupDeleteSweepsBindings() async throws {
        try await withApp { app, fx in
            let builder = TestDataBuilder(db: app.db)
            // A group in the home org holding a binding at home and one on the
            // other org's project (a cross-org grant).
            let group = try await builder.createGroup(
                name: "XOrg Sweep Group", description: "d", organization: fx.homeOrg)
            let otherProject = try await builder.createProject(
                name: "XOrg Group Sweep Project", description: "d", organization: fx.otherOrg)
            try await RoleBindingService.grant(
                principalType: .group, principalID: group.id!, role: .viewer,
                nodeType: .project, nodeID: fx.project.id!, createdBy: nil, on: app.db)
            try await RoleBindingService.grant(
                principalType: .group, principalID: group.id!, role: .viewer,
                nodeType: .project, nodeID: otherProject.id!, createdBy: nil, on: app.db)

            try await app.test(
                .DELETE, "/api/organizations/\(fx.homeOrg.id!)/groups/\(group.id!)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fx.actorToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let remaining = try await RoleBinding.query(on: app.db)
                .filter(\.$principalType == IAMPrincipalType.group.rawValue)
                .filter(\.$principalID == group.id!)
                .count()
            #expect(remaining == 0)
        }
    }
}
