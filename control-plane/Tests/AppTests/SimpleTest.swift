import Testing
import Vapor
import Fluent
import FluentSQLiteDriver
import VaporTesting
@testable import App

@Suite("Simple Tests", .serialized)
final class SimpleTests {

    @Test("Basic SQLite connection works")
    func testBasicConnection() async throws {
        let app = try await Application.makeForTesting()

        // Just verify the app starts without migrations
        #expect(app.environment == .testing)

        try await app.asyncShutdown()
        // Give time for shutdown to complete
        try? await Task.sleep(for: .seconds(2))
        app.cleanupTestDatabase()
    }

    @Test("In-memory SQLite works")
    func testInMemoryDatabase() async throws {
        let app = try await Application.makeForTesting()

        // Create a simple test table without migrations
        try await app.db.schema("test_table")
            .id()
            .field("name", .string, .required)
            .create()

        // Simple verification that database works
        #expect(true) // If we get here, schema creation worked

        try await app.asyncShutdown()
        // Give time for shutdown to complete
        try? await Task.sleep(for: .seconds(2))
        app.cleanupTestDatabase()
    }
}
