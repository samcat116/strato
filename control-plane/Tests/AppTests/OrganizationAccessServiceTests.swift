import Testing
import Vapor
import Fluent
import VaporTesting
@testable import App

/// `OrganizationAccessService` delegates to `Request.can`, which since cutover
/// (#482) is the Cedar evaluator answering from memberships and
/// `role_bindings`. These tests assert the wrapper's behavior: the right check
/// is made, the documented `.forbidden` reason is thrown on denial, and
/// system admins are allowed through the platform policy.
@Suite("OrganizationAccessService Tests", .serialized)
final class OrganizationAccessServiceTests {

    func withAccessTestApp(_ test: (Application, TestDataBuilder) async throws -> Void) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()
            try await test(app, TestDataBuilder(db: app.db))
        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
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

    @Test("requireMember passes for a member and 403s for an outsider")
    func testRequireMember() async throws {
        try await withAccessTestApp { app, builder in
            let org = try await builder.createOrganization()
            let member = try await builder.createUser(username: "m", email: "m@example.com")
            try await builder.addUserToOrganization(user: member, organization: org, role: "member")
            try await OrganizationAccessService.requireMember(
                organizationID: org.id!, on: self.authedRequest(app, user: member))

            let outsider = try await builder.createUser(username: "m2", email: "m2@example.com")
            await self.expectAbort(.forbidden, reason: "Not a member of this organization") {
                try await OrganizationAccessService.requireMember(
                    organizationID: org.id!, on: self.authedRequest(app, user: outsider))
            }
        }
    }

    @Test("requireAdmin passes for an org admin and 403s for a bare member")
    func testRequireAdmin() async throws {
        try await withAccessTestApp { app, builder in
            let org = try await builder.createOrganization()
            let admin = try await builder.createUser(username: "a", email: "a@example.com")
            try await builder.addUserToOrganization(user: admin, organization: org, role: "admin")
            try await OrganizationAccessService.requireAdmin(
                organizationID: org.id!, on: self.authedRequest(app, user: admin))

            let member = try await builder.createUser(username: "a2", email: "a2@example.com")
            try await builder.addUserToOrganization(user: member, organization: org, role: "member")
            await self.expectAbort(.forbidden, reason: "Admin access required") {
                try await OrganizationAccessService.requireAdmin(
                    organizationID: org.id!, on: self.authedRequest(app, user: member))
            }
        }
    }

    @Test("system admins are allowed through the platform-system-admin policy")
    func testSystemAdminBypasses() async throws {
        // No membership, no bindings — the evaluator's tier-1 policy is what
        // permits these.
        try await withAccessTestApp { app, builder in
            let org = try await builder.createOrganization()
            let sysAdmin = try await builder.createUser(
                username: "sys", email: "sys@example.com", isSystemAdmin: true
            )
            let req = self.authedRequest(app, user: sysAdmin)

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

            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .viewer,
                nodeType: .project, nodeID: project.id!, createdBy: nil, on: app.db)
            try await OrganizationAccessService.requireProjectMember(project: project, on: req)

            // A user with no binding anywhere — the check must fail.
            let outsider = try await builder.createUser(username: "m3", email: "m3@example.com")
            await self.expectAbort(.forbidden, reason: "Not a member of this organization") {
                try await OrganizationAccessService.requireProjectMember(
                    project: project, on: self.authedRequest(app, user: outsider))
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

            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .admin,
                nodeType: .project, nodeID: project.id!, createdBy: nil, on: app.db)
            try await OrganizationAccessService.requireProjectAdmin(project: project, on: req)

            // A viewer can see the project but not manage it.
            let viewer = try await builder.createUser(username: "a3", email: "a3@example.com")
            try await RoleBindingService.grant(
                principalType: .user, principalID: viewer.id!, role: .viewer,
                nodeType: .project, nodeID: project.id!, createdBy: nil, on: app.db)
            await self.expectAbort(.forbidden, reason: "Admin access required") {
                try await OrganizationAccessService.requireProjectAdmin(
                    project: project, on: self.authedRequest(app, user: viewer))
            }
        }
    }
}
