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

    @Test("Migration timeout defaults to serving timeout and validates its own setting")
    func migrationValue() throws {
        let normal = try DatabaseStatementTimeout(milliseconds: 42_000)
        #expect(
            try DatabaseStatementTimeout.resolveMigration(nil, defaultingTo: normal)
                == normal
        )
        #expect(
            try DatabaseStatementTimeout.resolveMigration("900000", defaultingTo: normal)
                .milliseconds == 900_000
        )

        var description: String?
        do {
            _ = try DatabaseStatementTimeout.resolveMigration("0", defaultingTo: normal)
        } catch {
            description = String(describing: error)
        }
        #expect(description?.contains(DatabaseStatementTimeout.migrationEnvironmentKey) == true)
    }

    @Test("Does not add statement_timeout to the PostgreSQL startup packet")
    func avoidsStartupParameter() throws {
        var configuration = PostgresTestDatabases.configuration(database: "strato_test")
        configuration.coreConfiguration.options.additionalStartupParameters = [
            ("application_name", "strato-test")
        ]

        _ = try DatabaseStatementTimeout(milliseconds: 42_000).applying(
            to: .postgres(configuration: configuration)
        )

        let parameters = configuration.coreConfiguration.options.additionalStartupParameters
        #expect(parameters.first(where: { $0.0 == "application_name" })?.1 == "strato-test")
        #expect(parameters.allSatisfy { $0.0 != "statement_timeout" })
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

        let configuration = PostgresTestDatabases.configuration(database: databaseName)
        let timeout = try DatabaseStatementTimeout(milliseconds: 100)
        timed.databases.use(
            timeout.applying(to: .postgres(configuration: configuration)),
            as: .psql
        )

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
                        let configuredValue = try await timedSQL.raw(
                            "SELECT current_setting('statement_timeout') AS value"
                        ).first(decodingColumn: "value", as: String.self)
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
                            connectionProbe: probe,
                            configuredValue: configuredValue
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
        #expect(attempt.configuredValue == "100ms")

        try await holder.asyncShutdown()
        try await timed.shutdownForTesting()
    }

    @Test("Migration work gets its longer budget and always restores the serving timeout")
    func migrationBudgetIsScoped() async throws {
        let databaseName = try await PostgresTestDatabases.shared.createDatabaseForTest()
        let app = try await Application.makeForTesting(
            database: databaseName,
            owningDatabase: true
        )
        let normal = try DatabaseStatementTimeout(milliseconds: 50)
        let migration = try DatabaseStatementTimeout(milliseconds: 1_000)
        let configuration = PostgresTestDatabases.configuration(database: databaseName)
        app.databases.use(
            normal.applying(to: .postgres(configuration: configuration)),
            as: .psql
        )

        do {
            try await app.db.withConnection { connection in
                let sql = try #require(connection as? any SQLDatabase)
                let before = try await currentStatementTimeout(on: sql)
                #expect(before == "50ms")

                try await SchemaMigrator.withMigrationStatementTimeout(
                    .init(normal: normal, migration: migration),
                    on: connection,
                    logger: app.logger
                ) {
                    #expect(try await currentStatementTimeout(on: sql) == "1s")
                    try await sql.raw("SELECT pg_sleep(0.2)").run()
                }

                #expect(try await currentStatementTimeout(on: sql) == "50ms")

                do {
                    try await SchemaMigrator.withMigrationStatementTimeout(
                        .init(normal: normal, migration: migration),
                        on: connection,
                        logger: app.logger
                    ) {
                        throw ExpectedMigrationFailure()
                    }
                } catch is ExpectedMigrationFailure {
                    // Expected: cleanup must still restore the serving value.
                }
                #expect(try await currentStatementTimeout(on: sql) == "50ms")
            }
        } catch {
            try? await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    private func currentStatementTimeout(on sql: any SQLDatabase) async throws -> String? {
        try await sql.raw(
            "SELECT current_setting('statement_timeout') AS value"
        ).first(decodingColumn: "value", as: String.self)
    }
}

private struct StatementTimeoutAttempt: Sendable {
    let errorDescription: String?
    let elapsed: Duration
    let connectionProbe: Int?
    let configuredValue: String?
}

private struct ExpectedMigrationFailure: Error {}
