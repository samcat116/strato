import Fluent
import FluentPostgresDriver
import FluentSQLiteDriver
import NIOCore
import NIOPosix
import PostgresNIO
import SQLKit
import Vapor
import VaporTesting

@testable import App

// MARK: - Test Database Backend

/// Which database engine the test suite runs against.
///
/// Defaults to SQLite for a fast, zero-dependency local inner loop. Set
/// `STRATO_TEST_DATABASE=postgres` (as CI does) to run the exact same tests
/// against a real Postgres, so migrations and Postgres-specific SQL are
/// validated against the engine production actually uses (see issue #195).
enum TestDatabaseBackend {
    case sqlite
    case postgres

    static var current: TestDatabaseBackend {
        switch Environment.get("STRATO_TEST_DATABASE")?.lowercased() {
        case "postgres", "postgresql", "psql":
            return .postgres
        default:
            return .sqlite
        }
    }
}

// MARK: - Test Database Templates
//
// Booting a test app used to replay every migration up (via `configure()`'s
// trailing `autoMigrate()`) against an empty database, and most teardowns
// replayed them all back down with `autoRevert()` — two full migration passes
// per test, which dominated suite runtime on both engines. Instead, migrations
// run ONCE per test process into a template, and every test gets a cheap clone
// of the migrated result:
//
//  - SQLite: the template is a database file; each test copies it.
//  - Postgres: the template is a database; each test clones it server-side
//    with `CREATE DATABASE ... TEMPLATE ...`.
//
// `configure(app)` still calls `autoMigrate()` in every test, but against a
// pre-migrated clone that is a no-op scan of the migration log. Full up/down
// migration coverage lives in MigrationRoundTripTests.

private let testProcessID = ProcessInfo.processInfo.processIdentifier

/// Whether the test process that embedded `pid` in a leftover template's name
/// is still alive on this machine (a parallel run in another worktree we must
/// not disturb). Anything else is debris from a finished or crashed run.
private func isTestProcessAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}

/// Migrated SQLite template, built once per process. Value is the file path.
private let sqliteTemplate = Task { () -> String in
    // Sweep templates left by dead runs — there is no reliable async hook at
    // process exit to self-delete, so each run cleans up after previous ones.
    let fileManager = FileManager.default
    for entry in (try? fileManager.contentsOfDirectory(atPath: "/tmp")) ?? []
    where entry.hasPrefix("strato-test-template-") && entry.hasSuffix(".db") {
        let pidText = entry.dropFirst("strato-test-template-".count).dropLast(".db".count)
        if let pid = Int32(pidText), pid != testProcessID, !isTestProcessAlive(pid) {
            try? fileManager.removeItem(atPath: "/tmp/\(entry)")
        }
    }

    let path = "/tmp/strato-test-template-\(testProcessID).db"
    try? fileManager.removeItem(atPath: path)

    var env = Environment.testing
    env.arguments = ["vapor"]
    let app = try await Application.make(env)
    app.logger.logLevel = .error
    app.databases.use(.sqlite(.file(path)), as: .sqlite)
    do {
        // configure() registers every migration and runs autoMigrate().
        try await configure(app)
        try await app.asyncShutdown()
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    return path
}

/// Builds the per-process Postgres template database and hands out per-test
/// clones of it, serializing all CREATE/DROP DATABASE statements through a
/// single admin connection: `CREATE DATABASE ... TEMPLATE` requires that the
/// template has no other users, so clones must be minted one at a time.
actor PostgresTestDatabases {
    static let shared = PostgresTestDatabases()

    /// Small event-loop group shared by every test app on the Postgres leg.
    /// Fluent's pool opens at most one connection per event loop, so this caps
    /// each app at two connections and keeps the fully parallel suite well
    /// under the server's default max_connections=100 — the constraint that
    /// used to force CI's Postgres leg to run --no-parallel.
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
        // developer pointing STRATO_TEST_DATABASE=postgres at a local/shared cluster
        // must never silently disable durability for unrelated databases.
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

        switch TestDatabaseBackend.current {
        case .sqlite:
            // Each test gets its own copy of the migrated template file.
            let templatePath = try await sqliteTemplate.value
            let testDBPath = "/tmp/strato-test-\(UUID().uuidString).db"
            try FileManager.default.copyItem(atPath: templatePath, toPath: testDBPath)

            let app = try await Application.make(env)
            app.logger.logLevel = .debug
            app.databases.use(.sqlite(.file(testDBPath)), as: .sqlite)
            app.storage[TestDatabasePathKey.self] = testDBPath
            return app

        case .postgres:
            // Each test gets its own server-side clone of the migrated
            // template database.
            let databaseName = try await PostgresTestDatabases.shared.createDatabaseForTest()

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
}

// Storage key for test database path (SQLite)
struct TestDatabasePathKey: StorageKey {
    typealias Value = String
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
        let sqlitePath = storage[TestDatabasePathKey.self]

        try await asyncShutdown()

        if let databaseName {
            await PostgresTestDatabases.shared.dropDatabase(databaseName)
        }
        if let sqlitePath {
            try? FileManager.default.removeItem(atPath: sqlitePath)
            try? FileManager.default.removeItem(atPath: sqlitePath + "-shm")
            try? FileManager.default.removeItem(atPath: sqlitePath + "-wal")
        }
    }
}

// Helper function to run tests with proper database lifecycle. configure()
// runs autoMigrate(), which is a no-op scan against the pre-migrated clone.
func withTestApp(_ test: (Application) async throws -> Void) async throws {
    let app = try await Application.makeForTesting()

    do {
        try await configure(app)
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

// MARK: - Mock SpiceDB Service

class MockSpiceDBService {
    var checkPermissionResult: Bool = true
    var writtenRelationships:
        [(entity: String, entityId: String, relation: String, subject: String, subjectId: String)] = []
    var deletedRelationships:
        [(entity: String, entityId: String, relation: String, subject: String, subjectId: String)] = []

    func checkPermission(
        subject: String,
        permission: String,
        resource: String,
        resourceId: String
    ) async throws -> Bool {
        return checkPermissionResult
    }

    func writeRelationship(
        entity: String,
        entityId: String,
        relation: String,
        subject: String,
        subjectId: String
    ) async throws {
        writtenRelationships.append((entity, entityId, relation, subject, subjectId))
    }

    func deleteRelationship(
        entity: String,
        entityId: String,
        relation: String,
        subject: String,
        subjectId: String
    ) async throws {
        deletedRelationships.append((entity, entityId, relation, subject, subjectId))
    }
}
