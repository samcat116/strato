import ControlPlanePostgres
import Fluent
import Foundation
import SQLKit
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// Bearer credentials record `last_used_at`/`last_used_ip`, but not once per
/// request: authenticating used to fire a full-row `save` on every call, so
/// write load tracked request rate and a single busy key serialized on its own
/// row (issue #696). The writes are now debounced to one per window, touch only
/// the two columns, and run through the background-task registry.
@Suite("Credential last-used tracking", .serialized)
struct LastUsedTrackingTests {

    // MARK: - Helpers

    private func makeUser(on db: any Database) async throws -> User {
        let user = User(
            username: "lastused-tester",
            email: "lastused@example.com",
            displayName: "Last Used Tester",
            isSystemAdmin: false
        )
        try await user.save(on: db)
        return user
    }

    private func makeAPIKey(
        for user: User,
        on app: Application,
        lastUsedAt: Date?,
        lastUsedIP: String?
    ) async throws -> (APIKeySnapshot, String) {
        let fullKey = APIKeyCredential.generate()
        let created = try await app.apiKeysPersistence.issue(
            APIKeyWrite(
                userID: try user.requireID(),
                name: "Test API Key",
                keyHash: APIKeyCredential.hash(fullKey),
                keyPrefix: String(fullKey.prefix(8)),
                restriction: CredentialRestriction.unrestricted.stored
            ),
            maximumKeysPerUser: 10
        )
        guard let lastUsedAt else { return (created, fullKey) }
        _ = try await app.apiKeysPersistence.recordUsage(
            id: created.id,
            usedAt: lastUsedAt,
            sourceIP: lastUsedIP,
            staleBefore: .distantFuture
        )
        let seeded = try #require(
            try await app.apiKeysPersistence.ownedKey(
                id: created.id,
                userID: created.userID
            )
        )
        return (seeded, fullKey)
    }

    private func makeCLISession(
        for user: User,
        on app: Application,
        lastUsedAt: Date?,
        lastUsedIP: String?
    ) async throws -> (CLISessionSnapshot, String) {
        let accessToken = CLISession.generateAccessToken()
        let created = try await app.oauthDeviceSessionsPersistence.createSession(
            CLISessionWrite(
                userID: try user.requireID(),
                clientName: "test-cli",
                restriction: CredentialRestriction.unrestricted.stored,
                accessTokenHash: CLISession.hashToken(accessToken),
                accessTokenPrefix: String(accessToken.prefix(8)),
                accessTokenExpiresAt: Date().addingTimeInterval(CLISession.accessTokenLifetime),
                refreshTokenHash: CLISession.hashToken(CLISession.generateRefreshToken()),
                refreshTokenExpiresAt: Date().addingTimeInterval(CLISession.refreshTokenLifetime)
            )
        )
        guard let lastUsedAt else { return (created, accessToken) }
        _ = try await app.oauthDeviceSessionsPersistence.recordSessionUsage(
            id: created.id,
            usedAt: lastUsedAt,
            sourceIP: lastUsedIP,
            staleBefore: lastUsedAt
        )
        let seeded = try #require(
            try await app.oauthDeviceSessionsPersistence.session(
                accessTokenHash: created.accessTokenHash
            ))
        return (seeded, accessToken)
    }

    /// Replaces the routing table with a single route behind the production
    /// authentication pipeline.
    ///
    /// The route is deliberately *not* wrapped in its own
    /// `BearerAuthorizationHeaderAuthenticator`: `configure` already installs
    /// one application-wide, and a second copy would authenticate — and so
    /// record usage — twice per request, which no real request does.
    private func registerProtectedRoute(on app: Application) {
        app.routes.all.removeAll()
        // Ad-hoc route outside the production classification; declare it so the
        // default-deny middleware treats it as login-gated (#482).
        app.testOnlyLoginRoutePrefixes = ["/test"]
        app.get("test") { req -> String in
            guard req.auth.has(User.self) else { throw Abort(.unauthorized) }
            return "ok"
        }
    }

    private func authenticate(_ app: Application, token: String) async throws {
        try await app.test(
            .GET, "/test",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            }
        ) { res async in
            #expect(res.status == .ok)
        }
        // The write-back is fire-and-forget; drain it before asserting.
        await app.backgroundTasks.drain(timeout: .seconds(10))
    }

    // MARK: - Debounce predicate

    @Test("A credential that has never been used is always stale")
    func testNeverUsedIsStale() {
        #expect(APIKeyCredential.lastUsedIsStale(nil))
    }

    @Test("A recently recorded timestamp is inside the debounce window")
    func testRecentTimestampIsFresh() {
        let now = Date()
        let lastUsedAt = now.addingTimeInterval(-APIKeyCredential.lastUsedDebounceWindow + 60)
        #expect(!APIKeyCredential.lastUsedIsStale(lastUsedAt, now: now))
    }

    @Test("A timestamp older than the debounce window is stale")
    func testOldTimestampIsStale() {
        let now = Date()
        let lastUsedAt = now.addingTimeInterval(-APIKeyCredential.lastUsedDebounceWindow - 1)
        #expect(APIKeyCredential.lastUsedIsStale(lastUsedAt, now: now))
    }

    @Test("A timestamp ahead of now reads as fresh rather than being dragged back")
    func testFutureTimestampIsFresh() {
        let now = Date()
        #expect(!CLISession.lastUsedIsStale(now.addingTimeInterval(300), now: now))
    }

    // MARK: - API keys

    @Test("First use of an API key writes the two last-used columns and nothing else")
    func testAPIKeyFirstUseRecords() async throws {
        let app = try await Application.makeForTesting()
        try await configure(app)
        try await app.autoMigrate()

        let user = try await makeUser(on: app.db)
        let (apiKey, fullKey) = try await makeAPIKey(
            for: user, on: app, lastUsedAt: nil, lastUsedIP: nil)
        let keyID = apiKey.id

        registerProtectedRoute(on: app)
        try await authenticate(app, token: fullKey)

        let reloaded = try #require(
            try await app.apiKeysPersistence.ownedKey(id: keyID, userID: apiKey.userID)
        )
        #expect(reloaded.lastUsedAt != nil)
        #expect(reloaded.name == "Test API Key")
        #expect(reloaded.keyPrefix == apiKey.keyPrefix)
        #expect(reloaded.isActive)
        #expect(reloaded.expiresAt == nil)

        try await app.shutdownForTesting()
    }

    @Test("Repeated use inside the debounce window writes only once")
    func testAPIKeyDebouncesRepeatedUse() async throws {
        let app = try await Application.makeForTesting()
        try await configure(app)
        try await app.autoMigrate()

        let user = try await makeUser(on: app.db)
        let (apiKey, fullKey) = try await makeAPIKey(
            for: user, on: app, lastUsedAt: nil, lastUsedIP: nil)
        let keyID = apiKey.id

        registerProtectedRoute(on: app)

        // First request pays the write, then stamp a recognizable IP so a
        // second write would be visible in the row as well as in the history.
        try await authenticate(app, token: fullKey)
        let afterFirst = try #require(
            try await app.apiKeysPersistence.ownedKey(id: keyID, userID: apiKey.userID)
        )
        let recordedAt = try #require(afterFirst.lastUsedAt)
        _ = try await app.apiKeysPersistence.recordUsage(
            id: keyID,
            usedAt: recordedAt,
            sourceIP: "198.51.100.7",
            staleBefore: recordedAt.addingTimeInterval(1)
        )

        for _ in 0..<3 {
            try await authenticate(app, token: fullKey)
        }

        let afterRepeats = try #require(
            try await app.apiKeysPersistence.ownedKey(id: keyID, userID: apiKey.userID)
        )
        #expect(afterRepeats.lastUsedAt == recordedAt)
        #expect(afterRepeats.lastUsedIP == "198.51.100.7")

        try await app.shutdownForTesting()
    }

    @Test("A second writer racing on the same stale row is rejected by the database")
    func testConcurrentWritersCollapseToOne() async throws {
        let app = try await Application.makeForTesting()
        try await configure(app)
        try await app.autoMigrate()

        let user = try await makeUser(on: app.db)
        let (apiKey, _) = try await makeAPIKey(
            for: user, on: app, lastUsedAt: nil, lastUsedIP: nil)
        let keyID = apiKey.id

        let first = Date()
        #expect(
            try await app.apiKeysPersistence.recordUsage(
                id: keyID,
                usedAt: first,
                sourceIP: "198.51.100.1",
                staleBefore: first.addingTimeInterval(-APIKeyCredential.lastUsedDebounceWindow)
            )
        )
        #expect(
            !(try await app.apiKeysPersistence.recordUsage(
                id: keyID,
                usedAt: first.addingTimeInterval(1),
                sourceIP: "198.51.100.2",
                staleBefore: first.addingTimeInterval(-APIKeyCredential.lastUsedDebounceWindow + 1)
            ))
        )

        let reloaded = try #require(
            try await app.apiKeysPersistence.ownedKey(id: keyID, userID: apiKey.userID)
        )
        #expect(reloaded.lastUsedIP == "198.51.100.1")

        try await app.shutdownForTesting()
    }

    @Test("Use after the debounce window elapses writes the timestamp forward")
    func testAPIKeyWritesAfterWindow() async throws {
        let app = try await Application.makeForTesting()
        try await configure(app)
        try await app.autoMigrate()

        let user = try await makeUser(on: app.db)
        let stale = Date().addingTimeInterval(-APIKeyCredential.lastUsedDebounceWindow - 60)
        let (apiKey, fullKey) = try await makeAPIKey(
            for: user, on: app, lastUsedAt: stale, lastUsedIP: "198.51.100.7")
        let keyID = apiKey.id

        registerProtectedRoute(on: app)
        try await authenticate(app, token: fullKey)

        let reloaded = try #require(
            try await app.apiKeysPersistence.ownedKey(id: keyID, userID: apiKey.userID)
        )
        let recordedAt = try #require(reloaded.lastUsedAt)
        #expect(recordedAt > stale)

        try await app.shutdownForTesting()
    }

    // MARK: - CLI sessions

    @Test("CLI session use is recorded once and then debounced")
    func testCLISessionDebounce() async throws {
        let app = try await Application.makeForTesting()
        try await configure(app)
        try await app.autoMigrate()

        let user = try await makeUser(on: app.db)
        let (session, accessToken) = try await makeCLISession(
            for: user, on: app, lastUsedAt: nil, lastUsedIP: nil)
        let sessionID = session.id

        registerProtectedRoute(on: app)

        try await authenticate(app, token: accessToken)
        let afterFirst = try #require(
            try await app.oauthDeviceSessionsPersistence.session(
                accessTokenHash: session.accessTokenHash
            ))
        let recordedAt = try #require(afterFirst.lastUsedAt)
        let sql = try #require(app.db as? any SQLDatabase)
        try await sql.raw(
            "UPDATE cli_sessions SET last_used_ip = \(bind: "198.51.100.9") WHERE id = \(bind: sessionID)"
        ).run()

        try await authenticate(app, token: accessToken)

        let afterSecond = try #require(
            try await app.oauthDeviceSessionsPersistence.session(
                accessTokenHash: session.accessTokenHash
            ))
        #expect(afterSecond.lastUsedAt == recordedAt)
        #expect(afterSecond.lastUsedIP == "198.51.100.9")

        try await app.shutdownForTesting()
    }
}
