import ControlPlanePostgres
import NIOCore
import NIOPosix
import PostgresNIO
import StratoShared
import Vapor
import VaporTesting

@testable import App

package struct TestAgentEnrollment: Sendable {
    package let id: UUID
    package let agentName: String
    package let trustDomain: String
    package let spiffeID: String
    package var bootstrapTokenHash: String?
    package var isUsed: Bool
    package let siteID: UUID?
    package let organizationID: UUID?
    package let organizationalUnitID: UUID?
    package var expiresAt: Date
    package let createdAt: Date?
    package var usedAt: Date?

    package init(
        id: UUID = UUID(),
        agentName: String,
        spiffeID: String,
        trustDomain: String = PlatformTrustDomain.current,
        bootstrapTokenHash: String? = nil,
        expirationHours: Int = 1,
        expiresAt: Date? = nil,
        siteID: UUID? = nil,
        organizationScope: OrganizationScope? = nil,
        isUsed: Bool = false,
        createdAt: Date? = nil,
        usedAt: Date? = nil
    ) {
        self.id = id
        self.agentName = agentName
        self.trustDomain = trustDomain
        self.spiffeID = spiffeID
        self.bootstrapTokenHash = bootstrapTokenHash
        self.isUsed = isUsed
        self.siteID = siteID
        self.organizationID = organizationScope?.organizationID
        self.organizationalUnitID = organizationScope?.organizationalUnitID
        self.expiresAt =
            expiresAt
            ?? Date().addingTimeInterval(TimeInterval(expirationHours * 3600))
        self.createdAt = createdAt
        self.usedAt = usedAt
    }

    package func requireID() -> UUID { id }

    package var isValid: Bool {
        bootstrapTokenHash != nil && !isUsed && expiresAt > Date()
    }

    package mutating func markAsUsed() {
        isUsed = true
        bootstrapTokenHash = nil
        usedAt = Date()
    }
}

@discardableResult
package func saveTestAgentEnrollment(
    _ enrollment: TestAgentEnrollment,
    on db: PostgresStoreContext
) async throws -> TestAgentEnrollment {
    let sql = try sqlDatabaseForTest(db)
    try await sql.raw(
        """
        INSERT INTO agent_enrollments (
            id, agent_name, trust_domain, spiffe_id, bootstrap_token_hash, is_used,
            site_id, organization_id, organizational_unit_id, expires_at, created_at, used_at
        ) VALUES (
            \(bind: enrollment.id), \(bind: enrollment.agentName),
            \(bind: enrollment.trustDomain), \(bind: enrollment.spiffeID),
            \(bind: enrollment.bootstrapTokenHash), \(bind: enrollment.isUsed),
            \(bind: enrollment.siteID), \(bind: enrollment.organizationID),
            \(bind: enrollment.organizationalUnitID), \(bind: enrollment.expiresAt),
            COALESCE(\(bind: enrollment.createdAt), CURRENT_TIMESTAMP),
            \(bind: enrollment.usedAt)
        )
        ON CONFLICT (id) DO UPDATE SET
            agent_name = EXCLUDED.agent_name,
            trust_domain = EXCLUDED.trust_domain,
            spiffe_id = EXCLUDED.spiffe_id,
            bootstrap_token_hash = EXCLUDED.bootstrap_token_hash,
            is_used = EXCLUDED.is_used,
            site_id = EXCLUDED.site_id,
            organization_id = EXCLUDED.organization_id,
            organizational_unit_id = EXCLUDED.organizational_unit_id,
            expires_at = EXCLUDED.expires_at,
            used_at = EXCLUDED.used_at
        """
    ).run()
    return enrollment
}

@discardableResult
package func seedTestAgentEnrollment(
    _ enrollment: TestAgentEnrollment,
    on db: PostgresStoreContext
) async throws -> TestAgentEnrollment {
    try await saveTestAgentEnrollment(enrollment, on: db)
}

package func findTestAgentEnrollment(
    _ id: UUID?,
    on db: PostgresStoreContext
) async throws -> TestAgentEnrollment? {
    guard let id else { return nil }
    let sql = try sqlDatabaseForTest(db)
    guard
        let row = try await sql.raw(
            """
            SELECT id, agent_name, trust_domain, spiffe_id, bootstrap_token_hash,
                   is_used, site_id, organization_id, organizational_unit_id,
                   expires_at, created_at, used_at
            FROM agent_enrollments WHERE id = \(bind: id)
            """
        ).first()
    else { return nil }
    return try decodeTestAgentEnrollment(row)
}

package func findTestAgentEnrollment(
    agentName: String,
    trustDomain: String? = nil,
    on db: PostgresStoreContext
) async throws -> TestAgentEnrollment? {
    let sql = try sqlDatabaseForTest(db)
    let row: PostgresStoreRow?
    if let trustDomain {
        row = try await sql.raw(
            """
            SELECT id, agent_name, trust_domain, spiffe_id, bootstrap_token_hash,
                   is_used, site_id, organization_id, organizational_unit_id,
                   expires_at, created_at, used_at
            FROM agent_enrollments
            WHERE agent_name = \(bind: agentName) AND trust_domain = \(bind: trustDomain)
            ORDER BY created_at DESC, id DESC LIMIT 1
            """
        ).first()
    } else {
        row = try await sql.raw(
            """
            SELECT id, agent_name, trust_domain, spiffe_id, bootstrap_token_hash,
                   is_used, site_id, organization_id, organizational_unit_id,
                   expires_at, created_at, used_at
            FROM agent_enrollments
            WHERE agent_name = \(bind: agentName)
            ORDER BY created_at DESC, id DESC LIMIT 1
            """
        ).first()
    }
    guard let row else { return nil }
    return try decodeTestAgentEnrollment(row)
}

