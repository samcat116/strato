import Fluent
import Testing
import Vapor
import VaporTesting

@testable import App

/// The unified role vocabulary on org member endpoints (issue #608): legacy
/// `admin`/`member` keep their literal membership semantics and last-admin
/// guards, while IAM role names and org-owned role ids are additionally
/// accepted and scope-validated to the org. Member lists carry a display name.
@Suite("Organization Member Role Tests", .serialized)
final class OrganizationMemberRoleTests {

    private func withApp(
        _ test: (Application, Organization, User, String, User) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Role Org")
            let admin = try await builder.createUser(
                username: "roleadmin", email: "roleadmin@example.com", displayName: "Role Admin")
            try await builder.addUserToOrganization(user: admin, organization: org, role: "admin")
            let adminToken = try await admin.generateAPIKey(on: app.db)

            let target = try await builder.createUser(
                username: "roletarget", email: "roletarget@example.com", displayName: "Role Target")

            try await test(app, org, admin, adminToken, target)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private func makeRole(
        name: String, ownerType: IAMRoleOwnerType, ownerID: UUID, actions: [String], on db: Database
    ) async throws -> IAMRoleDefinition {
        let id = UUID()
        let role = IAMRoleDefinition(
            id: id, name: name, ownerType: ownerType, ownerID: ownerID,
            cedarText: RoleDescriptor.canonicalPermitText(id: id, actions: actions),
            actions: actions, managed: false)
        try await role.save(on: db)
        return role
    }

    private func membership(_ userID: UUID, _ orgID: UUID, on db: Database) async throws -> UserOrganization? {
        try await UserOrganization.query(on: db)
            .filter(\.$user.$id == userID)
            .filter(\.$organization.$id == orgID)
            .first()
    }

    private func orgBindings(_ userID: UUID, _ orgID: UUID, on db: Database) async throws -> [String] {
        try await RoleBinding.query(on: db)
            .filter(\.$principalType == IAMPrincipalType.user.rawValue)
            .filter(\.$principalID == userID)
            .filter(\.$nodeType == IAMNodeType.organization.rawValue)
            .filter(\.$nodeID == orgID)
            .all()
            .map(\.role)
    }

    @Test("Legacy 'member' stores the literal and binds nothing")
    func legacyMemberUnchanged() async throws {
        try await withApp { app, org, _, token, target in
            try await app.test(.POST, "/api/organizations/\(org.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["userEmail": target.email, "role": "member"])
            } afterResponse: { res in
                #expect(res.status == .created)
            }
            let m = try await membership(target.id!, org.id!, on: app.db)
            #expect(m?.role == "member")
            #expect(try await orgBindings(target.id!, org.id!, on: app.db).isEmpty)
        }
    }

    @Test("Legacy 'admin' stores the literal and binds admin")
    func legacyAdminUnchanged() async throws {
        try await withApp { app, org, _, token, target in
            try await app.test(.POST, "/api/organizations/\(org.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["userEmail": target.email, "role": "admin"])
            } afterResponse: { res in
                #expect(res.status == .created)
            }
            let m = try await membership(target.id!, org.id!, on: app.db)
            #expect(m?.role == "admin")
            #expect(try await orgBindings(target.id!, org.id!, on: app.db) == [IAMRole.admin.seededID.uuidString])
        }
    }

    @Test("An IAM role name stores the seeded id and binds it")
    func iamRoleName() async throws {
        try await withApp { app, org, _, token, target in
            try await app.test(.POST, "/api/organizations/\(org.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["userEmail": target.email, "role": "editor"])
            } afterResponse: { res in
                #expect(res.status == .created)
            }
            let m = try await membership(target.id!, org.id!, on: app.db)
            #expect(m?.role == IAMRole.editor.seededID.uuidString)
            #expect(try await orgBindings(target.id!, org.id!, on: app.db) == [IAMRole.editor.seededID.uuidString])
        }
    }

    @Test("The seeded admin role id is stored as the literal 'admin'")
    func seededAdminIdNormalizesToLiteral() async throws {
        try await withApp { app, org, _, token, target in
            // Granting admin by its well-known id must land the same membership
            // semantics as the literal "admin", so the last-admin guards — which
            // key on that literal — still count this member (issue #608 review).
            try await app.test(.POST, "/api/organizations/\(org.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["userEmail": target.email, "role": IAMRole.admin.seededID.uuidString])
            } afterResponse: { res in
                #expect(res.status == .created)
            }
            let m = try await membership(target.id!, org.id!, on: app.db)
            #expect(m?.role == "admin")
            #expect(try await orgBindings(target.id!, org.id!, on: app.db) == [IAMRole.admin.seededID.uuidString])

            // With two admins now, the literal-admin caller can be demoted — the
            // by-id admin counts, so this is no longer the last admin.
            try await app.test(.GET, "/api/organizations/\(org.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                let body = try res.content.decode([OrganizationMemberResponse].self)
                #expect(body.filter { $0.role == "admin" }.count == 2)
            }
        }
    }

    @Test("An in-scope org-owned role UUID binds that role")
    func orgOwnedRoleUUIDInScope() async throws {
        try await withApp { app, org, _, token, target in
            let role = try await makeRole(
                name: "auditor", ownerType: .organization, ownerID: org.id!,
                actions: ["vm:read"], on: app.db)
            try await app.test(.POST, "/api/organizations/\(org.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["userEmail": target.email, "role": role.id!.uuidString])
            } afterResponse: { res in
                #expect(res.status == .created)
            }
            let m = try await membership(target.id!, org.id!, on: app.db)
            #expect(m?.role == role.id!.uuidString)
            #expect(try await orgBindings(target.id!, org.id!, on: app.db) == [role.id!.uuidString])
        }
    }

    @Test("A role owned by another org is a 400 naming the mismatch")
    func foreignRoleUUIDOutOfScope() async throws {
        try await withApp { app, org, _, token, target in
            let otherOrg = try await TestDataBuilder(db: app.db).createOrganization(name: "Foreign Org")
            let role = try await makeRole(
                name: "foreign", ownerType: .organization, ownerID: otherOrg.id!,
                actions: ["vm:read"], on: app.db)
            try await app.test(.POST, "/api/organizations/\(org.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["userEmail": target.email, "role": role.id!.uuidString])
            } afterResponse: { res in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("not in the hierarchy"))
            }
            #expect(try await membership(target.id!, org.id!, on: app.db) == nil)
        }
    }

