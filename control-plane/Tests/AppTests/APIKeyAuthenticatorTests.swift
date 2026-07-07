import Testing
import Vapor
import VaporTesting
import Fluent
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
        scopes: [String] = ["read", "write"]
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

    @Test("APIKeyAuthenticator rejects request without API key")
    func testMissingAPIKey() async throws {
        let app = try await Application.makeForTesting()

        try await configure(app)
        try await app.autoMigrate()

        // Create a test route that requires authentication
        app.routes.all.removeAll()
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

    @Test("Request isAPIKeyAuthenticated property works correctly")
    func testIsAPIKeyAuthenticated() async throws {
        let app = try await Application.makeForTesting()

        try await configure(app)
        try await app.autoMigrate()

        let user = try await createTestUser(on: app.db)
        let (_, fullKey) = try await createTestAPIKey(for: user, on: app.db)

        // This is a route-level unit test of the `isAPIKeyAuthenticated` request
        // property, including the *unauthenticated* branch. `configure` now installs
        // the global `SpiceDBAuthMiddleware` in every environment (issue #196), which
        // would 401 the no-key request below before it ever reaches the handler. Reset
        // the middleware stack to just error handling so the request-scoped
        // authenticator on the route group is the only auth in play.
        app.middleware = Middlewares()
        app.middleware.use(ErrorMiddleware.default(environment: app.environment))

        // Create a test route that checks isAPIKeyAuthenticated
        app.routes.all.removeAll()
        let protected = app.grouped(BearerAuthorizationHeaderAuthenticator())
        protected.get("test") { req -> String in
            return req.isAPIKeyAuthenticated ? "true" : "false"
        }

        try await app.test(
            .GET, "/test",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fullKey)
            }
        ) { res async in
            #expect(res.status == .ok)
            #expect(res.body.string == "true")
        }

        // Test without API key
        try await app.test(.GET, "/test") { res async in
            #expect(res.status == .ok)
            #expect(res.body.string == "false")
        }

        try await app.shutdownForTesting()
    }

    // MARK: - Scope Enforcement Tests

    /// Registers a read (GET) and a write (POST) route behind the bearer
    /// authenticator + scope middleware, mirroring the production pipeline.
    private func registerScopedRoutes(on app: Application) {
        app.routes.all.removeAll()
        let protected = app.grouped(
            BearerAuthorizationHeaderAuthenticator(),
            APIKeyScopeMiddleware()
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

    @Test("Read-only key is forbidden from write requests")
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

    @Test("APIKeyScope hierarchy grants higher scopes")
    func testScopeHierarchy() {
        let readOnly = APIKey(userID: UUID(), name: "k", keyHash: "h", keyPrefix: "p", scopes: ["read"])
        #expect(readOnly.grants(.read))
        #expect(!readOnly.grants(.write))
        #expect(!readOnly.grants(.admin))

        let writer = APIKey(userID: UUID(), name: "k", keyHash: "h", keyPrefix: "p", scopes: ["write"])
        #expect(writer.grants(.read))
        #expect(writer.grants(.write))
        #expect(!writer.grants(.admin))

        let admin = APIKey(userID: UUID(), name: "k", keyHash: "h", keyPrefix: "p", scopes: ["admin"])
        #expect(admin.grants(.read))
        #expect(admin.grants(.write))
        #expect(admin.grants(.admin))
    }

    @Test("APIKeyScope required(for:) maps methods to scopes")
    func testRequiredScopeForMethod() {
        #expect(APIKeyScope.required(for: .GET) == .read)
        #expect(APIKeyScope.required(for: .HEAD) == .read)
        #expect(APIKeyScope.required(for: .OPTIONS) == .read)
        #expect(APIKeyScope.required(for: .POST) == .write)
        #expect(APIKeyScope.required(for: .PUT) == .write)
        #expect(APIKeyScope.required(for: .PATCH) == .write)
        #expect(APIKeyScope.required(for: .DELETE) == .write)
    }

    @Test("Unknown scope strings do not grant access")
    func testUnknownScopesIgnored() {
        let bogus = APIKey(userID: UUID(), name: "k", keyHash: "h", keyPrefix: "p", scopes: ["superuser"])
        #expect(!bogus.grants(.read))
        #expect(!bogus.grants(.write))
        #expect(bogus.grantedScopes.isEmpty)
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
