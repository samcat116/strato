import Testing
import Vapor
import Fluent
import FluentSQLiteDriver
import VaporTesting
@testable import App

@Suite("Example Tests - Verify Setup", .serialized)
final class ExampleTests: BaseTestCase {

    @Test("Database setup works correctly")
    func testDatabaseSetup() async throws {
        try await withApp { app in
            // Verify we can interact with the database
            let userCount = try await User.query(on: app.db).count()
            #expect(userCount == 0)

            // Create a test user
            let user = User(
                username: "example",
                email: "example@test.com",
                displayName: "Example User",
                isSystemAdmin: false
            )
            try await user.save(on: app.db)

            // Verify user was saved
            let savedUser = try await User.query(on: app.db)
                .filter(\.$username == "example")
                .first()

            #expect(savedUser != nil)
            #expect(savedUser?.email == "example@test.com")
        }
    }

    @Test("Test data isolation between tests")
    func testDataIsolation() async throws {
        try await withApp { app in
            // This test should not see the user from the previous test
            let userCount = try await User.query(on: app.db).count()
            #expect(userCount == 0)
        }
    }

    @Test("Common test data setup works")
    func testCommonDataSetup() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)

            // Verify test user exists
            #expect(testUser != nil)
            #expect(testUser.username == "testuser")

            // Verify test organization exists
            #expect(testOrganization != nil)
            #expect(testOrganization.name == "Test Organization")

            // Verify user is member of organization
            let userOrg = try await UserOrganization.query(on: app.db)
                .filter(\.$user.$id == testUser.id!)
                .filter(\.$organization.$id == testOrganization.id!)
                .first()

            #expect(userOrg != nil)
            #expect(userOrg?.role == "admin")
        }
    }
}
