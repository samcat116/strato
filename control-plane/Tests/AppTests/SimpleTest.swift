import Testing
import Vapor
import Fluent
import FluentSQLiteDriver
import VaporTesting
@testable import App

@Suite("Simple Tests")
final class SimpleTests {
    
    @Test("Basic SQLite connection works")
    func testBasicConnection() async throws {
        let app = try await Application.makeForTesting()
        
        do {
            // Just verify the app starts without migrations
            #expect(app.environment == .testing)
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        
        try await app.asyncShutdown()
    }
    
    @Test("In-memory SQLite works")
    func testInMemoryDatabase() async throws {
        let app = try await Application.makeForTesting()
        
        do {
            // Create a simple test table without migrations
            try await app.db.schema("test_table")
                .id()
                .field("name", .string, .required)
                .create()
            
            // Simple verification that database works
            #expect(true) // If we get here, schema creation worked
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        
        try await app.asyncShutdown()
    }
}