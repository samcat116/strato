import Testing
import Vapor
import Fluent
import VaporTesting
@testable import App

@Suite("OrganizationAccessService Tests", .serialized)
final class OrganizationAccessServiceTests {

    // Spin up a fresh app + database and a data builder for each test.
    func withAccessTestApp(_ test: (Application, TestDataBuilder) async throws -> Void) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()
            try await test(app, TestDataBuilder(db: app.db))
            try await app.autoRevert()
        } catch {
            try? await app.autoRevert()
            try await app.asyncShutdown()
            app.cleanupTestDatabase()
            throw error
        }

        try await app.asyncShutdown()
        app.cleanupTestDatabase()
    }

    /// Asserts that `operation` throws an `Abort` with the given status (and reason, if provided).
    private func expectAbort(
        _ status: HTTPResponseStatus,
        reason: String? = nil,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected Abort(\(status)) but no error was thrown")
        } catch let abort as Abort {
            #expect(abort.status == status)
            if let reason {
                #expect(abort.reason == reason)
            }
        } catch {
            Issue.record("Expected Abort, got \(error)")
        }
    }

    // MARK: - Organization membership

    @Test("requireMember allows a member and rejects a non-member")
    func testRequireMember() async throws {
        try await withAccessTestApp { app, builder in
            let org = try await builder.createOrganization()
            let member = try await builder.createUser(username: "m", email: "m@example.com")
            try await builder.addUserToOrganization(user: member, organization: org, role: "member")

            let outsider = try await builder.createUser(username: "o", email: "o@example.com")

            // Member: passes without throwing.
            try await OrganizationAccessService.requireMember(user: member, organizationID: org.id!, on: app.db)

            // Non-member: forbidden.
            await expectAbort(.forbidden, reason: "Not a member of this organization") {
                try await OrganizationAccessService.requireMember(user: outsider, organizationID: org.id!, on: app.db)
            }
        }
    }

    @Test("requireAdmin allows admins and rejects members and non-members")
    func testRequireAdmin() async throws {
        try await withAccessTestApp { app, builder in
            let org = try await builder.createOrganization()

            let admin = try await builder.createUser(username: "a", email: "a@example.com")
            try await builder.addUserToOrganization(user: admin, organization: org, role: "admin")

            let member = try await builder.createUser(username: "m", email: "m@example.com")
            try await builder.addUserToOrganization(user: member, organization: org, role: "member")

            let outsider = try await builder.createUser(username: "o", email: "o@example.com")

            // Admin: passes.
            try await OrganizationAccessService.requireAdmin(user: admin, organizationID: org.id!, on: app.db)

            // Member (non-admin): forbidden.
            await expectAbort(.forbidden, reason: "Admin access required") {
                try await OrganizationAccessService.requireAdmin(user: member, organizationID: org.id!, on: app.db)
            }

            // Non-member: forbidden.
            await expectAbort(.forbidden, reason: "Admin access required") {
                try await OrganizationAccessService.requireAdmin(user: outsider, organizationID: org.id!, on: app.db)
            }
        }
    }

    @Test("membership checks do not grant system admins implicit access")
    func testSystemAdminNotBypassed() async throws {
        // The membership-based checks intentionally do NOT bypass for system admins
        // (that behavior lives only in OIDCController's request-based variants).
        try await withAccessTestApp { app, builder in
            let org = try await builder.createOrganization()
            let sysAdmin = try await builder.createUser(
                username: "sys", email: "sys@example.com", isSystemAdmin: true
            )

            await expectAbort(.forbidden, reason: "Not a member of this organization") {
                try await OrganizationAccessService.requireMember(user: sysAdmin, organizationID: org.id!, on: app.db)
            }
        }
    }

    // MARK: - Project scope

    @Test("requireProjectMember resolves the root organization (project directly under org)")
    func testRequireProjectMemberDirectOrg() async throws {
        try await withAccessTestApp { app, builder in
            let org = try await builder.createOrganization()
            let project = try await builder.createProject(
                name: "P", description: "d", organization: org
            )

            let member = try await builder.createUser(username: "m", email: "m@example.com")
            try await builder.addUserToOrganization(user: member, organization: org, role: "member")
            let outsider = try await builder.createUser(username: "o", email: "o@example.com")

            try await OrganizationAccessService.requireProjectMember(user: member, project: project, on: app.db)

            await expectAbort(.forbidden, reason: "Not a member of this organization") {
                try await OrganizationAccessService.requireProjectMember(user: outsider, project: project, on: app.db)
            }
        }
    }

    @Test("requireProjectAdmin resolves the root organization through an OU")
    func testRequireProjectAdminViaOU() async throws {
        try await withAccessTestApp { app, builder in
            let org = try await builder.createOrganization()
            let ou = try await builder.createOU(name: "Eng", description: "d", organization: org)
            let project = try await builder.createProject(
                name: "P", description: "d", ou: ou
            )

            let admin = try await builder.createUser(username: "a", email: "a@example.com")
            try await builder.addUserToOrganization(user: admin, organization: org, role: "admin")

            let member = try await builder.createUser(username: "m", email: "m@example.com")
            try await builder.addUserToOrganization(user: member, organization: org, role: "member")

            // Admin of the root org (resolved via the OU) passes.
            try await OrganizationAccessService.requireProjectAdmin(user: admin, project: project, on: app.db)

            // Plain member is rejected.
            await expectAbort(.forbidden, reason: "Admin access required") {
                try await OrganizationAccessService.requireProjectAdmin(user: member, project: project, on: app.db)
            }
        }
    }
}
