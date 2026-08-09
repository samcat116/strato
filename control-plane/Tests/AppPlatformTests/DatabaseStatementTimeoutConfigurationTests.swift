import AppTestSupport
import FluentPostgresDriver
import Foundation
import SQLKit
import Testing
import Vapor

@testable import App

@Suite("Database Statement Timeout Configuration")
struct DatabaseStatementTimeoutConfigurationTests {

    @Test("Defaults to five minutes when the environment value is absent")
    func defaultValue() throws {
        let timeout = try DatabaseStatementTimeout.resolve(nil)
        #expect(timeout.milliseconds == 300_000)
    }

    @Test("Accepts positive integer milliseconds")
    func positiveInteger() throws {
        #expect(try DatabaseStatementTimeout.resolve("1").milliseconds == 1)
        #expect(
            try DatabaseStatementTimeout.resolve(String(Int32.max)).milliseconds
                == Int(Int32.max)
        )
    }

    @Test(
        "Rejects empty, non-integer, zero, negative, and out-of-range values",
        arguments: ["", " ", "1.5", "one", "0", "-1", "2147483648"]
    )
    func invalidValue(raw: String) {
        #expect(throws: DatabaseStatementTimeoutConfigurationError.self) {
            try DatabaseStatementTimeout.resolve(raw)
        }
    }

    @Test("Applies one statement_timeout startup parameter without disturbing others")
    func appliesStartupParameter() throws {
        var configuration = PostgresTestDatabases.configuration(database: "strato_test")
        configuration.coreConfiguration.options.additionalStartupParameters = [
            ("application_name", "strato-test"),
            ("statement_timeout", "1"),
        ]

        try DatabaseStatementTimeout(milliseconds: 42_000).apply(to: &configuration)

        let parameters = configuration.coreConfiguration.options.additionalStartupParameters
        #expect(parameters.first(where: { $0.0 == "application_name" })?.1 == "strato-test")
        #expect(parameters.filter { $0.0 == "statement_timeout" }.count == 1)
        #expect(parameters.first(where: { $0.0 == "statement_timeout" })?.1 == "42000")
    }
}

@Suite("Database Statement Timeout Integration", .serialized)
struct DatabaseStatementTimeoutIntegrationTests {

    @Test("A blocked lock query times out and its pooled connection remains usable")
    func blockedLockTimesOut() async throws {
        let databaseName = try await PostgresTestDatabases.shared.createDatabaseForTest()
        let holder = try await Application.makeForTesting(
            database: databaseName,
            owningDatabase: false
        )
        let timed = try await Application.makeForTesting(
            database: databaseName,
            owningDatabase: true
        )

        var configuration = PostgresTestDatabases.configuration(database: databaseName)
        try DatabaseStatementTimeout(milliseconds: 100).apply(to: &configuration)
        timed.databases.use(.postgres(configuration: configuration), as: .psql)

        let attempt: StatementTimeoutAttempt
        do {
            attempt = try await holder.db.withConnection { heldConnection in
                let heldSQL = try #require(heldConnection as? any SQLDatabase)
                let lockName = "strato:statement-timeout:\(UUID().uuidString)"
                try await heldSQL.raw(
                    "SELECT pg_advisory_lock(hashtext(\(bind: lockName)))"
                ).run()

                do {
                    let result = try await timed.db.withConnection { timedConnection in
                        let timedSQL = try #require(timedConnection as? any SQLDatabase)
                        let clock = ContinuousClock()
                        let started = clock.now
                        var errorDescription: String?

                        do {
                            try await timedSQL.raw(
                                "SELECT pg_advisory_lock(hashtext(\(bind: lockName)))"
                            ).run()
                        } catch {
                            // SQLKit redacts `description`; its reflective form
                            // carries the PostgreSQL SQLSTATE and server message.
                            errorDescription = String(reflecting: error)
                        }

                        let elapsed = started.duration(to: clock.now)
                        let probe = try await timedSQL.raw("SELECT 1 AS value")
                            .first(decodingColumn: "value", as: Int.self)
                        return StatementTimeoutAttempt(
                            errorDescription: errorDescription,
                            elapsed: elapsed,
                            connectionProbe: probe
                        )
                    }
                    try await heldSQL.raw(
                        "SELECT pg_advisory_unlock(hashtext(\(bind: lockName)))"
                    ).run()
                    return result
                } catch {
                    try? await heldSQL.raw(
                        "SELECT pg_advisory_unlock(hashtext(\(bind: lockName)))"
                    ).run()
                    throw error
                }
            }
        } catch {
            try? await holder.asyncShutdown()
            try? await timed.shutdownForTesting()
            throw error
        }

        let description = try #require(attempt.errorDescription)
        #expect(description.contains("57014"))
        #expect(description.contains("statement timeout"))
        #expect(attempt.elapsed < .seconds(3))
        #expect(attempt.connectionProbe == 1)

        try await holder.asyncShutdown()
        try await timed.shutdownForTesting()
    }
}

private struct StatementTimeoutAttempt: Sendable {
    let errorDescription: String?
    let elapsed: Duration
    let connectionProbe: Int?
}
