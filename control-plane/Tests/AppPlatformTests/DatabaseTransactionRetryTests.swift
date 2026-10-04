import AppTestSupport
import Fluent
import FluentPostgresDriver
import Foundation
import SQLKit
import Testing
import Vapor

@testable import App

@Suite("Database transaction recovery", .serialized, .postgresFixture)
struct DatabaseTransactionRetryTests {
    @Test("Reject invalid session budgets")
    func validatesBudgets() throws {
        #expect(throws: (any Error).self) {
            try DatabaseSessionTimeouts(lockMilliseconds: 0, idleInTransactionMilliseconds: 1)
        }
        #expect(throws: (any Error).self) {
            try DatabaseSessionTimeouts(lockMilliseconds: 1, idleInTransactionMilliseconds: -1)
        }
    }

    @Test("Real PostgreSQL deadlock victim retries its entire transaction exactly once")
    func deadlockRecovery() async throws {
        let app = try await Application.makeForTesting(maxConnectionsPerEventLoop: 4)
        do {
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("CREATE TABLE retry_probe (id int PRIMARY KEY, value int NOT NULL)").run()
            try await sql.raw("INSERT INTO retry_probe VALUES (1, 0), (2, 0)").run()
            try await sql.raw("CREATE TABLE retry_events (actor int PRIMARY KEY)").run()
            try await sql.raw("CREATE TABLE retry_outbox (actor int PRIMARY KEY)").run()
            let barrier = RetryDeadlockBarrier()
            async let first: Void = increment(app.db, first: 1, second: 2, barrier: barrier)
            async let second: Void = increment(app.db, first: 2, second: 1, barrier: barrier)
            _ = try await (first, second)
            let values = try await sql.raw("SELECT value FROM retry_probe ORDER BY id").all(
                decodingColumn: "value", as: Int.self)
            #expect(values == [2, 2])
            #expect(await barrier.attemptCount == 3)
            #expect(
                try await sql.raw("SELECT count(*) FROM retry_events").first(decodingColumn: "count", as: Int.self) == 2
            )
            #expect(
                try await sql.raw("SELECT count(*) FROM retry_outbox").first(decodingColumn: "count", as: Int.self) == 2
            )
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private func increment(_ db: any Database, first: Int, second: Int, barrier: RetryDeadlockBarrier) async throws {
        try await DatabaseTransactionRetry.run(on: db) { tx in
            let sql = try #require(tx as? any SQLDatabase)
            let isFirst = await barrier.attempt(for: first)
            try await sql.raw("UPDATE retry_probe SET value = value + 1 WHERE id = \(bind: first)").run()
            // Written before the failure: these must roll back with the victim.
            try await sql.raw("INSERT INTO retry_events VALUES (\(bind: first))").run()
            try await sql.raw("INSERT INTO retry_outbox VALUES (\(bind: first))").run()
            if isFirst { await barrier.arrive() }
            try await sql.raw("UPDATE retry_probe SET value = value + 1 WHERE id = \(bind: second)").run()
        }
    }

    @Test("Typed errors exhaust to retryable 503; unsafe errors execute once")
    func classificationAndExhaustion() async throws {
        let app = try await Application.makeForTesting()
        do {
            for state in ["40001", "40P01", "55P03", "57014", "08006", "23503", "23505", "23514"] {
                let attempts = RetryAttemptCounter()
                do {
                    try await DatabaseTransactionRetry.run(on: app.db, attempts: 2) { tx in
                        await attempts.increment()
                        let sql = try #require(tx as? any SQLDatabase)
                        // Codes are fixed test literals, never request inputs.
                        try await sql.raw(
                            SQLQueryString(
                                stringLiteral:
                                    "DO $$ BEGIN RAISE EXCEPTION 'test abort' USING ERRCODE = '\(state)'; END $$")
                        ).run()
                    }
                    Issue.record("Expected PostgreSQL error")
                } catch let error as DatabaseTransactionRetryExhausted {
                    #expect(["40001", "40P01", "55P03"].contains(state))
                    #expect(error.status == .serviceUnavailable)
                    #expect(error.headers.first(name: "Retry-After") == "1")
                    #expect(await attempts.value == 2)
                } catch {
                    #expect(["57014", "08006", "23503", "23505", "23514"].contains(state))
                    #expect(DatabaseTransactionFailure.sqlState(error) == state)
                    #expect(await attempts.value == 1)
                }
            }
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test("Idle transaction connection loss is never replayed")
    func idleTransactionIsNotRetried() async throws {
        let name = try await PostgresTestDatabases.shared.createDatabaseForTest()
        let app = try await Application.makeForTesting(database: name, owningDatabase: true)
        app.databases.use(
            try DatabaseStatementTimeout(milliseconds: 30_000).applying(
                to: .postgres(configuration: PostgresTestDatabases.configuration(database: name)),
                sessionTimeouts: DatabaseSessionTimeouts(lockMilliseconds: 100, idleInTransactionMilliseconds: 100)),
            as: .psql)
        app.databases.reinitialize(.psql)
        let attempts = RetryAttemptCounter()
        do {
            do {
                try await DatabaseTransactionRetry.run(on: app.db) { tx in
                    await attempts.increment()
                    let sql = try #require(tx as? any SQLDatabase)
                    try await sql.raw("SELECT 1").run()
                    try await Task.sleep(for: .milliseconds(300))
                    try await sql.raw("SELECT 1").run()
                }
                Issue.record("Idle transaction should have been terminated by PostgreSQL")
            } catch {
                #expect(DatabaseTransactionFailure.classify(error) == nil)
                #expect(await attempts.value == 1)
            }
            // A replacement pooled connection remains usable after the loss.
            let sql = try #require(app.db as? any SQLDatabase)
            #expect(try await sql.raw("SELECT 1 AS value").first(decodingColumn: "value", as: Int.self) == 1)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test("Lock convoy expires at the lock budget and returns pool slots")
    func lockConvoy() async throws {
        let name = try await PostgresTestDatabases.shared.createDatabaseForTest()
        let holder = try await Application.makeForTesting(database: name, owningDatabase: false)
        let waiter = try await Application.makeForTesting(
            database: name, owningDatabase: true)
        let budgets = try DatabaseSessionTimeouts(lockMilliseconds: 100, idleInTransactionMilliseconds: 60_000)
        waiter.databases.use(
            try DatabaseStatementTimeout(milliseconds: 30_000).applying(
                to: .postgres(configuration: PostgresTestDatabases.configuration(database: name)),
                sessionTimeouts: budgets),
            as: .psql)
        do {
            try await holder.db.transaction { tx in
                let sql = try #require(tx as? any SQLDatabase)
                try await sql.raw("SELECT pg_advisory_xact_lock(1418)").run()
                let clock = ContinuousClock()
                let start = clock.now
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for _ in 0..<4 {
                        group.addTask {
                            do {
                                try await DatabaseTransactionRetry.run(on: waiter.db, attempts: 2) { transaction in
                                    let sql = try #require(transaction as? any SQLDatabase)
                                    try await sql.raw("SELECT pg_advisory_xact_lock(1418)").run()
                                }
                                Issue.record("Lock waiter unexpectedly succeeded")
                            } catch let error as DatabaseTransactionRetryExhausted {
                                #expect(error.sqlState == "55P03")
                            }
                        }
                    }
                    try await group.waitForAll()
                }
                #expect(start.duration(to: clock.now) < .seconds(3))
                // The same exhausted pool serves unrelated work immediately.
                let unrelated = try #require(waiter.db as? any SQLDatabase)
                #expect(try await unrelated.raw("SELECT 1 AS value").first(decodingColumn: "value", as: Int.self) == 1)
            }
        } catch {
            try await holder.asyncShutdown()
            try await waiter.shutdownForTesting()
            throw error
        }
        try await holder.asyncShutdown()
        try await waiter.shutdownForTesting()
    }
}

private actor RetryAttemptCounter {
    var value = 0
    func increment() { value += 1 }
}

private actor RetryDeadlockBarrier {
    var attemptCount = 0
    private var actors: Set<Int> = []
    private var waiting: CheckedContinuation<Void, Never>?
    func attempt(for actor: Int) -> Bool {
        attemptCount += 1
        return actors.insert(actor).inserted
    }
    func arrive() async {
        if let waiting {
            self.waiting = nil
            waiting.resume()
        } else {
            await withCheckedContinuation { waiting = $0 }
        }
    }
}
