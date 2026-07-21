import Fluent
import Testing
import Vapor
import VaporTesting

@testable import App

/// Pins the issue #482 pre-cutover audit decision for `/api/api-keys`: API
/// keys are identity-plane, deliberately outside the IAM resource tree (design
/// phase-0 decision: API keys unchanged for now). Authorization is login plus
/// row scoping to the calling user — another user's key is a 404, never
/// visible, and never mutable. The default-deny middleware keeps these routes
/// on login-only at cutover.
@Suite("API Key Ownership Tests", .serialized)
final class APIKeyOwnershipTests {

    private func withTwoUsers(
        _ test: (Application, User, String, User, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let alice = try await builder.createUser(
                username: "keyowner", email: "keyowner@example.com", displayName: "Key Owner")
            let aliceToken = try await alice.generateAPIKey(on: app.db)
            let mallory = try await builder.createUser(
                username: "keyother", email: "keyother@example.com", displayName: "Key Other")
            let malloryToken = try await mallory.generateAPIKey(on: app.db)

            try await test(app, alice, aliceToken, mallory, malloryToken)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    @Test("Another user's API key is invisible and immutable — 404, never 403")
    func crossUserKeyAccessIs404() async throws {
        try await withTwoUsers { app, alice, aliceToken, _, malloryToken in
            // Alice's persisted key row (the one backing her bearer token).
            let aliceKey = try #require(
                try await APIKey.query(on: app.db)
                    .filter(\.$user.$id == alice.id!)
                    .first())

            // The owner sees it.
            try await app.test(.GET, "/api/api-keys/\(aliceKey.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: aliceToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            // Another user gets 404 on every verb — existence is not leaked.
            try await app.test(.GET, "/api/api-keys/\(aliceKey.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: malloryToken)
            } afterResponse: { res in
                #expect(res.status == .notFound)
            }
            try await app.test(.PATCH, "/api/api-keys/\(aliceKey.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: malloryToken)
                try req.content.encode(["isActive": false])
            } afterResponse: { res in
                #expect(res.status == .notFound)
            }
            try await app.test(.DELETE, "/api/api-keys/\(aliceKey.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: malloryToken)
            } afterResponse: { res in
                #expect(res.status == .notFound)
            }

            // And the listing shows only the caller's own keys.
            try await app.test(.GET, "/api/api-keys") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: malloryToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let keys = try res.content.decode([APIKeyResponse].self)
                #expect(!keys.contains { $0.id == aliceKey.id })
            }
        }
    }
}
