import Fluent
import Testing
import Vapor
import VaporTesting

@testable import App

/// Covers folder-level role grants (STR-109): the write path for the binding
/// scope the evaluator has always honored but no endpoint could author.
///
/// Two properties matter beyond the CRUD mechanics — that a folder grant
/// actually inherits down to the projects beneath it (the delegation the whole
/// feature exists for), and that it is gated on `iam:setPolicy` rather than on
/// anything a folder editor holds.
@Suite("Folder Member Tests", .serialized)
struct FolderMemberTests {

    /// An org with an `engineering` folder holding one project, a sibling
    /// `research` folder holding another, an org-admin actor, and a grant
    /// target. The shape the issue's E2E used.
    private struct Fixture {
        let org: Organization
        let engineering: OrganizationalUnit
        let research: OrganizationalUnit
        let engineeringProject: Project
        let researchProject: Project
        let actor: User
        let actorToken: String
        let target: User
        let group: Group
        let builder: TestDataBuilder
    }

    private func withFixture(_ test: (Application, Fixture) async throws -> Void) async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Folder Grants Org")

            let actor = try await builder.createUser(
                username: "fmactor", email: "fmactor@example.com", displayName: "FM Actor")
            try await builder.addUserToOrganization(user: actor, organization: org, role: "admin")
            actor.currentOrganizationId = org.id
            try await actor.save(on: app.db)

            // A colleague in the same org: the ordinary grant target, and not
            // external, so the cross-org markers stay meaningful.
            let target = try await builder.createUser(
                username: "fmtarget", email: "fmtarget@example.com", displayName: "FM Target")
            try await builder.addUserToOrganization(user: target, organization: org, role: "member")

            let engineering = try await builder.createOU(
                name: "engineering", description: "d", organization: org)
            let research = try await builder.createOU(
                name: "research", description: "d", organization: org)

            let fixture = Fixture(
                org: org,
                engineering: engineering,
                research: research,
                engineeringProject: try await builder.createProject(
                    name: "web-prod", description: "d", ou: engineering),
                researchProject: try await builder.createProject(
                    name: "lab", description: "d", ou: research),
                actor: actor,
                actorToken: try await actor.generateAPIKey(on: app.db),
                target: target,
                group: try await builder.createGroup(
                    name: "FM Group", description: "d", organization: org),
                builder: builder
            )

