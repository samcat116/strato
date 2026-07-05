import Testing
import Vapor
import Fluent
import VaporTesting
@testable import App

/// Regression tests for issue #163: `SpiceDBAuthMiddleware` guarded `/vms` while VM
/// routes live under `/api/vms`, so per-object authorization was dead code. These tests
/// exercise the full middleware + handler stack against the in-memory mock SpiceDB and
/// assert that a denied permission actually yields 403 on the `/api/vms` routes.
@Suite("VM Authorization Tests", .serialized)
final class VMAuthorizationTests {

    /// Boots a configured test app with a non-admin user, org, project and one VM.
    ///
    /// `configure(app)` installs `SpiceDBAuthMiddleware` in every environment,
    /// including `.testing` (issue #196), so these requests traverse the same
    /// middleware whose `/api/vms` prefix regression this suite covers rather than
    /// only exercising the per-handler `authorizedVM` checks.
    private func withVMTestApp(
        _ test: (Application, User, VM, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "vmauthuser",
                email: "vmauth@example.com",
                displayName: "VM Auth User",
                isSystemAdmin: false
            )
            let org = try await builder.createOrganization(name: "VM Auth Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "member")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let project = try await builder.createProject(
                name: "VM Auth Project",
                description: "Project for VM authorization tests",
                organization: org
            )
            let vm = try await builder.createVM(name: "auth-vm", project: project)
            let token = try await user.generateAPIKey(on: app.db)

            try await test(app, user, vm, token)

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

    @Test("GET /api/vms/:id is denied (403) when SpiceDB withholds read")
    func showDeniedWhenNoPermission() async throws {
        try await withVMTestApp { app, _, vm, token in
            app.spicedbMockAllows = false

            try await app.test(.GET, "/api/vms/\(vm.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                // Before the fix the middleware guarded `/vms`, so this route slipped
                // through with only authentication and returned 200 (VM leaked).
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("GET /api/vms/:id succeeds (200) when SpiceDB grants read")
    func showAllowedWhenPermitted() async throws {
        try await withVMTestApp { app, _, vm, token in
            app.spicedbMockAllows = true

            try await app.test(.GET, "/api/vms/\(vm.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test("POST /api/vms/:id/start is denied (403) when SpiceDB withholds start")
    func startActionDeniedWhenNoPermission() async throws {
        try await withVMTestApp { app, _, vm, token in
            app.spicedbMockAllows = false

            try await app.test(.POST, "/api/vms/\(vm.id!)/start") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("GET /api/vms/:id/logs is denied (403) when SpiceDB withholds read")
    func logsDeniedWhenNoPermission() async throws {
        try await withVMTestApp { app, _, vm, token in
            app.spicedbMockAllows = false

            try await app.test(.GET, "/api/vms/\(vm.id!)/logs") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    // MARK: - Direct middleware tests
    //
    // These isolate `SpiceDBAuthMiddleware` from the route handlers so the `/api/vms`
    // prefix regression is pinned independently of the per-handler `authorizedVM`
    // checks: reverting the guard to `/vms` makes `middlewareGuardsApiVmsPrefix` fail
    // (the request falls through to `next` → 200 instead of throwing 403), and
    // `middlewareIgnoresBareVmsPrefix` fails the other way.

    /// A `next` responder that unconditionally succeeds, standing in for the route
    /// handler so any 403 must originate from the middleware itself.
    private struct OKResponder: AsyncResponder {
        func respond(to request: Request) async throws -> Response {
            Response(status: .ok)
        }
    }

    private func runMiddleware(
        _ app: Application,
        user: User,
        path: String,
        method: HTTPMethod = .GET
    ) async throws -> Response {
        let req = Request(
            application: app,
            method: method,
            url: URI(path: path),
            on: app.eventLoopGroup.next()
        )
        req.auth.login(user)
        return try await SpiceDBAuthMiddleware().respond(to: req, chainingTo: OKResponder())
    }

    @Test("Middleware runs its per-object check for the /api/vms prefix")
    func middlewareGuardsApiVmsPrefix() async throws {
        try await withVMTestApp { app, user, vm, _ in
            // Denied: the middleware must reject before reaching the handler.
            app.spicedbMockAllows = false
            await #expect(throws: Abort.self) {
                _ = try await self.runMiddleware(app, user: user, path: "/api/vms/\(vm.id!)")
            }

            // Granted: the middleware lets the request through to `next` (200).
            app.spicedbMockAllows = true
            let res = try await runMiddleware(app, user: user, path: "/api/vms/\(vm.id!)")
            #expect(res.status == .ok)
        }
    }

    @Test("Middleware does not guard the stale bare /vms prefix")
    func middlewareIgnoresBareVmsPrefix() async throws {
        try await withVMTestApp { app, user, vm, _ in
            // The old (buggy) prefix must NOT be what's guarded: even with permission
            // withheld, a bare `/vms/...` path is not a real route and falls through.
            app.spicedbMockAllows = false
            let res = try await runMiddleware(app, user: user, path: "/vms/\(vm.id!)")
            #expect(res.status == .ok)
        }
    }
}
