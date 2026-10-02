import AppTestSupport
import PostgresNIO
import SQLKit
import Testing
import Vapor

@Suite("Test fixture diagnostics", .serialized, .postgresFixture)
struct TestFixtureDiagnosticsTests {
    @Test("PostgreSQL failure reports contain codes and timings, never SQL or bindings")
    func postgresErrorIsSanitized() async throws {
        let app = try await Application.makeForTesting()
        do {
            let diagnostics = TestFixtureDiagnostics()
            diagnostics.register(app, started: ContinuousClock().now, poolLimitPerLoop: 2)
            diagnostics.configuring(app)
            diagnostics.running(app)
            let sql = try #require(app.db as? any SQLDatabase)
            var caught: PSQLError?
            do {
                _ = try await sql.raw(
                    "SELECT \(bind: "fixture-private-binding") FROM fixture_private_missing_relation"
                ).all()
            } catch let error as PSQLError {
                caught = error
            }
            let error = try #require(caught)
            let summary = diagnostics.summary(error, on: app)
            #expect(summary.contains("category=server sqlstate=42P01"))
            #expect(summary.contains("fixtures_active=1 fixtures_peak=1"))
            #expect(summary.contains("phase=test_body"))
            #expect(summary.contains("configuration_ms="))
            #expect(summary.contains("pool_limit_per_loop=2"))
            #expect(!summary.contains("fixture-private-binding"))
            #expect(!summary.contains("fixture_private_missing_relation"))
            #expect(!summary.contains("SELECT"))
            diagnostics.closing(app)
            #expect(diagnostics.summary(error, on: app).contains("phase=pool_shutdown"))
            diagnostics.finished(app)
            #expect(diagnostics.summary(error, on: app).contains("fixtures_active=0"))
        } catch {
            try? await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test("Unknown error descriptions are never read")
    func unknownErrorIsSanitized() {
        #expect(
            TestFixtureDiagnostics.errorCategory(PrivateError())
                == "category=non_postgres sqlstate=none")
    }
}

private struct PrivateError: Error, CustomStringConvertible {
    var description: String { "fixture-secret-token" }
}
