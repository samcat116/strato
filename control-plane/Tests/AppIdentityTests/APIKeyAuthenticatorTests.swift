import Testing
import Vapor
import VaporTesting
import Fluent
import AppTestSupport
@testable import App

@Suite("APIKeyAuthenticator Tests", .serialized)
struct APIKeyAuthenticatorTests {

    // MARK: - Test Helpers

    func createTestUser(on db: Database) async throws -> User {
        let user = User(
            username: "testuser",
            email: "test@example.com",
            displayName: "Test User",
            isSystemAdmin: false
        )
        try await user.save(on: db)
        return user
    }

    func createTestAPIKey(
        for user: User,
        on db: Database,
        isActive: Bool = true,
        expiresAt: Date? = nil,
        scopes: [String] = ["read", "write"],
        restriction: CredentialRestriction? = nil
    ) async throws -> (APIKey, String) {
        let fullKey = APIKey.generateAPIKey()
        let hashedKey = APIKey.hashAPIKey(fullKey)
        let prefix = String(fullKey.prefix(8))

        let apiKey = APIKey(
            userID: try user.requireID(),
            name: "Test API Key",
            keyHash: hashedKey,
            keyPrefix: prefix,
            scopes: scopes,
            isActive: isActive,
            expiresAt: expiresAt
        )
        apiKey.store(restriction: restriction)
        try await apiKey.save(on: db)
        return (apiKey, fullKey)
    }

    // MARK: - Basic Authentication Tests

