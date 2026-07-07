import Testing
import Vapor
import Fluent
import FluentSQLiteDriver
import VaporTesting
@testable import App

/// Base test case that provides common test infrastructure
/// Uses in-memory SQLite database for each test
class BaseTestCase {
    // Common test data
    var testUser: User!
    var testOrganization: Organization!
    var authToken: String!

    /// Run a test with a fresh application instance and a pre-migrated
    /// per-test database clone (see TestUtilities.swift).
    func withApp(_ test: (Application) async throws -> Void) async throws {
        try await withTestApp(test)
    }

    /// Set up common test data
    func setupCommonTestData(on db: Database) async throws {
        // Create test user
        testUser = User(
            username: "testuser",
            email: "test@example.com",
            displayName: "Test User",
            isSystemAdmin: false
        )
        try await testUser.save(on: db)

        // Create test organization
        testOrganization = Organization(
            name: "Test Organization",
            description: "Test organization for unit tests"
        )
        try await testOrganization.save(on: db)

        // Add user to organization as admin
        let userOrg = UserOrganization(
            userID: testUser.id!,
            organizationID: testOrganization.id!,
            role: "admin"
        )
        try await userOrg.save(on: db)

        // Set current organization
        testUser.currentOrganizationId = testOrganization.id
        try await testUser.save(on: db)

        // Generate auth token
        authToken = try await testUser.generateAPIKey(on: db)
    }
}
