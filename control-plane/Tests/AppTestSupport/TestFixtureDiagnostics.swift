import Fluent
import Foundation
import PostgresNIO
import Testing
import Vapor

/// Process-local test fixture bookkeeping. Emits only on an existing failure;
/// never reads error descriptions, server messages, queries, bindings or config.
package final class TestFixtureDiagnostics: @unchecked Sendable {
    package static let shared = TestFixtureDiagnostics()

    package init() {}

    private struct Fixture {
        let started: ContinuousClock.Instant
        let applicationReady: ContinuousClock.Instant
        let poolLimitPerLoop: Int
        var phase = "application_ready"
        var phaseStarted: ContinuousClock.Instant
        var configurationMilliseconds: Int64?
    }

    private let lock = NSLock()
    private let clock = ContinuousClock()
    private var fixtures: [ObjectIdentifier: Fixture] = [:]
    private var peak = 0
    private var completed = 0

    package func register(
        _ app: Application,
        started: ContinuousClock.Instant,
        poolLimitPerLoop: Int
    ) {
        lock.withLock {
            let now = clock.now
            fixtures[ObjectIdentifier(app)] = Fixture(
                started: started, applicationReady: now,
                poolLimitPerLoop: poolLimitPerLoop, phaseStarted: now)
            peak = max(peak, fixtures.count)
        }
    }

    package func configuring(_ app: Application) { phase("configuring", app) }
    package func running(_ app: Application) { phase("test_body", app) }
    package func closing(_ app: Application) { phase("pool_shutdown", app) }

    private func phase(_ value: String, _ app: Application) {
        lock.withLock {
            guard var fixture = fixtures[ObjectIdentifier(app)] else { return }
            if fixture.phase == "configuring" && value == "test_body" {
                fixture.configurationMilliseconds = milliseconds(fixture.phaseStarted.duration(to: clock.now))
            }
            fixture.phase = value
            fixture.phaseStarted = clock.now
            fixtures[ObjectIdentifier(app)] = fixture
        }
    }

    package func finished(_ app: Application) {
        finished(ObjectIdentifier(app))
    }

    package func finished(_ id: ObjectIdentifier) {
        lock.withLock {
            if fixtures.removeValue(forKey: id) != nil { completed += 1 }
        }
    }

    /// Fixed driver code + validated SQLSTATE only. In particular, do not use
    /// String(reflecting: error): Postgres debug descriptions include SQL/data.
    package static func errorCategory(_ error: any Error) -> String {
        guard let error = error as? PSQLError else { return "category=non_postgres sqlstate=none" }
        let rawState = error.serverInfo?[.sqlState] ?? ""
        let state =
            rawState.utf8.count == 5
                && rawState.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) }
            ? rawState : "none"
        let underlying = (error.underlying as? PSQLError)?.code.description ?? "none"
        return
            "category=\(error.code) sqlstate=\(state) underlying_psql=\(underlying) query_present=\(error.query != nil)"
    }

    package func report(_ error: any Error, on app: Application) {
        // Recording alongside the original thrown error puts this allowlisted
        // evidence in JUnit, which remains readable when raw logs are restricted.
        Issue.record(Comment(rawValue: summary(error, on: app)))
    }

    package func reportCloneFailure(_ error: any Error, started: ContinuousClock.Instant) {
        let value =
            summary(error, on: nil)
            + " phase=clone_creation clone_ms=\(milliseconds(started.duration(to: clock.now)))"
        Issue.record(Comment(rawValue: value))
    }

    package func summary(_ error: any Error, on app: Application?) -> String {
        let category = Self.errorCategory(error)
        return lock.withLock {
            let now = clock.now
            let configuring = fixtures.values.filter { $0.phase == "configuring" }.count
            let closing = fixtures.values.filter { $0.phase == "pool_shutdown" }.count
            var result =
                "Test fixture database diagnostic: \(category) fixtures_active=\(fixtures.count) fixtures_peak=\(peak) fixtures_completed=\(completed) configuring=\(configuring) closing=\(closing) event_loops=2"
            if let app, let fixture = fixtures[ObjectIdentifier(app)] {
                result +=
                    " phase=\(fixture.phase) fixture_ms=\(milliseconds(fixture.started.duration(to: now))) application_init_ms=\(milliseconds(fixture.started.duration(to: fixture.applicationReady))) phase_ms=\(milliseconds(fixture.phaseStarted.duration(to: now))) pool_limit_per_loop=\(fixture.poolLimitPerLoop)"
                if let duration = fixture.configurationMilliseconds {
                    result += " configuration_ms=\(duration)"
                }
            }
            return result
        }
    }

    private func milliseconds(_ duration: Duration) -> Int64 {
        let parts = duration.components
        return parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000
    }
}
