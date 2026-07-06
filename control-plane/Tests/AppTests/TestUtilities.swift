import Vapor
import Fluent
import FluentSQLiteDriver
import FluentPostgresDriver
import SQLKit
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

// MARK: - Test Extensions

extension Application {
    static func makeForTesting(_ environment: Environment = .testing) async throws -> Application {
        var env = environment
        env.arguments = ["vapor"]

        let app = try await Application.make(env)
        app.logger.logLevel = .debug

        switch TestDatabaseBackend.current {
        case .sqlite:
            // Use file-based SQLite with unique names for better isolation.
            // Generate a unique database file for each test.
            let testDBPath = "/tmp/strato-test-\(UUID().uuidString).db"
            app.databases.use(.sqlite(.file(testDBPath)), as: .sqlite)
            app.storage[TestDatabasePathKey.self] = testDBPath

        case .postgres:
            // Isolate each test in its own Postgres schema on a shared database.
            // This mirrors the per-file isolation SQLite gets while running the
            // suite in parallel against a single Postgres instance. The schema is
            // created here (before configure()/autoMigrate) and dropped on teardown.
            let schema = "test_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

            var configuration = SQLPostgresConfiguration(
                hostname: Environment.get("DATABASE_HOST") ?? "localhost",
                port: Environment.get("DATABASE_PORT").flatMap(Int.init(_:))
                    ?? SQLPostgresConfiguration.ianaPortNumber,
                username: Environment.get("DATABASE_USERNAME") ?? "strato",
                password: Environment.get("DATABASE_PASSWORD") ?? "strato_password",
                database: Environment.get("DATABASE_NAME") ?? "strato_test",
                tls: .disable
            )
            // All unqualified DDL/DML from migrations and models lands in this
            // per-test schema, keeping parallel tests from colliding.
            configuration.searchPath = [schema]

            app.databases.use(.postgres(configuration: configuration), as: .psql)
            app.storage[TestDatabaseSchemaKey.self] = schema

            // CREATE SCHEMA is search_path-independent, so it succeeds even though
            // the schema in the configured search_path does not exist yet.
            try await (app.db(.psql) as! SQLDatabase)
                .raw("CREATE SCHEMA IF NOT EXISTS \(ident: schema)")
                .run()
        }

        return app
    }
}

// Storage key for test database path (SQLite)
struct TestDatabasePathKey: StorageKey {
    typealias Value = String
}

// Storage key for per-test Postgres schema name
struct TestDatabaseSchemaKey: StorageKey {
    typealias Value = String
}

extension Application {
    /// Drop the per-test Postgres schema. Must run while the database connection
    /// is still live, i.e. *before* `asyncShutdown()`. No-op for SQLite.
    func dropTestSchemaIfNeeded() async {
        guard let schema = self.storage[TestDatabaseSchemaKey.self] else { return }
        try? await (self.db(.psql) as! SQLDatabase)
            .raw("DROP SCHEMA IF EXISTS \(ident: schema) CASCADE")
            .run()
    }

    /// Remove the SQLite database file. Safe to call after `asyncShutdown()`.
    /// No-op when running against Postgres.
    func cleanupTestDatabase() {
        if let dbPath = self.storage[TestDatabasePathKey.self] {
            try? FileManager.default.removeItem(atPath: dbPath)
            try? FileManager.default.removeItem(atPath: dbPath + "-shm")
            try? FileManager.default.removeItem(atPath: dbPath + "-wal")
        }
    }
}

// Helper function to run tests with proper database lifecycle
func withTestApp(_ test: (Application) async throws -> Void) async throws {
    let app = try await Application.makeForTesting()

    do {
        try await configure(app)
        try await app.autoMigrate()
        try await test(app)
        try await app.autoRevert()
    } catch {
        try? await app.autoRevert()
        await app.dropTestSchemaIfNeeded()
        // asyncShutdown() awaits full teardown (event loops, thread pool, DB
        // connection pool), so the database file is safe to remove immediately.
        try await app.asyncShutdown()
        app.cleanupTestDatabase()
        throw error
    }

    await app.dropTestSchemaIfNeeded()
    try await app.asyncShutdown()
    app.cleanupTestDatabase()
}

// Helper function to run a test with automatic app cleanup
func withApp(_ test: (Application) async throws -> Void) async throws {
    let app = try await Application.makeForTesting()

    do {
        try await configure(app)
        try await app.autoMigrate()
        try await test(app)
    } catch {
        await app.dropTestSchemaIfNeeded()
        try await app.asyncShutdown()
        app.cleanupTestDatabase()
        throw error
    }

    await app.dropTestSchemaIfNeeded()
    try await app.asyncShutdown()
    app.cleanupTestDatabase()
}

// Extension to safely shutdown Vapor apps
extension Application {
    func safeShutdown() {
        // This is deprecated - use asyncShutdown() instead
        // Kept for backward compatibility but should be replaced
        let app = self
        Task {
            try? await app.asyncShutdown()
        }
    }
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
