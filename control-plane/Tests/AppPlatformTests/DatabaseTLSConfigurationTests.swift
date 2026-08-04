import Testing
import Vapor
@testable import App

// These tests exercise `DatabaseTLSMode.resolve` with explicit raw values
// rather than setting `DATABASE_TLS` in the process environment: setenv while
// another parallel test thread reads the environment (e.g. Vapor's
// `Environment.get` during `configure`) is undefined behavior on glibc.
@Suite("Database TLS Configuration")
struct DatabaseTLSConfigurationTests {

    @Test("Defaults to require outside development")
    func defaultsToRequireInProduction() throws {
        let production = try DatabaseTLSMode.resolve(nil, for: .production)
        let testing = try DatabaseTLSMode.resolve(nil, for: .testing)
        #expect(production == .require)
        #expect(testing == .require)
    }

    @Test("Defaults to disable in development")
    func defaultsToDisableInDevelopment() throws {
        let mode = try DatabaseTLSMode.resolve(nil, for: .development)
        #expect(mode == .disable)
    }

    @Test("Explicit value overrides the environment default")
    func explicitValueWins() throws {
        let disabled = try DatabaseTLSMode.resolve("disable", for: .production)
        #expect(disabled == .disable)
        let preferred = try DatabaseTLSMode.resolve("prefer", for: .development)
        #expect(preferred == .prefer)
        let required = try DatabaseTLSMode.resolve("require", for: .development)
        #expect(required == .require)
    }

    @Test("Value parsing is case-insensitive")
    func caseInsensitive() throws {
        let mode = try DatabaseTLSMode.resolve("REQUIRE", for: .development)
        #expect(mode == .require)
    }

    @Test("An unrecognized value throws rather than downgrading to plaintext")
    func invalidValueThrows() throws {
        #expect(throws: DatabaseTLSConfigurationError.self) {
            try DatabaseTLSMode.resolve("verify-full", for: .production)
        }
    }
}
