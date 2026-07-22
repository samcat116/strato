import Fluent
import FluentPostgresDriver
import NIOCore
import NIOPosix
import PostgresNIO
import SQLKit
import Vapor
import VaporTesting

@testable import App

// MARK: - Test Database Templates
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
actor PostgresTestDatabases {
    static let shared = PostgresTestDatabases()

    /// Small event-loop group shared by every test app in the suite.
    /// Fluent's pool opens at most one connection per event loop, so this caps
    /// each app at two connections and keeps the fully parallel suite well
    /// under the server's default max_connections=100 — the constraint that
    /// used to force CI's Postgres run to be --no-parallel.
    static let appEventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)

    /// Connection parameters from the environment. `DATABASE_NAME` is only the
    /// anchor database the admin connection logs into — tests themselves run
    /// in throwaway clones of the template.
    static func configuration(database: String) -> SQLPostgresConfiguration {
        SQLPostgresConfiguration(
            hostname: Environment.get("DATABASE_HOST") ?? "localhost",
            port: Environment.get("DATABASE_PORT").flatMap(Int.init(_:))
                ?? SQLPostgresConfiguration.ianaPortNumber,
            username: Environment.get("DATABASE_USERNAME") ?? "strato",
            password: Environment.get("DATABASE_PASSWORD") ?? "strato_password",
            database: database,
            tls: .disable
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
    func createDatabaseForTest() async throws -> String {
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
    func createBareDatabaseForTest() async throws -> String {
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
    func dropDatabase(_ name: String) async {
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
        app.databases.use(.postgres(configuration: Self.configuration(database: templateName)), as: .psql)
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
                ?? SQLPostgresConfiguration.ianaPortNumber,
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
    static func makeForTesting(_ environment: Environment = .testing) async throws -> Application {
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
    static func makeForBareDatabaseTesting(_ environment: Environment = .testing) async throws
        -> Application
    {
        var env = environment
        env.arguments = ["vapor"]

        let databaseName = try await PostgresTestDatabases.shared.createBareDatabaseForTest()
        return try await make(env, database: databaseName)
    }

    private static func make(_ env: Environment, database databaseName: String) async throws
        -> Application
    {
        let app = try await Application.make(env, .shared(PostgresTestDatabases.appEventLoopGroup))
        app.logger.logLevel = .debug
        app.databases.use(
            .postgres(configuration: PostgresTestDatabases.configuration(database: databaseName)),
            as: .psql
        )
        app.storage[TestDatabaseNameKey.self] = databaseName
        return app
    }
}

// Storage key for the per-test Postgres database clone's name
struct TestDatabaseNameKey: StorageKey {
    typealias Value = String
}

extension Application {
    /// Tear down an app made by `makeForTesting`: shut Vapor down (closing its
    /// database pool), then destroy the test's database clone.
    func shutdownForTesting() async throws {
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
struct PermissiveGuardrailAnalyzer: GuardrailAnalyzer {
    func disjoint(
        schemaText: String,
        _ a: [CedarPolicySource],
        _ b: [CedarPolicySource],
        in environment: CedarRequestEnvironment
    ) async throws -> GuardrailAnalysis {
        GuardrailAnalysis(holds: true, counterexample: nil)
    }

    func implies(
        schemaText: String,
        _ a: [CedarPolicySource],
        _ b: [CedarPolicySource],
        in environment: CedarRequestEnvironment
    ) async throws -> GuardrailAnalysis {
        GuardrailAnalysis(holds: true, counterexample: nil)
    }
}

func withTestApp(_ test: (Application) async throws -> Void) async throws {
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
func withApp(_ test: (Application) async throws -> Void) async throws {
    try await withTestApp(test)
}

extension User {
    func generateToken() throws -> String {
        // In a real implementation, this would create a proper session/token
        // For testing, we'll use a simple token
        return "test-token-\(self.id?.uuidString ?? UUID().uuidString)"
    }

    func generateAPIKey(on db: Database, name: String = "Test API Key") async throws -> String {
        // Generate a proper API key for testing
        let apiKeyString = APIKey.generateAPIKey()
        let keyHash = APIKey.hashAPIKey(apiKeyString)
        let keyPrefix = String(apiKeyString.prefix(16))

        let apiKey = APIKey(
            userID: self.id!,
            name: name,
            keyHash: keyHash,
            keyPrefix: keyPrefix,
            scopes: ["read", "write"],
            isActive: true
        )
        try await apiKey.save(on: db)

        return apiKeyString
    }
}

// MARK: - Test Data Builders

struct TestDataBuilder {
    let db: Database

    func createUser(
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

    func createOrganization(
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

    func addUserToOrganization(
        user: User,
        organization: Organization,
        role: String = "member"
    ) async throws {
        let userOrg = UserOrganization(
            userID: user.id!,
            organizationID: organization.id!,
            role: role
        )
        try await userOrg.save(on: db)

        // Mirror the dual-write the API performs: an org admin carries an
        // `admin` role binding (a bare member carries none — membership itself
        // grants only org:read + project:create). Without this the Cedar
        // evaluator, which answers from `role_bindings`, sees no grant.
        if let bindingRole = IAMRole.fromOrganizationRole(role) {
            try await RoleBindingService.grant(
                principalType: .user,
                principalID: user.id!,
                role: bindingRole,
                nodeType: .organization,
                nodeID: organization.id!,
                createdBy: nil,
                on: db
            )
        }
    }

    func createOU(
        name: String,
        description: String,
        organization: Organization,
        parentOU: OrganizationalUnit? = nil
    ) async throws -> OrganizationalUnit {
        let ou = OrganizationalUnit(
            name: name,
            description: description,
            organizationID: organization.id!,
            parentOUID: parentOU?.id,
            path: "",
            depth: parentOU != nil ? (parentOU!.depth + 1) : 0
        )
        try await ou.save(on: db)
        ou.path = try await ou.buildPath(on: db)
        try await ou.save(on: db)
        return ou
    }

    func createProject(
        name: String,
        description: String,
        organization: Organization? = nil,
        ou: OrganizationalUnit? = nil,
        environments: [String] = ["development", "staging", "production"],
        defaultEnvironment: String = "development"
    ) async throws -> Project {
        let project = Project(
            name: name,
            description: description,
            organizationID: organization?.id,
            organizationalUnitID: ou?.id,
            path: "",
            defaultEnvironment: defaultEnvironment,
            environments: environments
        )
        try await project.save(on: db)
        project.path = try await project.buildPath(on: db)
        try await project.save(on: db)
        return project
    }

    func createGroup(
        name: String,
        description: String,
        organization: Organization
    ) async throws -> Group {
        let group = Group(
            name: name,
            description: description,
            organizationID: organization.id!
        )
        try await group.save(on: db)
        return group
    }

    func createResourceQuota(
        name: String,
        maxVCPUs: Int = 10,
        maxMemoryGB: Double = 20.0,
        maxStorageGB: Double = 100.0,
        maxVMs: Int = 5,
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
            environment: environment
        )
        try await quota.save(on: db)
        return quota
    }

    func createVM(
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

    func createSandbox(
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

    func createImage(
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
        let image = Image(
            name: name,
            description: description,
            projectID: project.id!,
            filename: filename,
            size: size,
            format: format,
            status: status,
            uploadedByID: uploadedBy.id!,
            sourceURL: sourceURL
        )
        image.storagePath = storagePath
        image.checksum = checksum
        try await image.save(on: db)
        return image
    }
}

// MARK: - Mock Image Fetch Service

/// Mock ImageFetchService that does nothing (prevents real HTTP requests in tests)
actor MockImageFetchService: ImageFetchServiceProtocol {
    var startedFetches: [UUID] = []
    var cancelledFetches: [UUID] = []
    var startedArtifactFetches: [UUID] = []

    func startFetch(imageId: UUID) async throws {
        startedFetches.append(imageId)
        // No-op: don't actually fetch anything
    }

    func cancelFetch(imageId: UUID) async {
        cancelledFetches.append(imageId)
    }

    func isFetchActive(imageId: UUID) async -> Bool {
        return false
    }

    func startArtifactFetch(artifactId: UUID) async throws {
        startedArtifactFetches.append(artifactId)
        // No-op: don't actually fetch anything
    }
}

// MARK: - Agent identity keys

/// The key an agent registered under the bare name `name` is stored beneath in
/// the connection map, the coordination presence/route keys, and console/exec
/// session ownership: its full SPIFFE ID in the platform trust domain
/// (issue #613). Tests that register an agent by name and then assert on one of
/// those registries must go through this rather than the bare name.
func agentKey(_ name: String) -> String {
    AgentIdentity(trustDomain: PlatformTrustDomain.current, name: name).key
}
