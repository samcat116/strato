import Testing
import Vapor
import Fluent
import VaporTesting
@testable import App

/// Tests the batch "can I?" endpoint (`POST /api/authorization/check`) that the
/// frontend uses to gate UI. Drives per-resource verdicts through the mock SpiceDB
/// (`spicedbMockAllows` / `spicedbMockDeniedResources`).
@Suite("Authorization Check Endpoint Tests", .serialized)
final class AuthorizationCheckTests {

    private func withApp(
        systemAdmin: Bool = false,
        _ test: (Application, User, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "authcheckuser",
                email: "authcheck@example.com",
                displayName: "Auth Check User",
                isSystemAdmin: systemAdmin
            )
            let org = try await builder.createOrganization(name: "Auth Check Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "member")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let token = try await user.generateAPIKey(on: app.db)
            try await test(app, user, token)

        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private func body(
        _ items: [(key: String, resourceType: String, permission: String)]
    ) -> AuthorizationController.CheckRequest {
        AuthorizationController.CheckRequest(
            checks: items.map {
                AuthorizationController.PermissionCheckItem(
                    key: $0.key,
                    resourceType: $0.resourceType,
                    resourceId: UUID().uuidString,
                    permission: $0.permission
                )
            }
        )
    }

    @Test("Per-resource denial is reflected per key")
    func perResourceDenial() async throws {
        try await withApp { app, _, token in
            app.spicedbMockAllows = true
            app.spicedbMockDeniedResources = ["organization"]

            try await app.test(.POST, "/api/authorization/check") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    self.body([
                        (key: "manage_org", resourceType: "organization", permission: "manage_members"),
                        (key: "view_proj", resourceType: "project", permission: "view_project"),
                    ]))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let decoded = try res.content.decode(AuthorizationController.CheckResponse.self)
                let orgResult = decoded.results["manage_org"]
                let projResult = decoded.results["view_proj"]
                #expect(orgResult == false)
                #expect(projResult == true)
            }
        }
    }

    @Test("System admin gets all-true without consulting SpiceDB")
    func systemAdminAllTrue() async throws {
        try await withApp(systemAdmin: true) { app, _, token in
            // Even with the mock set to deny everything, the admin short-circuit wins.
            app.spicedbMockAllows = false
            app.spicedbMockDeniedResources = ["organization", "project"]

            try await app.test(.POST, "/api/authorization/check") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    self.body([
                        (key: "a", resourceType: "organization", permission: "manage_members"),
                        (key: "b", resourceType: "project", permission: "manage_project"),
                    ]))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let decoded = try res.content.decode(AuthorizationController.CheckResponse.self)
                let a = decoded.results["a"]
                let b = decoded.results["b"]
                #expect(a == true)
                #expect(b == true)
            }
        }
    }

    @Test("Unauthenticated request is rejected (401)")
    func unauthenticated() async throws {
        try await withApp { app, _, _ in
            try await app.test(.POST, "/api/authorization/check") { req in
                try req.content.encode(
                    self.body([(key: "a", resourceType: "organization", permission: "view_organization")]))
            } afterResponse: { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test("More than 50 checks is rejected (400)")
    func tooManyChecks() async throws {
        try await withApp { app, _, token in
            app.spicedbMockAllows = true
            let items = (0..<51).map { (key: "k\($0)", resourceType: "project", permission: "view_project") }

            try await app.test(.POST, "/api/authorization/check") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(self.body(items))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }
}
