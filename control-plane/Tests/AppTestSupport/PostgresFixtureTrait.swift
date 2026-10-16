import Foundation
import Testing
import Vapor

/// SwiftPM's --num-workers bounds XCTest processes, not Swift Testing tasks.
/// Uses the supported Testing.TestScoping API (Swift 6.4). PostgreSQL 15
/// identifies SQLSTATE 53300 as too_many_connections:
/// https://www.postgresql.org/docs/15/errcodes-appendix.html
/// Admit whole test cases, so nested/shared applications cannot deadlock while
/// trying to acquire a second app permit. Existing in-test concurrency is intact.
package struct PostgresFixtureTrait: SuiteTrait, TestTrait, TestScoping {
    package var isRecursive: Bool { true }

    package func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        guard testCase != nil, PostgresFixtureScope.current == nil else {
            try await function()
            return
        }
        try await PostgresFixtureConcurrency.shared.withPermit {
            try await PostgresFixtureScope.withScope(function)
        }
    }
}

extension Trait where Self == PostgresFixtureTrait {
    package static var postgresFixture: Self { Self() }
}

/// Four cases leave headroom below PostgreSQL's default 100 connections for
/// the admin/template pool and cases with multiple apps or a larger test pool.
/// This budget is per test process; independent processes need separate servers.
package final class PostgresFixtureConcurrency: @unchecked Sendable {
    package static let shared = PostgresFixtureConcurrency(limit: 4)
    private let lock = NSLock()
    private let limit: Int
    private var active = 0
    private var peak = 0
    private var waiters: [(UUID, CheckedContinuation<Void, any Error>)] = []
    private var pending: Set<UUID> = []
    private var cancelled: Set<UUID> = []

    package init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
    }

    package func withPermit<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        let id = UUID()
        prepare(id)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                pending.remove(id)
                if cancelled.remove(id) != nil || Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if active < limit {
                    active += 1
                    peak = max(peak, active)
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append((id, continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            self.cancel(id)
        }
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    package var peakActive: Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }

    package var waitingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    private func prepare(_ id: UUID) {
        lock.lock()
        pending.insert(id)
        lock.unlock()
    }

    private func cancel(_ id: UUID) {
        lock.lock()
        if let index = waiters.firstIndex(where: { $0.0 == id }) {
            let continuation = waiters.remove(at: index).1
            lock.unlock()
            continuation.resume(throwing: CancellationError())
        } else {
            // An admitted task releases in defer; only pre-registration
            // cancellation needs remembering. No abandoned IDs accumulate.
            if pending.contains(id) { cancelled.insert(id) }
            lock.unlock()
        }
    }

    private func release() {
        lock.lock()
        if waiters.isEmpty {
            active -= 1
            lock.unlock()
        } else {
            let continuation = waiters.removeFirst().1
            lock.unlock()
            continuation.resume()
        }
    }
}

/// Owns fallback cleanup even when setup throws before the test's do/catch.
/// A permit is returned only after pools close and database drops complete.
package actor PostgresFixtureScope {
    @TaskLocal package static var current: PostgresFixtureScope?
    private var apps: [Application] = []
    private var databases: [String] = []

    package static func withScope(_ operation: @Sendable () async throws -> Void) async throws {
        let scope = PostgresFixtureScope()
        do {
            try await $current.withValue(scope, operation: operation)
        } catch {
            // Cleanup must not inherit cancellation from the test task. Record
            // any failure back in the original Swift Testing context.
            let failures = await Task.detached { await scope.finish() }.value
            for (app, failure) in failures {
                Issue.record(
                    Comment(
                        rawValue: TestFixtureDiagnostics.shared.summary(failure, on: app)
                            + " phase=fixture_teardown"))
            }
            throw error
        }
        let failures = await Task.detached { await scope.finish() }.value
        for (app, failure) in failures {
            Issue.record(
                Comment(
                    rawValue: TestFixtureDiagnostics.shared.summary(failure, on: app)
                        + " phase=fixture_teardown"))
        }
    }

    package static func requireCurrent() throws -> PostgresFixtureScope {
        guard let scope = current else {
            throw TestSetupError.message("PostgreSQL tests must declare .postgresFixture")
        }
        return scope
    }

    package func register(_ app: Application) { apps.append(app) }
    package func register(database: String) { databases.append(database) }

    package func finish() async -> [(Application?, any Error)] {
        var failures: [(Application?, any Error)] = []
        for app in apps.reversed() where !app.didShutdown {
            do {
                try await app.asyncShutdown()
            } catch {
                failures.append((app, error))
            }
        }
        for database in databases.reversed() {
            do {
                try await PostgresTestDatabases.shared.dropDatabaseForFixture(database)
            } catch {
                failures.append((nil, error))
            }
        }
        apps.removeAll()
        databases.removeAll()
        return failures
    }
}