package func testAgentEnrollmentCount(
    agentName: String? = nil,
    on db: PostgresStoreContext
) async throws -> Int {
    let sql = try sqlDatabaseForTest(db)
    if let agentName {
        return try await sql.raw(
            "SELECT COUNT(*) AS count FROM agent_enrollments WHERE agent_name = \(bind: agentName)"
        ).first(decodingColumn: "count", as: Int.self) ?? 0
    }
    return try await sql.raw("SELECT COUNT(*) AS count FROM agent_enrollments")
        .first(decodingColumn: "count", as: Int.self) ?? 0
}

private func decodeTestAgentEnrollment(_ row: PostgresStoreRow) throws -> TestAgentEnrollment {
    TestAgentEnrollment(
        id: try row.decode(column: "id", as: UUID.self),
        agentName: try row.decode(column: "agent_name", as: String.self),
        spiffeID: try row.decode(column: "spiffe_id", as: String.self),
        trustDomain: try row.decode(column: "trust_domain", as: String.self),
        bootstrapTokenHash: try row.decode(column: "bootstrap_token_hash", as: String?.self),
        expiresAt: try row.decode(column: "expires_at", as: Date.self),
        siteID: try row.decode(column: "site_id", as: UUID?.self),
        organizationScope: try {
            if let organizationID = try row.decode(column: "organization_id", as: UUID?.self) {
                return .organization(organizationID)
            }
            if let organizationalUnitID = try row.decode(
                column: "organizational_unit_id", as: UUID?.self)
            {
                return .organizationalUnit(organizationalUnitID)
            }
            return nil
        }(),
        isUsed: try row.decode(column: "is_used", as: Bool.self),
        createdAt: try row.decode(column: "created_at", as: Date?.self),
        usedAt: try row.decode(column: "used_at", as: Date?.self)
    )
}

package struct TestAccountClaim: Sendable {
    package let rawToken: String
    package let id: UUID
    package let userID: UUID
    package let tokenHash: String
    package let expiresAt: Date?
    package let claimedAt: Date?

    package func isValid(at now: Date = Date()) -> Bool {
        claimedAt == nil && expiresAt.map { now <= $0 } ?? true
    }
}

private func accountClaimTestDatabase(_ app: Application) -> PostgresStoreContext {
    app.testPostgres
}

/// Seed invitation states that cannot be reached through a public production
/// operation (expired, already consumed, or superseded claims). Production
/// behavior reads them through the native account-claim module.
@discardableResult
package func seedTestAccountClaim(
    userID: UUID,
    rawToken: String = AccountClaimSecret.generateToken(),
    expiresAt: Date? = Date().addingTimeInterval(3600),
    claimedAt: Date? = nil,
    createdByID: UUID? = nil,
    on app: Application
) async throws -> TestAccountClaim {
    let sql = accountClaimTestDatabase(app)
    let id = UUID()
    let tokenHash = AccountClaimSecret.hashToken(rawToken)
    try await sql.raw(
        """
        INSERT INTO account_claim_tokens (
            id, user_id, token_hash, token_prefix, expires_at, claimed_at,
            created_by_id, created_at
        ) VALUES (
            \(bind: id), \(bind: userID), \(bind: tokenHash),
            \(bind: AccountClaimSecret.extractPrefix(rawToken)),
            \(bind: expiresAt), \(bind: claimedAt), \(bind: createdByID),
            CURRENT_TIMESTAMP
        )
        """
    ).run()
    return TestAccountClaim(
        rawToken: rawToken,
        id: id,
        userID: userID,
        tokenHash: tokenHash,
        expiresAt: expiresAt,
        claimedAt: claimedAt
    )
}

package func consumeTestAccountClaim(
    id: UUID,
    at claimedAt: Date = Date(),
    on app: Application
) async throws {
    let sql = accountClaimTestDatabase(app)
    try await sql.raw(
        "UPDATE account_claim_tokens SET claimed_at = \(bind: claimedAt) WHERE id = \(bind: id)"
    ).run()
}

package func testAccountClaimCount(on app: Application) async throws -> Int {
    struct Count: Decodable { let value: Int }
    let sql = accountClaimTestDatabase(app)
    return try await sql.raw("SELECT COUNT(*)::int AS value FROM account_claim_tokens")
        .first(decoding: Count.self)?.value ?? 0
}

package func testAccountClaims(on app: Application) async throws -> [TestAccountClaim] {
    struct Row: Decodable {
        let id: UUID
        let userID: UUID
        let tokenHash: String
        let expiresAt: Date?
        let claimedAt: Date?

        private enum CodingKeys: String, CodingKey {
            case id
            case userID = "user_id"
            case tokenHash = "token_hash"
            case expiresAt = "expires_at"
            case claimedAt = "claimed_at"
        }
    }
    let sql = accountClaimTestDatabase(app)
    return try await sql.raw(
        "SELECT id, user_id, token_hash, expires_at, claimed_at FROM account_claim_tokens ORDER BY created_at"
    ).all(decoding: Row.self).map {
        TestAccountClaim(
            rawToken: "",
            id: $0.id,
            userID: $0.userID,
            tokenHash: $0.tokenHash,
            expiresAt: $0.expiresAt,
            claimedAt: $0.claimedAt
        )
    }
}

package func findTestAccountClaim(
    rawToken: String,
    on app: Application
) async throws -> TestAccountClaim? {
    let hash = AccountClaimSecret.hashToken(rawToken)
    return try await testAccountClaims(on: app).first { $0.tokenHash == hash }.map {
        TestAccountClaim(
            rawToken: rawToken,
            id: $0.id,
            userID: $0.userID,
            tokenHash: $0.tokenHash,
            expiresAt: $0.expiresAt,
            claimedAt: $0.claimedAt
        )
    }
}

