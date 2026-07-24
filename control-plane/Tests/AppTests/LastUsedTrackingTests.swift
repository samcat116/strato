import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

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
        on db: any Database,
        lastUsedAt: Date?,
        lastUsedIP: String?
    ) async throws -> (APIKey, String) {
        let fullKey = APIKey.generateAPIKey()
        let apiKey = APIKey(
            userID: try user.requireID(),
            name: "Test API Key",
            keyHash: APIKey.hashAPIKey(fullKey),
            keyPrefix: String(fullKey.prefix(8))
        )
        apiKey.lastUsedAt = lastUsedAt
        apiKey.lastUsedIP = lastUsedIP
        try await apiKey.save(on: db)
        return (apiKey, fullKey)
    }

    private func makeCLISession(
        for user: User,
        on db: any Database,
        lastUsedAt: Date?,
        lastUsedIP: String?
    ) async throws -> (CLISession, String) {
        let accessToken = CLISession.generateAccessToken()
        let session = CLISession(
            userID: try user.requireID(),
            clientName: "test-cli",
            scopes: ["read", "write"],
            accessTokenHash: CLISession.hashToken(accessToken),
            accessTokenPrefix: String(accessToken.prefix(8)),
            accessTokenExpiresAt: Date().addingTimeInterval(CLISession.accessTokenLifetime),
            refreshTokenHash: CLISession.hashToken(CLISession.generateRefreshToken()),
            refreshTokenExpiresAt: Date().addingTimeInterval(CLISession.refreshTokenLifetime)
        )
        session.lastUsedAt = lastUsedAt
        session.lastUsedIP = lastUsedIP
        try await session.save(on: db)
        return (session, accessToken)
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

    /// The column sets written by recorded `UPDATE`s against `schema`.
    ///
    /// Fluent records the query as issued, before it stamps `updated_at` onto
    /// any update, so these are exactly the columns the caller asked for.
    private func recordedUpdateColumns(on app: Application, schema: String) -> [Set<FieldKey>] {
        app.fluent.history.queries.compactMap { query in
            guard query.schema == schema, case .update = query.action else { return nil }
            var columns: Set<FieldKey> = []
            for case .dictionary(let fields) in query.input {
                columns.formUnion(fields.keys)
            }
            return columns
        }
    }

    // MARK: - Debounce predicate

    @Test("A credential that has never been used is always stale")
    func testNeverUsedIsStale() {
        let key = APIKey(userID: UUID(), name: "k", keyHash: "h", keyPrefix: "p")
        #expect(key.lastUsedIsStale())
    }

    @Test("A recently recorded timestamp is inside the debounce window")
    func testRecentTimestampIsFresh() {
        let now = Date()
        let key = APIKey(userID: UUID(), name: "k", keyHash: "h", keyPrefix: "p")
        key.lastUsedAt = now.addingTimeInterval(-APIKey.lastUsedDebounceWindow + 60)
        #expect(!key.lastUsedIsStale(now: now))
    }

    @Test("A timestamp older than the debounce window is stale")
    func testOldTimestampIsStale() {
        let now = Date()
        let key = APIKey(userID: UUID(), name: "k", keyHash: "h", keyPrefix: "p")
        key.lastUsedAt = now.addingTimeInterval(-APIKey.lastUsedDebounceWindow - 1)
        #expect(key.lastUsedIsStale(now: now))
    }

    @Test("A timestamp ahead of now reads as fresh rather than being dragged back")
    func testFutureTimestampIsFresh() {
        let now = Date()
        let session = CLISession()
        session.lastUsedAt = now.addingTimeInterval(300)
        #expect(!session.lastUsedIsStale(now: now))
    }

    // MARK: - API keys

    @Test("First use of an API key writes the two last-used columns and nothing else")
    func testAPIKeyFirstUseRecords() async throws {
        let app = try await Application.makeForTesting()
        try await configure(app)
        try await app.autoMigrate()

        let user = try await makeUser(on: app.db)
        let (apiKey, fullKey) = try await makeAPIKey(
            for: user, on: app.db, lastUsedAt: nil, lastUsedIP: nil)
        let keyID = try apiKey.requireID()

        registerProtectedRoute(on: app)
        app.fluent.history.start()
        try await authenticate(app, token: fullKey)

        let reloaded = try #require(try await APIKey.find(keyID, on: app.db))
        #expect(reloaded.lastUsedAt != nil)
        // A targeted update, not the full-row `save` this replaced: every other
        // column of the key stays out of the statement.
        #expect(
            recordedUpdateColumns(on: app, schema: APIKey.schema) == [
                [APIKey.lastUsedAtKey, APIKey.lastUsedIPKey]
            ])

        app.fluent.history.stop()
        try await app.shutdownForTesting()
    }

    @Test("Repeated use inside the debounce window writes only once")
    func testAPIKeyDebouncesRepeatedUse() async throws {
        let app = try await Application.makeForTesting()
        try await configure(app)
        try await app.autoMigrate()

        let user = try await makeUser(on: app.db)
        let (apiKey, fullKey) = try await makeAPIKey(
            for: user, on: app.db, lastUsedAt: nil, lastUsedIP: nil)
        let keyID = try apiKey.requireID()

        registerProtectedRoute(on: app)

        // First request pays the write, then stamp a recognizable IP so a
        // second write would be visible in the row as well as in the history.
        try await authenticate(app, token: fullKey)
        let afterFirst = try #require(try await APIKey.find(keyID, on: app.db))
        let recordedAt = try #require(afterFirst.lastUsedAt)
        afterFirst.lastUsedIP = "198.51.100.7"
        try await afterFirst.save(on: app.db)

        app.fluent.history.start()
        for _ in 0..<3 {
            try await authenticate(app, token: fullKey)
        }

        #expect(recordedUpdateColumns(on: app, schema: APIKey.schema).isEmpty)
        let afterRepeats = try #require(try await APIKey.find(keyID, on: app.db))
        #expect(afterRepeats.lastUsedAt == recordedAt)
        #expect(afterRepeats.lastUsedIP == "198.51.100.7")

        app.fluent.history.stop()
        try await app.shutdownForTesting()
    }

    @Test("A second writer racing on the same stale row is rejected by the database")
    func testConcurrentWritersCollapseToOne() async throws {
        let app = try await Application.makeForTesting()
        try await configure(app)
        try await app.autoMigrate()

        let user = try await makeUser(on: app.db)
        let (apiKey, _) = try await makeAPIKey(
            for: user, on: app.db, lastUsedAt: nil, lastUsedIP: nil)
        let keyID = try apiKey.requireID()

        // Both calls run against the same in-memory row — the state two
        // concurrent requests see when neither has written yet — so both pass
        // the in-process staleness check and only the `WHERE` can separate
        // them.
        let first = Date()
        apiKey.recordUsage(ip: "198.51.100.1", on: app, now: first)
        await app.backgroundTasks.drain(timeout: .seconds(10))
        apiKey.recordUsage(ip: "198.51.100.2", on: app, now: first.addingTimeInterval(1))
        await app.backgroundTasks.drain(timeout: .seconds(10))

        let reloaded = try #require(try await APIKey.find(keyID, on: app.db))
        #expect(reloaded.lastUsedIP == "198.51.100.1")

        try await app.shutdownForTesting()
    }

    @Test("Use after the debounce window elapses writes the timestamp forward")
    func testAPIKeyWritesAfterWindow() async throws {
        let app = try await Application.makeForTesting()
        try await configure(app)
        try await app.autoMigrate()

        let user = try await makeUser(on: app.db)
        let stale = Date().addingTimeInterval(-APIKey.lastUsedDebounceWindow - 60)
        let (apiKey, fullKey) = try await makeAPIKey(
            for: user, on: app.db, lastUsedAt: stale, lastUsedIP: "198.51.100.7")
        let keyID = try apiKey.requireID()

        registerProtectedRoute(on: app)
        try await authenticate(app, token: fullKey)

        let reloaded = try #require(try await APIKey.find(keyID, on: app.db))
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
            for: user, on: app.db, lastUsedAt: nil, lastUsedIP: nil)
        let sessionID = try session.requireID()

        registerProtectedRoute(on: app)

        try await authenticate(app, token: accessToken)
        let afterFirst = try #require(try await CLISession.find(sessionID, on: app.db))
        let recordedAt = try #require(afterFirst.lastUsedAt)
        afterFirst.lastUsedIP = "198.51.100.9"
        try await afterFirst.save(on: app.db)

        app.fluent.history.start()
        try await authenticate(app, token: accessToken)

        #expect(recordedUpdateColumns(on: app, schema: CLISession.schema).isEmpty)
        let afterSecond = try #require(try await CLISession.find(sessionID, on: app.db))
        #expect(afterSecond.lastUsedAt == recordedAt)
        #expect(afterSecond.lastUsedIP == "198.51.100.9")

        app.fluent.history.stop()
        try await app.shutdownForTesting()
    }
}
