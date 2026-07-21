import Fluent
import Testing
import Vapor
import VaporTesting

@testable import App

/// Pins the issue #482 pre-cutover audit decision for org member management:
/// `addMember` / `removeMember` / `updateMemberRole` / `getMembers` authorize
/// through SpiceDB (`OrganizationAccessService`), not through inline
/// `UserOrganization.role` reads — so the decisions are shadow-evaluated and
/// map to `org:update` / `org:read` at the Cedar cutover, and system admins
/// bypass like everywhere else in the API.
@Suite("Organization Member Authorization Tests", .serialized)
final class OrganizationMemberAuthzTests {

    private func withMemberAuthzApp(
        _ test: (Application, Organization, User, String, User) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Authz Org")

            let caller = try await builder.createUser(
                username: "authzcaller",
                email: "authzcaller@example.com",
                displayName: "Authz Caller",
                isSystemAdmin: false
            )
            try await builder.addUserToOrganization(user: caller, organization: org, role: "member")
            let callerToken = try await caller.generateAPIKey(on: app.db)

            let target = try await builder.createUser(
                username: "authztarget",
                email: "authztarget@example.com",
                displayName: "Authz Target",
                isSystemAdmin: false
            )

            try await test(app, org, caller, callerToken, target)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    @Test("Member management 403s when SpiceDB withholds org admin")
    func memberManagementRequiresSpiceDBAdmin() async throws {
        try await withMemberAuthzApp { app, org, _, callerToken, target in
            // The mock default-allows; withholding `manage_members` models a
            // caller without org admin, regardless of the relational role row.
            app.spicedbMockDeniedPermissions = ["manage_members"]

            try await app.test(.POST, "/api/organizations/\(org.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: callerToken)
                try req.content.encode(["userEmail": target.email, "role": "member"])
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            try await app.test(.DELETE, "/api/organizations/\(org.id!)/members/\(target.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: callerToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            try await app.test(.PATCH, "/api/organizations/\(org.id!)/members/\(target.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: callerToken)
                try req.content.encode(["role": "admin"])
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("Member list 403s for a caller outside the organization")
    func memberListRequiresSpiceDBMembership() async throws {
        try await withMemberAuthzApp { app, org, _, _, _ in
            // Not a member of the org: no membership-derived org:read, no
            // binding — the evaluator denies the member list.
            let outsider = try await TestDataBuilder(db: app.db).createUser(
                username: "authz-outsider", email: "authz-outsider@example.com")
            let outsiderToken = try await outsider.generateAPIKey(on: app.db)

            try await app.test(.GET, "/api/organizations/\(org.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: outsiderToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("System admins manage members even when SpiceDB denies everything")
    func systemAdminBypassesMemberManagement() async throws {
        // Pins the platform-bypass semantics these routes gain by going
        // through `req.can` — the tier-1 `platform-system-admin` policy at
        // cutover.
        try await withMemberAuthzApp { app, org, _, _, target in
            let builder = TestDataBuilder(db: app.db)
            let sysAdmin = try await builder.createUser(
                username: "authzsysadmin",
                email: "authzsysadmin@example.com",
                displayName: "Authz Sysadmin",
                isSystemAdmin: true
            )
            let sysAdminToken = try await sysAdmin.generateAPIKey(on: app.db)

            app.spicedbMockAllows = false

            try await app.test(.POST, "/api/organizations/\(org.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: sysAdminToken)
                try req.content.encode(["userEmail": target.email, "role": "member"])
            } afterResponse: { res in
                #expect(res.status == .created)
            }
        }
    }
}