/// Enroll a persistence-valid passkey fixture through the same native module
/// production uses. Cryptographic ceremony verification belongs to the
/// WebAuthn service and is intentionally outside persistence tests.
@discardableResult
package func createTestPasskey(
    userID: UUID,
    on app: Application,
    credentialID: Data = Data(UUID().uuidString.utf8),
    publicKey: Data = Data("test-public-key".utf8),
    name: String? = nil
) async throws -> PasskeySnapshot {
    let challenge = "test-passkey-\(UUID())"
    _ = try await app.passkeysPersistence.storeChallenge(
        challenge,
        userID: userID,
        operation: "test_fixture"
    )
    return try await app.passkeysPersistence.registerCredential(
        challenge: challenge,
        operation: "test_fixture",
        expectedUserID: userID,
        credential: PasskeyWrite(
            credentialID: credentialID,
            publicKey: publicKey,
            name: name
        )
    )
}

// MARK: - Test PostgresStoreContext Templates
//
// The suite runs against Postgres — the engine production uses — so migrations
// and Postgres-specific SQL are validated everywhere, not just in CI (issue
// #195; the former SQLite backend was removed because nothing used it and its
// CI leg doubled suite runtime). Connection parameters come from the standard
// `DATABASE_*` env vars, defaulting to localhost:5432, strato/strato_password,
// anchor database strato_test — matching `docker run -e POSTGRES_DB=strato_test
// -e POSTGRES_USER=strato -e POSTGRES_PASSWORD=strato_password ...`.
//
// Booting a test app used to replay every migration up (via `configure()`'s
// trailing `autoMigrate()`) against an empty database, and most teardowns
// replayed them all back down with `autoRevert()` — two full migration passes
// per test, which dominated suite runtime. Instead, migrations run ONCE per
// test process into a template database, and every test gets a cheap
// server-side clone of the migrated result via
// `CREATE DATABASE ... TEMPLATE ...`.
//
// `configure(app)` still calls `autoMigrate()` in every test, but against a
// pre-migrated clone that is a no-op scan of the migration log. Full up/down
// migration coverage lives in MigrationRoundTripTests.

private let testProcessID = ProcessInfo.processInfo.processIdentifier

/// Whether the test process that embedded `pid` in a leftover database's name
/// is still alive on this machine (a parallel run in another worktree we must
/// not disturb). Anything else is debris from a finished or crashed run.
private func isTestProcessAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}