            try await test(app, fixture)
        }
    }

    private func membersPath(_ fixture: Fixture) throws -> String {
        "/api/organizations/\(try fixture.org.requireID())/ous/\(try fixture.engineering.requireID())/members"
    }

    private func groupsPath(_ fixture: Fixture) throws -> String {
        "/api/organizations/\(try fixture.org.requireID())/ous/\(try fixture.engineering.requireID())/groups"
    }

    /// The role ids bound to `principal` on the engineering folder.
    private func folderRoles(
        _ fixture: Fixture, principalType: IAMPrincipalType, principalID: UUID, on db: any Database
    ) async throws -> [String] {
        try await RoleBinding.query(on: db)
            .filter(\.$principalType == principalType.rawValue)
            .filter(\.$principalID == principalID)
            .filter(\.$nodeType == IAMNodeType.organizationalUnit.rawValue)
            .filter(\.$nodeID == fixture.engineering.requireID())
            .all()
            .map(\.role)
    }

    // MARK: - Grants

    @Test("Granting a user a folder role writes a binding on the folder node")
    func grantWritesFolderBinding() async throws {
        try await withFixture { app, fixture in
            let path = try membersPath(fixture)
            try await app.test(.POST, path) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.actorToken)
                try req.content.encode(
                    OrganizationalUnitMemberController.GrantMemberRequest(
                        userEmail: fixture.target.email, userID: nil, role: "admin"))
            } afterResponse: { res in
                #expect(res.status == .created)
            }

            let roles = try await folderRoles(
                fixture, principalType: .user, principalID: try fixture.target.requireID(), on: app.db)
            #expect(roles == [IAMRole.admin.seededID.uuidString])
        }
    }

    @Test("A folder grant inherits to projects beneath it and stops at the sibling folder")
    func folderGrantInheritsDownAndContains() async throws {
        try await withFixture { app, fixture in
            let path = try membersPath(fixture)
            try await app.test(.POST, path) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.actorToken)
                try req.content.encode(
                    OrganizationalUnitMemberController.GrantMemberRequest(
                        userEmail: fixture.target.email, userID: nil, role: "viewer"))
            } afterResponse: { res in
                #expect(res.status == .created)
            }

            let targetToken = try await fixture.target.generateAPIKey(on: app.db)

            // The project under `engineering` is reachable...
            try await app.test(.GET, "/api/projects/\(try fixture.engineeringProject.requireID())") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: targetToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            // ...and the one under the sibling folder is not: the grant is
            // contained by the folder it was written on.
            try await app.test(.GET, "/api/projects/\(try fixture.researchProject.requireID())") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: targetToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden || res.status == .notFound)
            }
        }
    }

    @Test("A second grant for the same user is a conflict")
    func secondGrantConflicts() async throws {
        try await withFixture { app, fixture in
            let path = try membersPath(fixture)
            try await RoleBindingService.grant(
                principalType: .user, principalID: try fixture.target.requireID(), role: .viewer,
                nodeType: .organizationalUnit, nodeID: try fixture.engineering.requireID(),
                createdBy: nil, on: app.db)

            try await app.test(.POST, path) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.actorToken)
                try req.content.encode(
                    OrganizationalUnitMemberController.GrantMemberRequest(
                        userEmail: fixture.target.email, userID: nil, role: "editor"))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("Changing a role leaves exactly one binding on the folder")
    func patchReplacesGrant() async throws {
        try await withFixture { app, fixture in
            let targetID = try fixture.target.requireID()
            try await RoleBindingService.grant(
                principalType: .user, principalID: targetID, role: .viewer,
                nodeType: .organizationalUnit, nodeID: try fixture.engineering.requireID(),
                createdBy: nil, on: app.db)

            let path = try membersPath(fixture)
            try await app.test(.PATCH, "\(path)/\(targetID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.actorToken)
                try req.content.encode(
                    OrganizationalUnitMemberController.UpdateMemberRoleRequest(role: "admin"))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            let roles = try await folderRoles(
                fixture, principalType: .user, principalID: targetID, on: app.db)
            #expect(roles == [IAMRole.admin.seededID.uuidString])
        }
    }

    @Test("Changing the role of a user who holds none on the folder is a 404")
    func patchWithoutGrantIsNotFound() async throws {
        try await withFixture { app, fixture in
            let path = try membersPath(fixture)
            try await app.test(.PATCH, "\(path)/\(try fixture.target.requireID())") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.actorToken)
                try req.content.encode(
                    OrganizationalUnitMemberController.UpdateMemberRoleRequest(role: "admin"))
            } afterResponse: { res in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("Revoking removes the folder binding")
    func revokeRemovesBinding() async throws {
        try await withFixture { app, fixture in
            let targetID = try fixture.target.requireID()
            try await RoleBindingService.grant(
                principalType: .user, principalID: targetID, role: .editor,
                nodeType: .organizationalUnit, nodeID: try fixture.engineering.requireID(),
                createdBy: nil, on: app.db)

            let path = try membersPath(fixture)
            try await app.test(.DELETE, "\(path)/\(targetID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.actorToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let roles = try await folderRoles(
                fixture, principalType: .user, principalID: targetID, on: app.db)
            #expect(roles.isEmpty)
        }
    }

    @Test("Granting and revoking a group writes and removes a group binding")
    func groupGrantRoundTrips() async throws {
        try await withFixture { app, fixture in
            let groupID = try fixture.group.requireID()
            let path = try groupsPath(fixture)

            try await app.test(.POST, path) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.actorToken)
                try req.content.encode(
                    OrganizationalUnitMemberController.GrantGroupRequest(groupID: groupID, role: "editor"))
            } afterResponse: { res in
                #expect(res.status == .created)
            }

            let granted = try await folderRoles(
                fixture, principalType: .group, principalID: groupID, on: app.db)
            #expect(granted == [IAMRole.editor.seededID.uuidString])

            try await app.test(.DELETE, "\(path)/\(groupID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.actorToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let revoked = try await folderRoles(
                fixture, principalType: .group, principalID: groupID, on: app.db)
            #expect(revoked.isEmpty)
        }
    }

    // MARK: - Listing

    @Test("Listing returns the folder's grants, with role names and cross-org markers")
    func listReturnsGrants() async throws {
        try await withFixture { app, fixture in
            let targetID = try fixture.target.requireID()
            let groupID = try fixture.group.requireID()
            let folderID = try fixture.engineering.requireID()
            // A user with no membership in the folder's org: listed, flagged,
            // never filtered out (issue #485).
            let outsider = try await fixture.builder.createUser(
                username: "fm-external", email: "fm-external@example.com")
            let outsiderID = try outsider.requireID()

            try await RoleBindingService.grant(
                principalType: .user, principalID: targetID, role: .admin,
                nodeType: .organizationalUnit, nodeID: folderID, createdBy: nil, on: app.db)
            try await RoleBindingService.grant(
                principalType: .user, principalID: outsiderID, role: .viewer,
                nodeType: .organizationalUnit, nodeID: folderID, createdBy: nil, on: app.db)
            try await RoleBindingService.grant(
                principalType: .group, principalID: groupID, role: .viewer,
                nodeType: .organizationalUnit, nodeID: folderID, createdBy: nil, on: app.db)

            try await app.test(.GET, try membersPath(fixture)) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.actorToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(
                    OrganizationalUnitMemberController.FolderMembersResponse.self)
                let member = try #require(body.users.first { $0.userId == targetID })
                #expect(member.role == IAMRole.admin.seededID.uuidString)
                #expect(member.roleDisplayName == "admin")
                #expect(member.external == false)

                let external = try #require(body.users.first { $0.userId == outsiderID })
                #expect(external.external == true)

                let grant = try #require(body.groups.first { $0.groupId == groupID })
                #expect(grant.role == IAMRole.viewer.seededID.uuidString)
                #expect(grant.roleDisplayName == "viewer")
                #expect(grant.external == false)
            }
        }
    }

    // MARK: - Gating

    @Test("Writing a grant requires iam:setPolicy on the folder")
    func grantRequiresSetPolicy() async throws {
        try await withFixture { app, fixture in
            // An editor on the folder can read it and everything under it, but
            // holds no iam:setPolicy — so it cannot hand out access.
            let editor = try await fixture.builder.createUser(
                username: "fm-editor", email: "fm-editor@example.com")
            try await RoleBindingService.grant(
                principalType: .user, principalID: try editor.requireID(), role: .editor,
                nodeType: .organizationalUnit, nodeID: try fixture.engineering.requireID(),
                createdBy: nil, on: app.db)
            let editorToken = try await editor.generateAPIKey(on: app.db)

            try await app.test(.POST, try membersPath(fixture)) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: editorToken)
                try req.content.encode(
                    OrganizationalUnitMemberController.GrantMemberRequest(
                        userEmail: fixture.target.email, userID: nil, role: "viewer"))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("Listing grants requires iam:readPolicy on the folder")
    func listRequiresReadPolicy() async throws {
        try await withFixture { app, fixture in
            let outsider = try await fixture.builder.createUser(
                username: "fm-outsider", email: "fm-outsider@example.com")
            let outsiderToken = try await outsider.generateAPIKey(on: app.db)

            try await app.test(.GET, try membersPath(fixture)) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: outsiderToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("A folder in another organization is rejected on the path")
    func folderMustBelongToPathOrganization() async throws {
        try await withFixture { app, fixture in
            let otherOrg = try await fixture.builder.createOrganization(name: "Other Org")
            let path =
                "/api/organizations/\(try otherOrg.requireID())"
                + "/ous/\(try fixture.engineering.requireID())/members"

            try await app.test(.GET, path) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.actorToken)
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("A role owned outside the folder's hierarchy is a 400 naming the mismatch")
    func grantByOutOfScopeRoleUUID() async throws {
        try await withFixture { app, fixture in
            let otherOrg = try await fixture.builder.createOrganization(name: "Role Owner Org")
            let roleID = UUID()
            let role = IAMRoleDefinition(
                id: roleID,
                name: "foreign",
                ownerType: .organization,
                ownerID: try otherOrg.requireID(),
                cedarText: RoleDescriptor.canonicalPermitText(id: roleID, actions: ["vm:read"]),
                actions: ["vm:read"],
                managed: false
            )
            try await role.save(on: app.db)

            try await app.test(.POST, try membersPath(fixture)) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.actorToken)
                try req.content.encode(
                    OrganizationalUnitMemberController.GrantMemberRequest(
                        userEmail: fixture.target.email, userID: nil, role: roleID.uuidString))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("not in the hierarchy"))
            }

            let roles = try await folderRoles(
                fixture, principalType: .user, principalID: try fixture.target.requireID(), on: app.db)
            #expect(roles.isEmpty)
        }
    }

    @Test("Deleting a folder takes its grants with it")
    func deletingFolderRevokesItsBindings() async throws {
        try await withFixture { app, fixture in
            // An empty folder: deletion refuses while projects or children hang
            // off it, so the grant under test goes on `research`'s sibling.
            let empty = try await fixture.builder.createOU(
                name: "empty", description: "d", organization: fixture.org)
            let emptyID = try empty.requireID()
            try await RoleBindingService.grant(
                principalType: .user, principalID: try fixture.target.requireID(), role: .admin,
                nodeType: .organizationalUnit, nodeID: emptyID, createdBy: nil, on: app.db)

            try await app.test(
                .DELETE, "/api/organizations/\(try fixture.org.requireID())/ous/\(emptyID)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.actorToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let remaining = try await RoleBinding.query(on: app.db)
                .filter(\.$nodeType == IAMNodeType.organizationalUnit.rawValue)
                .filter(\.$nodeID == emptyID)
                .count()
            #expect(remaining == 0)
        }
    }
}
