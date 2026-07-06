import Testing
import Vapor
import Fluent
import VaporTesting
@testable import App

/// `OrganizationAccessService` now delegates to SpiceDB (via `Request.can`) instead of
/// reading the relational `UserOrganization.role`. These tests drive the verdict
/// through the mock SpiceDB (`spicedbMockAllows` / `spicedbMockDeniedResources`) and
/// assert the wrapper's behavior: the right resource is checked, the documented
/// `.forbidden` reason is thrown on denial, and system admins bypass.
@Suite("OrganizationAccessService Tests", .serialized)
final class OrganizationAccessServiceTests {

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

    /// Builds an authenticated `Request` so the static service methods can resolve the
    /// current user and the (mock) SpiceDB service.
    private func authedRequest(_ app: Application, user: User) -> Request {
        let req = Request(
            application: app,
            method: .GET,
            url: URI(path: "/"),
            on: app.eventLoopGroup.next()
        )
        req.auth.login(user)
        return req
    }

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

    // MARK: - Organization scope

    @Test("requireMember passes when SpiceDB grants and 403s when it withholds")
    func testRequireMember() async throws {
        try await withAccessTestApp { app, builder in
            let org = try await builder.createOrganization()
            let user = try await builder.createUser(username: "m", email: "m@example.com")
            let req = self.authedRequest(app, user: user)

            app.spicedbMockAllows = true
            try await OrganizationAccessService.requireMember(organizationID: org.id!, on: req)

            app.spicedbMockDeniedResources = ["organization"]
            await self.expectAbort(.forbidden, reason: "Not a member of this organization") {
                try await OrganizationAccessService.requireMember(organizationID: org.id!, on: req)
            }
        }
    }

    @Test("requireAdmin passes when SpiceDB grants and 403s when it withholds")
    func testRequireAdmin() async throws {
        try await withAccessTestApp { app, builder in
            let org = try await builder.createOrganization()
            let user = try await builder.createUser(username: "a", email: "a@example.com")
            let req = self.authedRequest(app, user: user)

            app.spicedbMockAllows = true
            try await OrganizationAccessService.requireAdmin(organizationID: org.id!, on: req)

            app.spicedbMockAllows = false
            await self.expectAbort(.forbidden, reason: "Admin access required") {
                try await OrganizationAccessService.requireAdmin(organizationID: org.id!, on: req)
            }
        }
    }

    @Test("system admins bypass the SpiceDB check")
    func testSystemAdminBypasses() async throws {
        // System admins bypass everywhere (Request.can returns true for them), so these
        // checks pass even when the mock denies all permissions.
        try await withAccessTestApp { app, builder in
            let org = try await builder.createOrganization()
            let sysAdmin = try await builder.createUser(
                username: "sys", email: "sys@example.com", isSystemAdmin: true
            )
            let req = self.authedRequest(app, user: sysAdmin)

            app.spicedbMockAllows = false
            try await OrganizationAccessService.requireMember(organizationID: org.id!, on: req)
            try await OrganizationAccessService.requireAdmin(organizationID: org.id!, on: req)
        }
    }

    // MARK: - Project scope

    @Test("requireProjectMember checks the project resource")
    func testRequireProjectMember() async throws {
        try await withAccessTestApp { app, builder in
            let org = try await builder.createOrganization()
            let project = try await builder.createProject(name: "P", description: "d", organization: org)
            let user = try await builder.createUser(username: "m", email: "m@example.com")
            let req = self.authedRequest(app, user: user)

            app.spicedbMockAllows = true
            try await OrganizationAccessService.requireProjectMember(project: project, on: req)

            // Deny only the project resource — the check must fail.
            app.spicedbMockDeniedResources = ["project"]
            await self.expectAbort(.forbidden, reason: "Not a member of this organization") {
                try await OrganizationAccessService.requireProjectMember(project: project, on: req)
            }
        }
    }

    @Test("requireProjectAdmin checks the project resource")
    func testRequireProjectAdmin() async throws {
        try await withAccessTestApp { app, builder in
            let org = try await builder.createOrganization()
            let project = try await builder.createProject(name: "P", description: "d", organization: org)
            let user = try await builder.createUser(username: "a", email: "a@example.com")
            let req = self.authedRequest(app, user: user)

            app.spicedbMockAllows = true
            try await OrganizationAccessService.requireProjectAdmin(project: project, on: req)

            app.spicedbMockAllows = false
            await self.expectAbort(.forbidden, reason: "Admin access required") {
                try await OrganizationAccessService.requireProjectAdmin(project: project, on: req)
            }
        }
    }
}