    @Test("APIKeyAuthenticator authenticates valid API key")
    func testValidAPIKey() async throws {
        let app = try await Application.makeForTesting()

        try await configure(app)
        try await app.autoMigrate()

        let user = try await createTestUser(on: app.db)
        let (_, fullKey) = try await createTestAPIKey(for: user, on: app.db)

        // Create a test route that requires authentication
        app.routes.all.removeAll()
        // Ad-hoc routes outside the production classification; declare them so
        // the default-deny middleware treats them as login-gated (#482).
        app.testOnlyLoginRoutePrefixes = ["/test", "/resource"]
        let protected = app.grouped(BearerAuthorizationHeaderAuthenticator())
        protected.get("test") { req -> String in
            guard let authUser = req.auth.get(User.self) else {
                throw Abort(.unauthorized)
            }
            return authUser.username
        }

        try await app.test(
            .GET, "/test",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fullKey)
            }
        ) { res async in
            #expect(res.status == .ok)
            #expect(res.body.string == "testuser")
        }

        try await app.shutdownForTesting()
    }

    @Test("APIKeyAuthenticator rejects invalid API key")
    func testInvalidAPIKey() async throws {
        let app = try await Application.makeForTesting()

        try await configure(app)
        try await app.autoMigrate()

        let user = try await createTestUser(on: app.db)
        _ = try await createTestAPIKey(for: user, on: app.db)

        // Create a test route that requires authentication
        app.routes.all.removeAll()
        // Ad-hoc routes outside the production classification; declare them so
        // the default-deny middleware treats them as login-gated (#482).
        app.testOnlyLoginRoutePrefixes = ["/test", "/resource"]
        let protected = app.grouped(BearerAuthorizationHeaderAuthenticator())
        protected.get("test") { req -> String in
            guard let authUser = req.auth.get(User.self) else {
                throw Abort(.unauthorized)
            }
            return authUser.username
        }

        try await app.test(
            .GET, "/test",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: "sk_invalid_key_1234567890")
            }
        ) { res async in
            #expect(res.status == .unauthorized)
        }

        try await app.shutdownForTesting()
    }

    @Test("API-key authentication does not create a browser session")
    func testAPIKeyDoesNotCreateSession() async throws {
        let app = try await Application.makeForTesting()

        try await configure(app)
        try await app.autoMigrate()

        let user = try await createTestUser(on: app.db)
        let (_, fullKey) = try await createTestAPIKey(for: user, on: app.db)

        app.routes.all.removeAll()
        app.testOnlyLoginRoutePrefixes = ["/test"]
        app.get("test", "api-key-session-isolation") { req -> String in
            try req.auth.require(User.self).username
        }

        try await app.test(
            .GET, "/test/api-key-session-isolation",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fullKey)
            }
        ) { res async in
            #expect(res.status == .ok)
            #expect(res.body.string == "testuser")
            // Before STR-206, SessionAuthenticator wrapped bearer auth and
            // promoted this user into a new Valkey-backed browser session.
            #expect(res.headers.setCookie?["vapor-session"] == nil)
        }

        try await app.shutdownForTesting()
    }

    @Test("APIKeyAuthenticator rejects request without API key")
    func testMissingAPIKey() async throws {
        let app = try await Application.makeForTesting()

        try await configure(app)
        try await app.autoMigrate()

        // Create a test route that requires authentication
        app.routes.all.removeAll()
        // Ad-hoc routes outside the production classification; declare them so
        // the default-deny middleware treats them as login-gated (#482).
        app.testOnlyLoginRoutePrefixes = ["/test", "/resource"]
        let protected = app.grouped(BearerAuthorizationHeaderAuthenticator())
        protected.get("test") { req -> String in
            guard let authUser = req.auth.get(User.self) else {
                throw Abort(.unauthorized)
            }
            return authUser.username
        }

        try await app.test(.GET, "/test") { res async in
            #expect(res.status == .unauthorized)
        }

        try await app.shutdownForTesting()
    }

    // MARK: - API Key Format Tests

    @Test("APIKeyAuthenticator only processes keys with sk_ prefix")
    func testAPIKeyPrefix() async throws {
        let app = try await Application.makeForTesting()

        try await configure(app)
        try await app.autoMigrate()

        let user = try await createTestUser(on: app.db)
        _ = try await createTestAPIKey(for: user, on: app.db)

        // Create a test route that requires authentication
        app.routes.all.removeAll()
        // Ad-hoc routes outside the production classification; declare them so
        // the default-deny middleware treats them as login-gated (#482).
        app.testOnlyLoginRoutePrefixes = ["/test", "/resource"]
        let protected = app.grouped(BearerAuthorizationHeaderAuthenticator())
        protected.get("test") { req -> String in
            guard let authUser = req.auth.get(User.self) else {
                throw Abort(.unauthorized)
            }
            return authUser.username
        }

        // Try with a non-sk_ prefixed token (should be ignored by authenticator)
        try await app.test(
            .GET, "/test",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: "other_token_format")
            }
        ) { res async in
            #expect(res.status == .unauthorized)
        }

        try await app.shutdownForTesting()
    }

    // MARK: - API Key Status Tests

    @Test("APIKeyAuthenticator rejects inactive API key")
    func testInactiveAPIKey() async throws {
        let app = try await Application.makeForTesting()

        try await configure(app)
        try await app.autoMigrate()

        let user = try await createTestUser(on: app.db)
        let (_, fullKey) = try await createTestAPIKey(for: user, on: app.db, isActive: false)

        // Create a test route that requires authentication
        app.routes.all.removeAll()
        // Ad-hoc routes outside the production classification; declare them so
        // the default-deny middleware treats them as login-gated (#482).
        app.testOnlyLoginRoutePrefixes = ["/test", "/resource"]
        let protected = app.grouped(BearerAuthorizationHeaderAuthenticator())
        protected.get("test") { req -> String in
            guard let authUser = req.auth.get(User.self) else {
                throw Abort(.unauthorized)
            }
            return authUser.username
        }

        try await app.test(
            .GET, "/test",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fullKey)
            }
        ) { res async in
            #expect(res.status == .unauthorized)
        }

        try await app.shutdownForTesting()
    }

    @Test("APIKeyAuthenticator rejects expired API key")
    func testExpiredAPIKey() async throws {
        let app = try await Application.makeForTesting()

        try await configure(app)
        try await app.autoMigrate()

        let user = try await createTestUser(on: app.db)
        let expiredDate = Date().addingTimeInterval(-86400)  // 1 day ago
        let (_, fullKey) = try await createTestAPIKey(for: user, on: app.db, expiresAt: expiredDate)

        // Create a test route that requires authentication
        app.routes.all.removeAll()
        // Ad-hoc routes outside the production classification; declare them so
        // the default-deny middleware treats them as login-gated (#482).
        app.testOnlyLoginRoutePrefixes = ["/test", "/resource"]
        let protected = app.grouped(BearerAuthorizationHeaderAuthenticator())
        protected.get("test") { req -> String in
            guard let authUser = req.auth.get(User.self) else {
                throw Abort(.unauthorized)
            }
            return authUser.username
        }

        try await app.test(
            .GET, "/test",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fullKey)
            }
        ) { res async in
            #expect(res.status == .unauthorized)
        }

        try await app.shutdownForTesting()
    }

    @Test("APIKeyAuthenticator accepts API key with future expiration")
    func testFutureExpirationAPIKey() async throws {
        let app = try await Application.makeForTesting()

        try await configure(app)
        try await app.autoMigrate()

        let user = try await createTestUser(on: app.db)
        let futureDate = Date().addingTimeInterval(86400)  // 1 day from now
        let (_, fullKey) = try await createTestAPIKey(for: user, on: app.db, expiresAt: futureDate)

        // Create a test route that requires authentication
        app.routes.all.removeAll()
        // Ad-hoc routes outside the production classification; declare them so
        // the default-deny middleware treats them as login-gated (#482).
        app.testOnlyLoginRoutePrefixes = ["/test", "/resource"]
        let protected = app.grouped(BearerAuthorizationHeaderAuthenticator())
        protected.get("test") { req -> String in
            guard let authUser = req.auth.get(User.self) else {
                throw Abort(.unauthorized)
            }
            return authUser.username
        }

        try await app.test(
            .GET, "/test",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fullKey)
            }
        ) { res async in
            #expect(res.status == .ok)
            #expect(res.body.string == "testuser")
        }

        try await app.shutdownForTesting()
    }

    // MARK: - User Association Tests

    @Test("APIKeyAuthenticator loads associated user")
    func testUserAssociation() async throws {
        let app = try await Application.makeForTesting()

        try await configure(app)
        try await app.autoMigrate()

        let user = try await createTestUser(on: app.db)
        let (_, fullKey) = try await createTestAPIKey(for: user, on: app.db)

        // Create a test route that checks user details
        app.routes.all.removeAll()
        // Ad-hoc routes outside the production classification; declare them so
        // the default-deny middleware treats them as login-gated (#482).
        app.testOnlyLoginRoutePrefixes = ["/test", "/resource"]
        let protected = app.grouped(BearerAuthorizationHeaderAuthenticator())
        protected.get("test") { req -> String in
            guard let authUser = req.auth.get(User.self) else {
                throw Abort(.unauthorized)
            }
            return "\(authUser.username):\(authUser.email)"
        }

        try await app.test(
            .GET, "/test",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fullKey)
            }
        ) { res async in
            #expect(res.status == .ok)
            #expect(res.body.string == "testuser:test@example.com")
        }

        try await app.shutdownForTesting()
    }

    // MARK: - API Key Storage Tests

    @Test("APIKeyAuthenticator stores API key in request storage")
    func testAPIKeyStorage() async throws {
        let app = try await Application.makeForTesting()

        try await configure(app)
        try await app.autoMigrate()

        let user = try await createTestUser(on: app.db)
        let (_, fullKey) = try await createTestAPIKey(for: user, on: app.db)

        // Create a test route that checks API key storage
        app.routes.all.removeAll()
        // Ad-hoc routes outside the production classification; declare them so
        // the default-deny middleware treats them as login-gated (#482).
        app.testOnlyLoginRoutePrefixes = ["/test", "/resource"]
        let protected = app.grouped(BearerAuthorizationHeaderAuthenticator())
        protected.get("test") { req -> String in
            guard let storedKey = req.apiKey else {
                throw Abort(.internalServerError, reason: "API key not stored")
            }
            return storedKey.name
        }

        try await app.test(
            .GET, "/test",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fullKey)
            }
        ) { res async in
            #expect(res.status == .ok)
            #expect(res.body.string == "Test API Key")
        }

        try await app.shutdownForTesting()
    }

    // MARK: - Credential restriction backstop (STR-115)

    /// Registers a read (GET) and a write (POST) route behind the bearer
    /// authenticator + restriction middleware, mirroring the production
    /// pipeline. The routes are declared as test-only login routes, so they
    /// classify as `.loginOnly` — the class the backstop exists for, since no
    /// evaluator decision is made there.
    private func registerScopedRoutes(on app: Application) {
        app.routes.all.removeAll()
        // Ad-hoc routes outside the production classification; declare them so
        // the default-deny middleware treats them as login-gated (#482).
        app.testOnlyLoginRoutePrefixes = ["/test", "/resource"]
        let protected = app.grouped(
            BearerAuthorizationHeaderAuthenticator(),
            CredentialRestrictionMiddleware()
        )
        protected.get("resource") { _ in "read-ok" }
        protected.post("resource") { _ in "write-ok" }
    }

    @Test("Read-only key can perform read requests")
    func testReadScopeAllowsGet() async throws {
        let app = try await Application.makeForTesting()
        try await configure(app)
        try await app.autoMigrate()

        let user = try await createTestUser(on: app.db)
        let (_, fullKey) = try await createTestAPIKey(for: user, on: app.db, scopes: ["read"])
        registerScopedRoutes(on: app)

        try await app.test(
            .GET, "/resource",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fullKey)
            }
        ) { res async in
            #expect(res.status == .ok)
            #expect(res.body.string == "read-ok")
        }

        try await app.shutdownForTesting()
    }

    @Test("Read-only key is forbidden from identity-plane writes")
    func testReadScopeForbidsPost() async throws {
        let app = try await Application.makeForTesting()
        try await configure(app)
        try await app.autoMigrate()

        let user = try await createTestUser(on: app.db)
        let (_, fullKey) = try await createTestAPIKey(for: user, on: app.db, scopes: ["read"])
        registerScopedRoutes(on: app)

        try await app.test(
            .POST, "/resource",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fullKey)
            }
        ) { res async in
            #expect(res.status == .forbidden)
        }

        try await app.shutdownForTesting()
    }

    /// The same backstop covers CLI sessions, which the scope-era carve-outs
    /// kept forgetting: the restriction hangs off the request, not off the
    /// API-key storage key.
    @Test("A read-scoped CLI session is forbidden from identity-plane writes")
    func testReadScopedCLISessionForbidsPost() async throws {
        let app = try await Application.makeForTesting()
        try await configure(app)
        try await app.autoMigrate()

        let user = try await createTestUser(on: app.db)
        let accessToken = CLISession.generateAccessToken()
        let session = CLISession(
            userID: try user.requireID(),
            clientName: "cli",
            scopes: ["read"],
            accessTokenHash: CLISession.hashToken(accessToken),
            accessTokenPrefix: String(accessToken.prefix(12)) + "...",
            accessTokenExpiresAt: Date().addingTimeInterval(3600),
            refreshTokenHash: CLISession.hashToken(CLISession.generateRefreshToken()),
            refreshTokenExpiresAt: Date().addingTimeInterval(86400)
        )
        try await session.save(on: app.db)
        registerScopedRoutes(on: app)

        try await app.test(
            .GET, "/resource",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: accessToken)
            }
        ) { res async in
            #expect(res.status == .ok)
        }

        try await app.test(
            .POST, "/resource",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: accessToken)
            }
        ) { res async in
            #expect(res.status == .forbidden)
        }

        try await app.shutdownForTesting()
    }

    @Test("A restriction denial outside the evaluator writes a credential_restricted decision row")
    func testScopeDenialRecorded() async throws {
        let app = try await Application.makeForTesting()
        try await configure(app)
        try await app.autoMigrate()
        // Enable decision-row recording (off by default under .testing), after
        // configure resets the config and before the recorder is lazily built.
        app.iamDecisionLogConfig.recordDecisions = true

        let user = try await createTestUser(on: app.db)
        let (apiKey, fullKey) = try await createTestAPIKey(for: user, on: app.db, scopes: ["read"])
        registerScopedRoutes(on: app)

        try await app.test(
            .POST, "/resource",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fullKey)
            }
        ) { res async in
            #expect(res.status == .forbidden)
        }

        // Identity-plane routes make no evaluator decision, so this refusal has
        // no Cedar verdict behind it and would otherwise be an authorization
        // denial the decision log cannot explain (STR-116). The row names the
        // principal, the credential in its own columns, and which surface
        // refused. Filter to the credential_restricted rows rather than assert
        // on the whole table, so another middleware recording something on this
        // request doesn't turn this into a flake.
        await app.iamDecisionRecorder.flush()
        let entries = try await IAMDecisionLog.query(on: app.db)
            .filter(\.$cedarDecision == "credential_restricted")
            .all()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        let userID = try user.requireID()
        let apiKeyID = try apiKey.requireID()
        #expect(entry.subject == userID.uuidString)
        #expect(entry.spicedbPermission == "credential:login_only_mutation")
        #expect(entry.tier == "credential")
        #expect(entry.credentialType == "api_key")
        #expect(entry.credentialID == apiKeyID)
        // The route, not the credential: the credential has columns of its own
        // now, so the resource says what was being reached.
        #expect(entry.resourceType == "route")
        #expect(entry.resourceID == "POST /resource")
        #expect(entry.path == "/resource")
        #expect(entry.method == "POST")

        try await app.shutdownForTesting()
    }

    @Test("Write key can perform both read and write requests")
    func testWriteScopeAllowsReadAndWrite() async throws {
        let app = try await Application.makeForTesting()
        try await configure(app)
        try await app.autoMigrate()

        let user = try await createTestUser(on: app.db)
        let (_, fullKey) = try await createTestAPIKey(for: user, on: app.db, scopes: ["write"])
        registerScopedRoutes(on: app)

        try await app.test(
            .GET, "/resource",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fullKey)
            }
        ) { res async in
            #expect(res.status == .ok)
        }

        try await app.test(
            .POST, "/resource",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fullKey)
            }
        ) { res async in
            #expect(res.status == .ok)
            #expect(res.body.string == "write-ok")
        }

        try await app.shutdownForTesting()
    }

    @Test("Admin key can perform write requests")
    func testAdminScopeAllowsWrite() async throws {
        let app = try await Application.makeForTesting()
        try await configure(app)
        try await app.autoMigrate()

        let user = try await createTestUser(on: app.db)
        let (_, fullKey) = try await createTestAPIKey(for: user, on: app.db, scopes: ["admin"])
        registerScopedRoutes(on: app)

        try await app.test(
            .POST, "/resource",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fullKey)
            }
        ) { res async in
            #expect(res.status == .ok)
            #expect(res.body.string == "write-ok")
        }

        try await app.shutdownForTesting()
    }

    /// An explicitly restricted key is refused the identity plane whatever its
    /// action list says: minting a wider successor is the escalation the
    /// backstop exists for.
    @Test("An action-restricted key cannot mutate the identity plane")
    func testActionRestrictedKeyCannotMutateIdentityPlane() async throws {
        let app = try await Application.makeForTesting()
        try await configure(app)
        try await app.autoMigrate()

        let user = try await createTestUser(on: app.db)
        let restriction = try CredentialRestriction.validated(
            actions: ["vm:*"], nodeType: nil, nodeID: nil)
        let (_, fullKey) = try await createTestAPIKey(
            for: user, on: app.db, restriction: restriction)
        registerScopedRoutes(on: app)

        try await app.test(
            .POST, "/resource",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fullKey)
            }
        ) { res async in
            #expect(res.status == .forbidden)
        }

        try await app.shutdownForTesting()
    }

    @Test("A legacy scope array resolves to the restriction it always meant")
    func testLegacyScopesResolveToRestrictions() {
        let readOnly = APIKey(userID: UUID(), name: "k", keyHash: "h", keyPrefix: "p", scopes: ["read"])
        #expect(!readOnly.restriction.isUnrestricted)
        #expect(readOnly.restriction.permits(action: "vm:read"))
        #expect(!readOnly.restriction.permits(action: "vm:start"))

        for scopes in [["write"], ["admin"], ["read", "write"]] {
            let key = APIKey(userID: UUID(), name: "k", keyHash: "h", keyPrefix: "p", scopes: scopes)
            #expect(key.restriction.isUnrestricted, "\(scopes) should be unrestricted")
        }
    }

    @Test("Unknown scope strings do not grant access")
    func testUnknownScopesIgnored() {
        let bogus = APIKey(userID: UUID(), name: "k", keyHash: "h", keyPrefix: "p", scopes: ["superuser"])
        #expect(bogus.restriction == .denyAll)
        #expect(!bogus.restriction.permits(action: "vm:read"))
    }

    // MARK: - Hash Function Tests

    @Test("APIKey.hashAPIKey produces consistent hashes")
    func testHashConsistency() {
        let key = "sk_test_1234567890"
        let hash1 = APIKey.hashAPIKey(key)
        let hash2 = APIKey.hashAPIKey(key)

        #expect(hash1 == hash2)
    }

    @Test("APIKey.hashAPIKey produces different hashes for different keys")
    func testHashUniqueness() {
        let key1 = "sk_test_1234567890"
        let key2 = "sk_test_0987654321"

        let hash1 = APIKey.hashAPIKey(key1)
        let hash2 = APIKey.hashAPIKey(key2)

        #expect(hash1 != hash2)
    }

    @Test("APIKey.hashAPIKey produces valid SHA256 hash")
    func testHashFormat() {
        let key = "sk_test_1234567890"
        let hash = APIKey.hashAPIKey(key)

        // SHA256 hash should be 64 hexadecimal characters
        #expect(hash.count == 64)

        // Should only contain hexadecimal characters
        let hexCharacters = CharacterSet(charactersIn: "0123456789abcdef")
        let hashCharacters = CharacterSet(charactersIn: hash)
        #expect(hashCharacters.isSubset(of: hexCharacters))
    }

    // MARK: - API Key Generation Tests

    @Test("APIKey.generateAPIKey produces valid format")
    func testGenerateAPIKeyFormat() {
        let key = APIKey.generateAPIKey()

        #expect(key.hasPrefix("sk_"))
        #expect(key.count > 10)  // Should be reasonably long

        // Should have the format: sk_[prefix]_[key]
        let components = key.components(separatedBy: "_")
        #expect(components.count == 3)
        #expect(components[0] == "sk")
    }

    @Test("APIKey.generateAPIKey produces unique keys")
    func testGenerateAPIKeyUniqueness() {
        let key1 = APIKey.generateAPIKey()
        let key2 = APIKey.generateAPIKey()

        #expect(key1 != key2)
    }
}
