import Testing
import Vapor
import Fluent
import VaporTesting
@testable import App

/// Base test case that provides common test infrastructure.
/// Each test runs against its own clone of the migrated template database.
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

        // The admin role binding the API/backfill would have written alongside
        // the membership row. Since cutover (#482) the Cedar evaluator answers
        // from `role_bindings`, so a membership written straight to the
        // database grants nothing without it.
        try await RoleBindingService.grant(
            principalType: .user,
            principalID: testUser.id!,
            role: .admin,
            nodeType: .organization,
            nodeID: testOrganization.id!,
            createdBy: nil,
            on: db
        )

        // Set current organization
        testUser.currentOrganizationId = testOrganization.id
        try await testUser.save(on: db)

        // Generate auth token
        authToken = try await testUser.generateAPIKey(on: db)
    }
}