    @Test("Member list carries a role display name")
    func memberListDisplayName() async throws {
        try await withApp { app, org, _, token, target in
            try await app.test(.POST, "/api/organizations/\(org.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["userEmail": target.email, "role": "editor"])
            } afterResponse: { res in
                #expect(res.status == .created)
            }
            try await app.test(.GET, "/api/organizations/\(org.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = try res.content.decode([OrganizationMemberResponse].self)
                let m = try #require(body.first { $0.id == target.id })
                #expect(m.role == IAMRole.editor.seededID.uuidString)
                #expect(m.roleDisplayName == "editor")
                // The legacy-literal admin caller displays verbatim.
                let adminRow = try #require(body.first { $0.role == "admin" })
                #expect(adminRow.roleDisplayName == "admin")
            }
        }
    }

    @Test("The last-admin guard stays keyed on the literal 'admin'")
    func lastAdminGuardKeyedOnLiteral() async throws {
        try await withApp { app, org, admin, token, _ in
            // The admin caller is the only literal admin; moving them off admin
            // is refused whether the target role is a bare member or a role id.
            try await app.test(.PATCH, "/api/organizations/\(org.id!)/members/\(admin.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["role": "editor"])
            } afterResponse: { res in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("last admin"))
            }
        }
    }

    @Test("updateMemberRole swaps bindings across legacy and id formats")
    func updateAcrossStoredFormats() async throws {
        try await withApp { app, org, _, token, target in
            let builder = TestDataBuilder(db: app.db)
            // A second literal admin, so the last-admin guard does not fire when
            // we move `target` off admin.
            try await builder.addUserToOrganization(user: target, organization: org, role: "admin")
            #expect(try await orgBindings(target.id!, org.id!, on: app.db) == [IAMRole.admin.seededID.uuidString])

            try await app.test(.PATCH, "/api/organizations/\(org.id!)/members/\(target.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["role": "editor"])
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            // Admin binding revoked, editor binding granted, literal replaced by id.
            let m = try await membership(target.id!, org.id!, on: app.db)
            #expect(m?.role == IAMRole.editor.seededID.uuidString)
            #expect(try await orgBindings(target.id!, org.id!, on: app.db) == [IAMRole.editor.seededID.uuidString])
        }
    }
}
