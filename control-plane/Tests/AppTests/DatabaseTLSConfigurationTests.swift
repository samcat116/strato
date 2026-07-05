import Testing
import Vapor
@testable import App

@Suite("Database TLS Configuration", .serialized)
struct DatabaseTLSConfigurationTests {

    /// Set `DATABASE_TLS` for the duration of `body`, restoring it afterward.
    private func withDatabaseTLS<T>(_ value: String?, _ body: () throws -> T) rethrows -> T {
        let previous = Environment.get("DATABASE_TLS")
        if let value {
            setenv("DATABASE_TLS", value, 1)
        } else {
            unsetenv("DATABASE_TLS")
        }
        defer {
            if let previous {
                setenv("DATABASE_TLS", previous, 1)
            } else {
                unsetenv("DATABASE_TLS")
            }
        }
        return try body()
    }

    @Test("Defaults to require outside development")
    func defaultsToRequireInProduction() throws {
        try withDatabaseTLS(nil) {
            let production = try DatabaseTLSMode.fromEnvironment(for: .production)
            let testing = try DatabaseTLSMode.fromEnvironment(for: .testing)
            #expect(production == .require)
            #expect(testing == .require)
        }
    }

    @Test("Defaults to disable in development")
    func defaultsToDisableInDevelopment() throws {
        try withDatabaseTLS(nil) {
            let mode = try DatabaseTLSMode.fromEnvironment(for: .development)
            #expect(mode == .disable)
        }
    }

    @Test("Explicit value overrides the environment default")
    func explicitValueWins() throws {
        try withDatabaseTLS("disable") {
            let mode = try DatabaseTLSMode.fromEnvironment(for: .production)
            #expect(mode == .disable)
        }
        try withDatabaseTLS("prefer") {
            let mode = try DatabaseTLSMode.fromEnvironment(for: .development)
            #expect(mode == .prefer)
        }
        try withDatabaseTLS("require") {
            let mode = try DatabaseTLSMode.fromEnvironment(for: .development)
            #expect(mode == .require)
        }
    }

    @Test("Value parsing is case-insensitive")
    func caseInsensitive() throws {
        try withDatabaseTLS("REQUIRE") {
            let mode = try DatabaseTLSMode.fromEnvironment(for: .development)
            #expect(mode == .require)
        }
    }

    @Test("An unrecognized value throws rather than downgrading to plaintext")
    func invalidValueThrows() throws {
        try withDatabaseTLS("verify-full") {
            #expect(throws: DatabaseTLSConfigurationError.self) {
                try DatabaseTLSMode.fromEnvironment(for: .production)
            }
        }
    }
}
