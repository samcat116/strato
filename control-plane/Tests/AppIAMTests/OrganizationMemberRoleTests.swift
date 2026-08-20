import AppTestSupport
import ControlPlanePostgres
import Fluent
import Testing
import Vapor
import VaporTesting

@testable import App

/// Organization membership remains relational so it can exist without a
/// grant. Any role attached to that membership is a canonical UUID and its
/// binding is the sole authorization representation.
@Suite("Organization Member Role Tests", .serialized)
final class OrganizationMemberRoleTests {
    private struct AddRequest: Content {
        let userEmail: String
        let role: UUID?
    }

    private struct UpdateRequest: Content {
        let role: UUID?
    }

    private struct InvalidRoleRequest: Content {
        let userEmail: String
        let role: String
    }

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
            let token = try await admin.generateAPIKey(on: app)
            let target = try await builder.createUser(
                username: "roletarget", email: "roletarget@example.com", displayName: "Role Target")
            try await test(app, org, admin, token, target)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private func makeRole(
        name: String, organizationID: UUID, actions: [String] = ["vm:read"], on db: Database
    ) async throws -> LegacyIAMRoleRecord {
        let id = UUID()
        return try await RoleStore.insertLegacy(IAMRoleSnapshot(
            id: id, name: name, description: nil,
            ownerType: IAMRoleOwnerType.organization.rawValue, ownerID: organizationID,
            cedarText: RoleDescriptor.canonicalPermitText(id: id, actions: actions),
            actions: actions, managed: false, createdBy: nil), on: db)
    }

    private func membership(_ userID: UUID, _ orgID: UUID, on db: Database) async throws
        -> LegacyOrganizationMembershipRecord?
    {
        try await OrganizationMembershipStore.membership(
            userID: userID, organizationID: orgID, on: db)
    }

    private func orgBindings(_ userID: UUID, _ orgID: UUID, on db: Database) async throws -> [UUID] {
        try await LegacyRoleBindingStore.bindings(
            principalType: IAMPrincipalType.user.rawValue,
            principalID: userID,
            nodeType: IAMNodeType.organization.rawValue,
            nodeID: orgID,
            on: db)
            .map(\.roleID)
    }

    @Test("Bare membership stores no role UUID and creates no binding")
    func bareMembership() async throws {
        try await withApp { app, org, _, token, target in
            try await app.test(.POST, "/api/organizations/\(org.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(AddRequest(userEmail: target.email, role: nil))
            } afterResponse: { res in
                #expect(res.status == .created)
            }
            #expect(try await membership(target.id!, org.id!, on: app.db)?.roleID == nil)
            #expect(try await orgBindings(target.id!, org.id!, on: app.db).isEmpty)
        }
    }

