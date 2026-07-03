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
            try? await Task.sleep(for: .seconds(2))
            app.cleanupTestDatabase()
            throw error
        }

        try await app.asyncShutdown()
        try? await Task.sleep(for: .seconds(2))
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
}