/// Builds the per-process Postgres template database and hands out per-test
/// clones of it, serializing all CREATE/DROP DATABASE statements through a
/// single admin connection: `CREATE DATABASE ... TEMPLATE` requires that the
/// template has no other users, so clones must be minted one at a time.
package actor PostgresTestDatabases {
    package static let shared = PostgresTestDatabases()

    /// Small event-loop group shared by every test app in the suite. Native
    /// application pools are independently capped at one connection.
    package static let appEventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)

    package static func nativeConfiguration(database: String) throws
        -> ControlPlanePostgres.PostgresDatabase.Configuration
    {
        try .init(
            hostname: Environment.get("DATABASE_HOST") ?? "localhost",
            port: Environment.get("DATABASE_PORT").flatMap(Int.init(_:))
                ?? 5432,
            username: Environment.get("DATABASE_USERNAME") ?? "strato",
            password: Environment.get("DATABASE_PASSWORD") ?? "strato_password",
            database: database,
            tls: .disable,
            maximumConnections: 1,
            connectionAcquireTimeout: .seconds(10),
            statementTimeoutMilliseconds: 300_000
        )
    }

    private static let logger: Logger = {
        var logger = Logger(label: "strato.test.pg-admin")
        logger.logLevel = .error
        return logger
    }()

    private let templateName = "strato_test_tpl_\(testProcessID)"
    private var connection: PostgresConnection?
    private var template: Task<Void, Error>?
    /// FIFO chain serializing admin statements; actor methods interleave at
    /// suspension points, so ordering needs an explicit chain, not just `self`.
    private var lastAdminOperation: Task<Void, Never>?

    /// Mint a fresh clone of the migrated template for one test.
    package func createDatabaseForTest() async throws -> String {
        if template == nil {
            template = Task { try await self.buildTemplate() }
        }
        try await template!.value

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let name = "strato_test_db_\(testProcessID)_\(suffix)"
        try await run(#"CREATE DATABASE "\#(name)" TEMPLATE "\#(templateName)""#)
        return name
    }

    /// Mint an EMPTY database (no migrations applied) for tests that need to
    /// build legacy schemas by hand before running a single migration — the
    /// migrated template has every migration pre-applied, which makes
    /// before/after tests impossible. Shares the clone namespace so teardown
    /// (`dropDatabase`) and the dead-run sweep cover these too.
    package func createBareDatabaseForTest() async throws -> String {
        // Await the template build even though its result is unused: every
        // other admin statement is serialized behind it, and buildTemplate()'s
        // internal queries (`allDatabaseNames`) run outside the FIFO chain.
        // Racing it here would mint a second admin connection and drop the
        // first unclosed — PostgresNIO asserts on that.
        if template == nil {
            template = Task { try await self.buildTemplate() }
        }
        try await template!.value

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let name = "strato_test_db_\(testProcessID)_\(suffix)"
        try await run(#"CREATE DATABASE "\#(name)""#)
        return name
    }

    /// Destroy one test's clone. Best effort — leftovers are swept by the
    /// next run's buildTemplate().
    package func dropDatabase(_ name: String) async {
        try? await run(#"DROP DATABASE IF EXISTS "\#(name)" WITH (FORCE)"#)
    }

    private func buildTemplate() async throws {
        // On a disposable CI Postgres, trade durability for speed. Each test mints a
        // clone via CREATE DATABASE ... TEMPLATE, which is checkpoint/fsync-bound;
        // these settings remove the syncs. Safe because a crashed CI Postgres is just
        // a rerun. (All three are SIGHUP-reloadable; strato is a superuser.)
        //
        // ALTER SYSTEM is cluster-wide and persists in postgresql.auto.conf, so it is
        // gated behind an explicit opt-in that only the ephemeral CI service sets — a
        // developer pointing DATABASE_* at a local/shared cluster must never silently
        // disable durability for unrelated databases.
        if Environment.get("STRATO_TEST_DISPOSABLE_POSTGRES") == "1" {
            try await run("ALTER SYSTEM SET fsync = off")
            try await run("ALTER SYSTEM SET synchronous_commit = off")
            try await run("ALTER SYSTEM SET full_page_writes = off")
            try await run("SELECT pg_reload_conf()")
        }

        // Sweep templates and clones left by dead runs (crashed teardowns,
        // killed processes); skip names whose embedded pid is still alive —
        // that's a parallel run in another worktree sharing this server.
        for name in try await allDatabaseNames() {
            let pidText: Substring
            if name.hasPrefix("strato_test_tpl_") {
                pidText = name.dropFirst("strato_test_tpl_".count)
            } else if name.hasPrefix("strato_test_db_") {
                pidText = name.dropFirst("strato_test_db_".count).prefix(while: { $0 != "_" })
            } else {
                continue
            }
            if let pid = Int32(pidText), pid != testProcessID, isTestProcessAlive(pid) { continue }
            try await run(#"DROP DATABASE IF EXISTS "\#(name)" WITH (FORCE)"#)
        }

        try await run(#"CREATE DATABASE "\#(templateName)""#)

        // Boot a throwaway app against the template: configure() registers
        // every migration and its trailing autoMigrate() applies them. The app
        // is shut down before the first clone, so the template has no live
        // sessions when CREATE DATABASE reads it.
        var env = Environment.testing
        env.arguments = ["vapor"]
        let app = try await Application.make(env, .shared(Self.appEventLoopGroup))
        app.logger.logLevel = .error
        app.nativePostgresConfigurationOverride = try Self.nativeConfiguration(database: templateName)
        do {
            try await configure(app)
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    private func allDatabaseNames() async throws -> [String] {
        let connection = try await adminConnection()
        let rows = try await connection.query(
            PostgresQuery(unsafeSQL: "SELECT datname FROM pg_database WHERE NOT datistemplate"),
            logger: Self.logger
        )
        var names: [String] = []
        for try await row in rows {
            names.append(try row.decode(String.self))
        }
        return names
    }

    /// Run one admin statement strictly after every previously enqueued one.
    private func run(_ sql: String) async throws {
        let previous = lastAdminOperation
        let operation = Task {
            await previous?.value
            let connection = try await self.adminConnection()
            let rows = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: Self.logger)
            for try await _ in rows {}  // drain to completion
        }
        lastAdminOperation = Task { try? await operation.value }
        do {
            try await operation.value
        } catch {
            // The connection may have died; discard it so the next statement
            // reconnects. (Plain SQL failures pay a harmless reconnect.)
            if let connection {
                self.connection = nil
                try? await connection.close()
            }
            throw error
        }
    }

    private func adminConnection() async throws -> PostgresConnection {
        if let connection, !connection.isClosed { return connection }
        let configuration = PostgresConnection.Configuration(
            host: Environment.get("DATABASE_HOST") ?? "localhost",
            port: Environment.get("DATABASE_PORT").flatMap(Int.init(_:))
                ?? 5432,
            username: Environment.get("DATABASE_USERNAME") ?? "strato",
            password: Environment.get("DATABASE_PASSWORD") ?? "strato_password",
            database: Environment.get("DATABASE_NAME") ?? "strato_test",
            tls: .disable
        )
        let connection = try await PostgresConnection.connect(
            on: Self.appEventLoopGroup.next(),
            configuration: configuration,
            id: 0,
            logger: Self.logger
        )
        self.connection = connection
        return connection
    }
}

// MARK: - Test Extensions

extension Application {
    package static func makeForTesting(_ environment: Environment = .testing) async throws -> Application {
        var env = environment
        env.arguments = ["vapor"]

        // Each test gets its own server-side clone of the migrated template
        // database.
        let databaseName = try await PostgresTestDatabases.shared.createDatabaseForTest()
        return try await make(env, database: databaseName)
    }

    /// Like `makeForTesting`, but on an EMPTY database with no migrations
    /// applied — for migration before/after tests that hand-build legacy
    /// schemas. Tear down with `shutdownForTesting()` as usual.
    package static func makeForBareDatabaseTesting(_ environment: Environment = .testing) async throws
        -> Application
    {
        var env = environment
        env.arguments = ["vapor"]

        let databaseName = try await PostgresTestDatabases.shared.createBareDatabaseForTest()
        return try await make(env, database: databaseName)
    }

    /// Boot an application against a database the caller already minted, so more
    /// than one application can share one schema — what a concurrent-boot test
    /// needs and what every other fixture deliberately prevents.
    ///
    /// Exactly one application should be the `owningDatabase` one: only that
    /// one's `shutdownForTesting()` drops the clone, and it must be the last to
    /// go (the drop is `WITH (FORCE)`, so it would kill a sibling's connections).
    /// Shut the others down with plain `asyncShutdown()` first.
    package static func makeForTesting(
        database databaseName: String,
        owningDatabase: Bool,
        _ environment: Environment = .testing
    ) async throws -> Application {
        var env = environment
        env.arguments = ["vapor"]
        return try await make(env, database: databaseName, owningDatabase: owningDatabase)
    }

    private static func make(
        _ env: Environment,
        database databaseName: String,
        owningDatabase: Bool = true
    ) async throws -> Application {
        let app = try await Application.make(env, .shared(PostgresTestDatabases.appEventLoopGroup))
        app.logger.logLevel = .debug
        app.nativePostgresConfigurationOverride = try PostgresTestDatabases.nativeConfiguration(
            database: databaseName)
        if owningDatabase {
            app.storage[TestDatabaseNameKey.self] = databaseName
        }
        return app
    }
}

// Storage key for the per-test Postgres database clone's name
package struct TestDatabaseNameKey: StorageKey {
    package typealias Value = String
}

extension Application {
    /// Tear down an app made by `makeForTesting`: shut Vapor down (closing its
    /// database pool), then destroy the test's database clone.
    package func shutdownForTesting() async throws {
        let databaseName = storage[TestDatabaseNameKey.self]

        try await asyncShutdown()

        if let databaseName {
            await PostgresTestDatabases.shared.dropDatabase(databaseName)
        }
    }
}

// Helper function to run tests with proper database lifecycle. configure()
// runs autoMigrate(), which is a no-op scan against the pre-migrated clone.
/// A symbolic analyzer that proves nothing and objects to nothing.
///
/// Installed by `withTestApp` so the suites that merely *write bindings* do
/// not each need an SMT solver on the machine. Tests that are about the
/// write-time ceiling check replace it with the real `SymCCGuardrailAnalyzer`;
/// production never sees it, since the only construction site is here.
package struct PermissiveGuardrailAnalyzer: GuardrailAnalyzer {
    package init() {}

    package func disjoint(
        schemaText: String,
        _ a: [CedarPolicySource],
        _ b: [CedarPolicySource],
        in environment: CedarRequestEnvironment
    ) async throws -> GuardrailAnalysis {
        GuardrailAnalysis(holds: true, counterexample: nil)
    }

    package func implies(
        schemaText: String,
        _ a: [CedarPolicySource],
        _ b: [CedarPolicySource],
        in environment: CedarRequestEnvironment
    ) async throws -> GuardrailAnalysis {
        GuardrailAnalysis(holds: true, counterexample: nil)
    }
}

package func withTestApp(_ test: (Application) async throws -> Void) async throws {
    let app = try await Application.makeForTesting()

    do {
        try await configure(app)
        app.guardrailAnalyzer = PermissiveGuardrailAnalyzer()
        try await test(app)
    } catch {
        try? await app.shutdownForTesting()
        throw error
    }

    try await app.shutdownForTesting()
}

// Historical alias: the two helpers only differed in a teardown-time
// autoRevert(), which per-test database clones made obsolete.
package func withApp(_ test: (Application) async throws -> Void) async throws {
    try await withTestApp(test)
}

extension User {
    package func generateToken() throws -> String {
        // In a real implementation, this would create a proper session/token
        // For testing, we'll use a simple token
        return "test-token-\(self.id?.uuidString ?? UUID().uuidString)"
    }

    package func generateAPIKey(
        on app: Application,
        name: String = "Test API Key",
        restriction: CredentialRestriction = .unrestricted
    ) async throws -> String {
        let apiKeyString = APIKeyCredential.generate()
        let keyHash = APIKeyCredential.hash(apiKeyString)
        let keyPrefix = String(apiKeyString.prefix(16))

        _ = try await app.apiKeysPersistence.issue(
            APIKeyWrite(
                userID: self.id!,
                name: name,
                keyHash: keyHash,
                keyPrefix: keyPrefix,
                restriction: restriction.stored
            ),
            maximumKeysPerUser: 10
        )

        return apiKeyString
    }
}

// MARK: - Test Data Builders

/// Immutable test-facing view of a persisted group. The optional `id` shape
/// keeps older fixture call sites readable while the backing write and every
/// subsequent operation use the production PostgresNIO module.
package struct TestGroup: Sendable {
    package let snapshot: GroupSnapshot

    package var id: UUID? { snapshot.id }
    package var name: String { snapshot.name }
    package var description: String { snapshot.description }
    package var organizationID: UUID { snapshot.organizationID }

    package func requireID() -> UUID { snapshot.id }
}

package struct TestDataBuilder {
    package let db: PostgresStoreContext
    private let groups: GroupsPersistence?
    private let floatingIPPools: FloatingIPPoolsPersistence?

    package init(db: PostgresStoreContext) {
        self.db = db
        self.groups = nil
        self.floatingIPPools = nil
    }

    /// Use this initializer for fixtures that exercise migrated persistence.
    /// It keeps the existing Fluent builder surface available to unmigrated
    /// cohorts while routing group intent through the production module.
    package init(app: Application) {
        self.db = app.testPostgres
        self.groups = app.groupsPersistence
        self.floatingIPPools = app.floatingIPPoolsPersistence
    }

    package func createFloatingIPPool(
        name: String,
        cidr: String,
        gateway: String? = nil,
        siteID: UUID,
        organizationID: UUID? = nil,
        organizationalUnitID: UUID? = nil
    ) async throws -> FloatingIPPoolSnapshot {
        guard let floatingIPPools else {
            throw Abort(.internalServerError, reason: "Native floating-IP pool persistence is unavailable")
        }
        switch try await floatingIPPools.create(FloatingIPPoolWrite(
            name: name,
            cidr: cidr,
            gateway: gateway,
            siteID: siteID,
            organizationID: organizationID,
            organizationalUnitID: organizationalUnitID
        )) {
        case .created(let pool): return pool
        case .siteNotFound: throw Abort(.internalServerError, reason: "Fixture site does not exist")
        case .scopeNotFound: throw Abort(.internalServerError, reason: "Fixture scope does not exist")
        case .overlaps(let name, let cidr):
            throw Abort(.internalServerError, reason: "Fixture pool overlaps \(name) (\(cidr))")
        case .duplicateName: throw Abort(.internalServerError, reason: "Fixture pool name is duplicated")
        }
    }

    package func createUser(
        username: String = "testuser",
        email: String = "test@example.com",
        displayName: String = "Test User",
        isSystemAdmin: Bool = false
    ) async throws -> User {
        let user = User(
            username: username,
            email: email,
            displayName: displayName,
            isSystemAdmin: isSystemAdmin
        )
        try await user.save(on: db)
        return user
    }

    package func createOrganization(
        name: String = "Test Organization",
        description: String = "Test organization"
    ) async throws -> Organization {
        let org = Organization(
            name: name,
            description: description
        )
        try await org.save(on: db)
        return org
    }

    package func addUserToOrganization(
        user: User,
        organization: Organization,
        role: String = "member"
    ) async throws {
        let roleID: UUID?
        switch role {
        case "member": roleID = nil
        case "viewer": roleID = IAMRole.viewer.seededID
        case "operator": roleID = IAMRole.operator.seededID
        case "editor": roleID = IAMRole.editor.seededID
        case "admin": roleID = IAMRole.admin.seededID
        default:
            guard let customRoleID = UUID(uuidString: role) else {
                throw TestSetupError.message("Unknown organization role fixture '\(role)'")
            }
            roleID = customRoleID
        }
        guard let sql = Optional(db) else {
            throw TestSetupError.message("Organization membership fixtures require PostgreSQL")
        }
        try await sql.raw(
            """
            INSERT INTO user_organizations (id, user_id, organization_id, role_id, created_at)
            VALUES (
                \(bind: UUID()), \(bind: user.id!), \(bind: organization.id!),
                \(bind: roleID), CURRENT_TIMESTAMP
            )
            """
        ).run()

        // Organization membership remains relational, while any role grant is
        // represented only by its authoritative binding.
        if let roleID {
            try await RoleBindingService.grant(
                principalType: .user,
                principalID: user.id!,
                roleID: roleID,
                nodeType: .organization,
                nodeID: organization.id!,
                createdBy: nil,
                on: db
            )
        }
    }

    package func createOU(
        name: String,
        description: String,
        organization: Organization,
        parentOU: OrganizationalUnit? = nil
    ) async throws -> OrganizationalUnit {
        var ou = OrganizationalUnit(
            name: name,
            description: description,
            organizationID: organization.id!,
            parentOUID: parentOU?.id,
            path: "",
            depth: parentOU != nil ? (parentOU!.depth + 1) : 0
        )
        try await ou.save(on: db)
        ou = OrganizationalUnit(
            id: ou.id, name: ou.name, description: ou.description,
            organizationID: ou.organizationID, parentOUID: ou.parentOUID,
            path: try await ou.buildPath(on: db), depth: ou.depth,
            createdAt: ou.createdAt, updatedAt: ou.updatedAt)
        try await ou.save(on: db)
        return ou
    }

    /// Reuses an organization's test site, or creates one when the fixture has
    /// not needed site-scoped infrastructure yet.
    package func placementSite(for project: Project) async throws -> Site {
        guard let organizationID = try await project.getRootOrganizationId(on: db) else {
            throw Abort(.internalServerError, reason: "Test project has no owning organization")
        }
        if let existing = try await LegacySiteStore.sites(
            organizationID: organizationID,
            on: db
        ).first {
            return existing
        }
        let site = Site(
            name: "Test Site \(organizationID.uuidString)",
            organizationScope: .organization(organizationID)
        )
        try await site.save(on: db)
        return site
    }

    /// A logical network in `project`. Nothing provisions one automatically
    /// (issue #765), so any fixture whose workloads need a network must make
    /// one — and two projects may safely share a name and a subnet.
    @discardableResult
    package func createNetwork(
        name: String = "default",
        project: Project,
        subnet: String = "192.168.1.0/24",
        gateway: String? = "192.168.1.1",
        subnet6: String? = nil,
        gateway6: String? = nil,
        dhcpEnabled: Bool = true,
        externalAccess: Bool = true,
        site: Site? = nil
    ) async throws -> LogicalNetwork {
        let resolvedSite: Site
        if let site {
            resolvedSite = site
        } else {
            resolvedSite = try await placementSite(for: project)
        }
        let network = LogicalNetwork(
            name: name,
            subnet: subnet,
            gateway: gateway,
            subnet6: subnet6,
            gateway6: gateway6,
            projectID: try project.requireID(),
            dhcpEnabled: dhcpEnabled,
            externalAccess: externalAccess,
            siteID: try resolvedSite.requireID()
        )
        try await network.save(on: db)
        return network
    }

    package func createProject(
        name: String,
        description: String,
        organization: Organization? = nil,
        ou: OrganizationalUnit? = nil,
        environments: [String] = ["development", "staging", "production"],
        defaultEnvironment: String = "development"
    ) async throws -> Project {
        var project = Project(
            name: name,
            description: description,
            organizationID: organization?.id,
            organizationalUnitID: ou?.id,
            path: "",
            defaultEnvironment: defaultEnvironment,
            environments: environments
        )
        try await project.save(on: db)
        project = project.replacingPath(try await project.buildPath(on: db))
        try await project.save(on: db)
        return project
    }

    package func createGroup(
        name: String,
        description: String,
        organization: Organization
    ) async throws -> TestGroup {
        guard let groups else {
            preconditionFailure("Group fixtures require TestDataBuilder(app:)")
        }
        return TestGroup(
            snapshot: try await groups.create(GroupWrite(
                organizationID: try organization.requireID(),
                name: name,
                description: description
            ))
        )
    }

    package func addUserToGroup(user: User, group: TestGroup) async throws {
        guard let groups else {
            preconditionFailure("Group fixtures require TestDataBuilder(app:)")
        }
        let result = try await groups.addMembers(
            [try user.requireID()],
            to: group.requireID(),
            organizationID: group.organizationID
        )
        guard result.groupFound else {
            throw TestSetupError.message("Cannot add a fixture member to a group that does not exist")
        }
        guard result.ineligibleUserIDs.isEmpty else {
            throw TestSetupError.message(
                "Group fixture users must belong to the group's organization"
            )
        }
    }

    package func createResourceQuota(
        name: String,
        maxVCPUs: Int = 10,
        maxMemoryGB: Double = 20.0,
        maxStorageGB: Double = 100.0,
        maxVMs: Int = 5,
        maxNetworks: Int = 10,
        organization: Organization? = nil,
        ou: OrganizationalUnit? = nil,
        project: Project? = nil,
        environment: String? = nil
    ) async throws -> ResourceQuota {
        let quota = ResourceQuota(
            name: name,
            organizationID: organization?.id,
            organizationalUnitID: ou?.id,
            projectID: project?.id,
            maxVCPUs: maxVCPUs,
            maxMemory: Int64(maxMemoryGB * 1024 * 1024 * 1024),
            maxStorage: Int64(maxStorageGB * 1024 * 1024 * 1024),
            maxVMs: maxVMs,
            maxNetworks: maxNetworks,
            environment: environment
        )
        try await quota.save(on: db)
        return quota
    }

    package func createVM(
        name: String,
        project: Project,
        environment: String = "development",
        image: String = "test-image"
    ) async throws -> VM {
        let vm = VM(
            name: name,
            description: "Test VM",
            image: image,
            projectID: project.id!,
            environment: environment,
            cpu: 2,
            memory: 2 * 1024 * 1024 * 1024,
            disk: 10 * 1024 * 1024 * 1024
        )
        try await vm.save(on: db)
        return vm
    }

    package func createSandbox(
        name: String,
        project: Project,
        environment: String = "development",
        image: String = "ghcr.io/acme/worker:v1"
    ) async throws -> Sandbox {
        let sandbox = Sandbox(
            name: name,
            projectID: project.id!,
            environment: environment,
            image: image,
            cpus: 1,
            memory: 1024 * 1024 * 1024
        )
        try await sandbox.save(on: db)
        return sandbox
    }

    /// A saved volume, for the suites that only need one to exist (STR-181's
    /// quota accounting, mostly). Suites that drive convergence keep their own
    /// richer builders — this one sets no agent, path or attachment.
    package func createVolume(
        name: String,
        project: Project,
        environment: String = "development",
        sizeGB: Int = 10,
        status: VolumeStatus = .available,
        createdBy: User
    ) async throws -> Volume {
        let volume = Volume(
            name: name,
            description: "Test volume",
            projectID: try project.requireID(),
            environment: environment,
            size: Int64(sizeGB) * 1024 * 1024 * 1024,
            status: status,
            createdByID: try createdBy.requireID()
        )
        try await volume.save(on: db)
        return volume
    }

    package func createImage(
        name: String = "Test Image",
        description: String = "Test image description",
        project: Project,
        filename: String = "test.qcow2",
        size: Int64 = 10 * 1024 * 1024,
        format: ImageFormat = .qcow2,
        status: ImageStatus = .ready,
        uploadedBy: User,
        storagePath: String? = nil,
        sourceURL: String? = nil,
        checksum: String? = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    ) async throws -> Image {
        let projectID = try project.requireID()
        let image = Image(
            name: name,
            description: description,
            projectID: projectID,
            status: status,
            uploadedByID: uploadedBy.id!
        )
        try await image.save(on: db)

        var result = image
        if status == .ready || storagePath != nil || sourceURL != nil {
            let imageID = try image.requireID()
            let artifact = try await LegacyImageArtifactStore.insert(
                imageID: imageID,
                kind: .diskImage,
                format: format,
                architecture: image.architecture,
                filename: filename,
                size: size,
                checksum: checksum ?? "",
                storagePath: storagePath
                    ?? ImageObjectKey.artifact(
                        projectId: projectID,
                        imageId: imageID,
                        kind: "disk-image",
                        filename: filename),
                status: status == .ready ? .ready : .pending,
                sourceURL: sourceURL,
                expectedChecksum: status == .ready ? nil : checksum,
                on: db
            )
            result = image.loading(artifacts: [artifact])
        }
        return result
    }
}

// MARK: - Mock Image Fetch Service

/// Mock ImageFetchService that does nothing (prevents real HTTP requests in tests)
package actor MockImageFetchService: ImageFetchServiceProtocol {
    package var startedArtifactFetches: [UUID] = []

    package init() {}

    package func startArtifactFetch(artifactId: UUID) async throws {
        startedArtifactFetches.append(artifactId)
        // No-op: don't actually fetch anything
    }
}

// MARK: - Conditioned role bindings

/// Run `body` with the STR-108 write boundary lifted, then put it back.
///
/// Conditions are not implemented, so the evaluator skips a conditioned binding
/// and it grants nothing. That skip is the defence in depth behind the
/// constraint, and the only way to exercise it is to reproduce the one way such
/// a row can still appear: a write against a database whose constraint predates
/// or outlives this deployment. Dropping the constraint is safe because every
/// test runs against its own clone of the migrated template, which teardown
/// destroys.
///
/// The restore is what makes it scoped rather than remembered: leaving the
/// boundary down for the rest of the test would let a later assertion that a
/// conditioned write is refused pass vacuously. It comes back `NOT VALID`,
/// since any row `body` wrote would fail the re-scan a validating `ADD
/// CONSTRAINT` performs — which is exactly the state being simulated: new
/// writes refused, one legacy row already present.
///
/// (`Application.makeForBareDatabaseTesting()` is the house pattern for
/// migration before/after tests that hand-build a legacy schema. This does not
/// use it: the only difference from the current schema is one constraint, and
/// dropping it in place also exercises the migration's idempotent
/// drop-then-add.)
package func withConditionedRoleBindingsAllowed<T>(
    on db: PostgresStoreContext,
    _ body: () async throws -> T
) async throws -> T {
    let sql = try sqlDatabaseForTest(db)
    let constraint = conditionedRoleBindingConstraintName
    try await sql.raw(
        "ALTER TABLE \"role_bindings\" DROP CONSTRAINT IF EXISTS \(unsafeRaw: constraint)"
    ).run()

    func restore() async throws {
        try await sql.raw(
            """
            ALTER TABLE "role_bindings" ADD CONSTRAINT \(unsafeRaw: constraint)
            CHECK ("condition" IS NULL) NOT VALID
            """
        ).run()
    }

    do {
        let result = try await body()
        try await restore()
        return result
    } catch {
        try? await restore()
        throw error
    }
}

/// Write a `role_bindings` row carrying a `condition` — which the schema
/// otherwise refuses (STR-108) — leaving the
/// boundary in place for everything after it. See
/// `withConditionedRoleBindingsAllowed`.
package func insertConditionedRoleBinding(
    principalType: IAMPrincipalType,
    principalID: UUID,
    role: IAMRole,
    nodeType: IAMNodeType,
    nodeID: UUID,
    condition: String,
    on db: PostgresStoreContext
) async throws {
    try await withConditionedRoleBindingsAllowed(on: db) {
        let sql = try sqlDatabaseForTest(db)
        try await sql.raw(
            """
            INSERT INTO role_bindings (
                id, principal_type, principal_id, role_id, node_type, node_id,
                condition, created_at
            ) VALUES (
                \(bind: UUID()), \(bind: principalType.rawValue), \(bind: principalID),
                \(bind: role.seededID), \(bind: nodeType.rawValue), \(bind: nodeID),
                \(bind: condition), CURRENT_TIMESTAMP
            )
            """
        ).run()
    }
}

/// The state of the STR-108 write boundary on `role_bindings`.
package enum ConditionedRoleBindingConstraintState: Equatable, Sendable {
    /// No constraint: a conditioned row can be written.
    case absent
    /// Present but unvalidated — new writes are refused, existing rows were
    /// never scanned. What `withConditionedRoleBindingsAllowed` restores.
    case notValidated
    /// Present and validated, which Postgres only permits when no conditioned
    /// row survives.
    case validated
}

package func conditionedRoleBindingConstraint(
    on db: PostgresStoreContext
) async throws -> ConditionedRoleBindingConstraintState {
    let sql = try sqlDatabaseForTest(db)
    let rows = try await sql.raw(
        """
        SELECT convalidated FROM pg_constraint
        WHERE conrelid = 'role_bindings'::regclass
          AND conname = \(bind: conditionedRoleBindingConstraintName)
        """
    ).all()
    guard let row = rows.first else { return .absent }
    return try row.decode(column: "convalidated", as: Bool.self) ? .validated : .notValidated
}

/// Whether the schema refuses a conditioned write — either constraint state
/// does, validated or not.
package func conditionedRoleBindingsAreRefused(on db: PostgresStoreContext) async throws -> Bool {
    try await conditionedRoleBindingConstraint(on: db) != .absent
}

private let conditionedRoleBindingConstraintName = "ck_role_bindings_condition_unsupported"

/// Give a saved test volume its authoritative physical placement. Passing no
/// agent deliberately leaves the volume unplaced for tests that exercise that
/// state.
package func placeVolume(
    _ volume: Volume,
    on agentID: String?,
    at filePath: String? = "/var/lib/strato/volumes/test/volume.qcow2",
    state: VolumeReplicaState = .healthy,
    using db: PostgresStoreContext
) async throws {
    guard let agentID else { return }
    let diskAttachment: DiskAttachment? = filePath.map {
            .file(
                path: $0,
                format: $0.lowercased().hasSuffix(".raw") ? .raw : .qcow2)
        }
    let attachmentJSON = try diskAttachment.map {
        String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
    }
    try await sqlDatabaseForTest(db).raw(
        """
        INSERT INTO volume_replicas (
            id, volume_id, agent_id, disk_attachment, state, generation,
            created_at, updated_at
        ) VALUES (
            \(bind: UUID()), \(bind: try volume.requireID()), \(bind: agentID),
            CAST(\(bind: attachmentJSON) AS jsonb), \(bind: state.rawValue),
            \(bind: volume.observedGeneration), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        )
        """
    ).run()
}

private func sqlDatabaseForTest(_ db: PostgresStoreContext) throws -> PostgresStoreContext {
    db
}

package enum TestSetupError: Error, CustomStringConvertible {
    case message(String)

    package var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

// MARK: - Agent identity keys

/// The key an agent registered under the bare name `name` is stored beneath in
/// the connection map, the coordination presence/route keys, and console/exec
/// session ownership: its full SPIFFE ID in the platform trust domain
/// (issue #613). Tests that register an agent by name and then assert on one of
/// those registries must go through this rather than the bare name.
package func agentKey(_ name: String) -> String {
    AgentIdentity(trustDomain: PlatformTrustDomain.current, name: name).key
}