    @Test("A role name is rejected at the UUID-only request boundary")
    func roleNameRejected() async throws {
        try await withApp { app, org, _, token, target in
            try await app.test(.POST, "/api/organizations/\(org.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(InvalidRoleRequest(userEmail: target.email, role: "admin"))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
            #expect(try await membership(target.id!, org.id!, on: app.db) == nil)
        }
    }

    @Test("The seeded admin UUID is stored and bound without normalization")
    func seededAdminUUID() async throws {
        try await withApp { app, org, _, token, target in
            try await app.test(.POST, "/api/organizations/\(org.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(AddRequest(userEmail: target.email, role: IAMRole.admin.seededID))
            } afterResponse: { res in
                #expect(res.status == .created)
            }
            #expect(try await membership(target.id!, org.id!, on: app.db)?.roleID == IAMRole.admin.seededID)
            #expect(try await orgBindings(target.id!, org.id!, on: app.db) == [IAMRole.admin.seededID])
        }
    }

    @Test("An org-owned role UUID is stored and bound")
    func customRoleUUID() async throws {
        try await withApp { app, org, _, token, target in
            let role = try await makeRole(name: "auditor", organizationID: org.id!, on: app.db)
            try await app.test(.POST, "/api/organizations/\(org.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(AddRequest(userEmail: target.email, role: role.id))
            } afterResponse: { res in
                #expect(res.status == .created)
            }
            #expect(try await membership(target.id!, org.id!, on: app.db)?.roleID == role.id)
            #expect(try await orgBindings(target.id!, org.id!, on: app.db) == [role.id])
        }
    }

    @Test("A role owned by another organization is rejected")
    func foreignRoleUUID() async throws {
        try await withApp { app, org, _, token, target in
            let otherOrg = try await TestDataBuilder(db: app.db).createOrganization(name: "Foreign Org")
            let role = try await makeRole(name: "foreign", organizationID: otherOrg.id!, on: app.db)
            try await app.test(.POST, "/api/organizations/\(org.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(AddRequest(userEmail: target.email, role: role.id))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
            #expect(try await membership(target.id!, org.id!, on: app.db) == nil)
        }
    }

    @Test("Member list returns canonical ids and display names")
    func memberListDisplayName() async throws {
        try await withApp { app, org, _, token, target in
            try await app.test(.POST, "/api/organizations/\(org.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(AddRequest(userEmail: target.email, role: IAMRole.editor.seededID))
            } afterResponse: { res in
                #expect(res.status == .created)
            }
            try await app.test(.GET, "/api/organizations/\(org.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = try res.content.decode([OrganizationMemberResponse].self)
                let member = try #require(body.first { $0.id == target.id })
                #expect(member.role == IAMRole.editor.seededID)
                #expect(member.roleDisplayName == "editor")
            }
        }
    }

    @Test("The last seeded-admin binding cannot be replaced")
    func lastAdminGuard() async throws {
        try await withApp { app, org, admin, token, _ in
            try await app.test(.PATCH, "/api/organizations/\(org.id!)/members/\(admin.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateRequest(role: IAMRole.editor.seededID))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("last admin"))
            }
        }
    }

    @Test("Updating a member replaces the authoritative binding and role metadata")
    func updateRole() async throws {
        try await withApp { app, org, _, token, target in
            let builder = TestDataBuilder(db: app.db)
            try await builder.addUserToOrganization(user: target, organization: org, role: "admin")

            try await app.test(.PATCH, "/api/organizations/\(org.id!)/members/\(target.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateRequest(role: IAMRole.editor.seededID))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            #expect(try await membership(target.id!, org.id!, on: app.db)?.roleID == IAMRole.editor.seededID)
            #expect(try await orgBindings(target.id!, org.id!, on: app.db) == [IAMRole.editor.seededID])
        }
    }

    @Test("Concurrent admin demotions leave one administrator")
    func concurrentAdminDemotions() async throws {
        try await withApp { app, org, admin, token, target in
            try await TestDataBuilder(db: app.db).addUserToOrganization(
                user: target, organization: org, role: "admin")

            let organizationID = try org.requireID()
            let userIDs = [try admin.requireID(), try target.requireID()]
            let statuses = await withTaskGroup(of: HTTPStatus?.self) { group in
                for userID in userIDs {
                    group.addTask {
                        var status: HTTPStatus?
                        _ = try? await app.test(
                            .PATCH, "/api/organizations/\(organizationID)/members/\(userID)"
                        ) { req in
                            req.headers.bearerAuthorization = BearerAuthorization(token: token)
                            try req.content.encode(UpdateRequest(role: nil))
                        } afterResponse: { res in
                            status = res.status
                        }
                        return status
                    }
                }
                return await group.reduce(into: [HTTPStatus]()) { result, status in
                    if let status { result.append(status) }
                }
            }

            #expect(statuses.filter { $0 == .ok }.count == 1)
            #expect(statuses.filter { $0 == .badRequest }.count == 1)

            let adminBindings = try await LegacyRoleBindingStore.bindings(
                principalType: IAMPrincipalType.user.rawValue,
                roleID: IAMRole.admin.seededID,
                nodeType: IAMNodeType.organization.rawValue,
                nodeID: organizationID,
                activeAt: Date(),
                on: app.db).count
            #expect(adminBindings == 1)

            let adminMemberships = try await OrganizationMembershipStore.memberships(
                organizationID: organizationID, on: app.db
            ).filter { $0.roleID == IAMRole.admin.seededID }.count
            #expect(adminMemberships == 1)
        }
    }
}
