import AppTestSupport
import Fluent
import FluentPostgresDriver
import Foundation
import SQLKit
import Testing
import Vapor

@testable import App

@Suite("Database Statement Timeout Configuration")
struct DatabaseStatementTimeoutConfigurationTests {

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
            attempt = try await holder.db.transaction { heldTransaction in
                let key = AdvisoryLockKey.object(.dnsZone, id: UUID())
                try await AdvisoryLock.acquireTransactionLock(key, on: heldTransaction)

                let configuredValue = try await timed.db.withConnection { timedConnection in
                    let timedSQL = try #require(timedConnection as? any SQLDatabase)
                    return try await timedSQL.raw(
                        "SELECT current_setting('statement_timeout') AS value"
                    ).first(decodingColumn: "value", as: String.self)
                }
                let clock = ContinuousClock()
                let started = clock.now
                var errorDescription: String?

                do {
                    try await timed.db.transaction { timedTransaction in
                        try await AdvisoryLock.acquireTransactionLock(key, on: timedTransaction)
                    }
                } catch {
                    // SQLKit redacts `description`; its reflective form carries
                    // the PostgreSQL SQLSTATE and server message. Letting the
                    // error escape the transaction also completes its rollback
                    // before the pooled connection is checked below.
                    errorDescription = String(reflecting: error)
                }

                let elapsed = started.duration(to: clock.now)
                let probe = try await timed.db.withConnection { connection in
                    let sql = try #require(connection as? any SQLDatabase)
                    return try await sql.raw("SELECT 1 AS value")
                        .first(decodingColumn: "value", as: Int.self)
                }
                return StatementTimeoutAttempt(
                    errorDescription: errorDescription,
                    elapsed: elapsed,
                    connectionProbe: probe,
                    configuredValue: configuredValue
                )
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

    @Test("Explicit migration transaction stays active across nested Database.transaction")
    func nestedMigrationTransactionDoesNotCommitOuterTransaction() async throws {
        let databaseName = try await PostgresTestDatabases.shared.createDatabaseForTest()
        let app = try await Application.makeForTesting(
            database: databaseName,
            owningDatabase: true
        )
        let timeout = try DatabaseStatementTimeout(milliseconds: 1_000)
        let configuration = PostgresTestDatabases.configuration(database: databaseName)
        app.databases.use(
            timeout.applying(to: .postgres(configuration: configuration)),
            as: .psql
        )
        let migration = NestedTransactionCreatesThenFails()

        var thrown: (any Error)?
        do {
            try await app.db.withConnection { connection in
                let control = try #require(connection as? any TransactionControlDatabase)
                #expect(!connection.inTransaction)
                try await control.beginTransaction().get()
                #expect(connection.inTransaction)
                try await control.rollbackTransaction().get()
                #expect(!connection.inTransaction)

                do {
                    try await SchemaMigrator.applyBatch(
                        [migration],
                        batch: 9999,
                        on: connection,
                        logger: app.logger
                    )
                } catch {
                    #expect(!connection.inTransaction)
                    throw error
                }
            }
        } catch {
            thrown = error
        }

        do {
            let error = try #require(thrown as? SchemaMigrationError)
            #expect(error.description.contains(migration.name))

            let sql = try #require(app.db as? any SQLDatabase)
            let present = try await sql.raw(
                "SELECT to_regclass('public.statement_timeout_nested_transaction_probe') "
                    + "IS NOT NULL AS present"
            ).first(decodingColumn: "present", as: Bool.self)
            #expect(present == false)

            let logged = try await MigrationLog.query(on: app.db)
                .filter(\.$name == migration.name)
                .count()
            #expect(logged == 0)
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

/// Opens a nested `Database.transaction`, lets it return successfully, and
/// then fails. The schema change survives only if that nested call incorrectly
/// commits SchemaMigrator's explicit outer transaction.
private struct NestedTransactionCreatesThenFails: AsyncMigration {
    struct Boom: Error {}

    var name: String { "DatabaseStatementTimeoutTests.NestedTransactionCreatesThenFails" }

    func prepare(on database: any Database) async throws {
        try await database.transaction { nested in
            guard let sql = nested as? any SQLDatabase else {
                throw DatabaseStatementTimeoutConfigurationError.postgresRequired
            }
            try await sql.raw(
                "CREATE TABLE statement_timeout_nested_transaction_probe "
                    + "(id uuid PRIMARY KEY)"
            ).run()
        }
        throw Boom()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS statement_timeout_nested_transaction_probe").run()
    }
}
