import Vapor
import Fluent
import FluentSQLiteDriver
import VaporTesting
@testable import App

// MARK: - Test Extensions

extension Application {
    static func makeForTesting(_ environment: Environment = .testing) async throws -> Application {
        var env = environment
        env.arguments = ["vapor"]

        let app = try await Application.make(env)
        app.logger.logLevel = .debug

        // Use file-based SQLite with unique names for better isolation
        // Generate a unique database file for each test
        let testDBPath = "/tmp/strato-test-\(UUID().uuidString).db"
        app.databases.use(.sqlite(.file(testDBPath)), as: .sqlite)

        // Store the path so we can clean it up later
        app.storage[TestDatabasePathKey.self] = testDBPath

        return app
    }
}

// Storage key for test database path
struct TestDatabasePathKey: StorageKey {
    typealias Value = String
}

// Extension to clean up test database file
extension Application {
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
        try await app.asyncShutdown()
        // Give time for shutdown to complete
        try? await Task.sleep(for: .seconds(2))
        app.cleanupTestDatabase()
        throw error
    }

    try await app.asyncShutdown()
    // Give time for shutdown to complete before deallocation
    try? await Task.sleep(for: .seconds(2))
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
        try await app.asyncShutdown()
        try? await Task.sleep(for: .seconds(2))
        app.cleanupTestDatabase()
        throw error
    }

    try await app.asyncShutdown()
    try? await Task.sleep(for: .seconds(2))
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
}

// MARK: - Mock SpiceDB Service

class MockSpiceDBService {
    var checkPermissionResult: Bool = true
    var writtenRelationships: [(entity: String, entityId: String, relation: String, subject: String, subjectId: String)] = []
    var deletedRelationships: [(entity: String, entityId: String, relation: String, subject: String, subjectId: String)] = []

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
