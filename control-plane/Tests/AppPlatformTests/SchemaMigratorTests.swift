import AppTestSupport
import Fluent
import FluentPostgresDriver
import Logging
import SQLKit
import Testing
import Vapor

@testable import App

/// STR-183: the schema phase has to survive two replicas booting at once, and a
/// crash in the middle of a migration.
///
/// These cannot use `withTestApp`: every standard fixture hands out a clone of a
/// **pre-migrated** template, and the races here are only observable against a
/// genuinely unmigrated database. `createBareDatabaseForTest()` mints one, and
/// `Application.makeForTesting(database:owningDatabase:)` points more than one
/// application at it.
@Suite("Schema Migrator", .serialized)
struct SchemaMigratorTests {

    // MARK: - Half 1: serialization

    @Test("Two boots racing an empty database both succeed, and each migration is logged once")
    func racingBootsMigrateExactlyOnce() async throws {
        let databaseName = try await PostgresTestDatabases.shared.createBareDatabaseForTest()
        let first = try await Application.makeForTesting(database: databaseName, owningDatabase: false)
        let second = try await Application.makeForTesting(database: databaseName, owningDatabase: true)

        do {
            async let firstBoot: Void = configure(first)
            async let secondBoot: Void = configure(second)
            _ = try await (firstBoot, secondBoot)

            let sql = try #require(second.db as? any SQLDatabase)
            let duplicates = try await sql.raw(
                "SELECT name FROM _fluent_migrations GROUP BY name HAVING count(*) > 1"
            ).all(decoding: MigrationName.self)
            #expect(duplicates.isEmpty, "a migration was recorded twice: \(duplicates.map(\.name))")

            // Sanity: the schema really was built, not just left empty.
            let applied = try await MigrationLog.query(on: second.db).count()
            #expect(applied > 100)
            #expect(try await User.query(on: second.db).count() == 0)
        } catch {
            try? await first.asyncShutdown()
            try? await second.shutdownForTesting()
            throw error
        }

        // The owning application drops the clone `WITH (FORCE)`, so it goes last.
        try await first.asyncShutdown()
        try await second.shutdownForTesting()
    }

    @Test("A lock another process holds is reported by name rather than waited on forever")
    func lockTimeoutNamesTheLock() async throws {
        let databaseName = try await PostgresTestDatabases.shared.createDatabaseForTest()
        let holder = try await Application.makeForTesting(database: databaseName, owningDatabase: false)
        let waiter = try await Application.makeForTesting(database: databaseName, owningDatabase: true)

        // `withConnection`'s closure is @Sendable and `any Error` is not, so the
        // failure comes back as its rendered description rather than the value.
        let thrown: LockAttempt
        do {
            thrown = try await holder.db.withConnection { held in
                let sql = try #require(held as? any SQLDatabase)
                _ = try await sql.raw(
                    "SELECT pg_advisory_lock(hashtext(\(bind: SchemaMigrator.lockName)))"
                ).all()

                var attempt = LockAttempt(isSchemaMigrationError: false, description: nil)
                do {
                    try await waiter.db.withConnection { waiting in
                        _ = try await SchemaMigrator.acquireLock(
                            on: waiting,
                            timeout: 1,
                            poll: 0.2,
                            logger: waiter.logger
                        )
                    }
                } catch {
                    attempt = LockAttempt(
                        isSchemaMigrationError: error is SchemaMigrationError,
                        description: (error as? SchemaMigrationError)?.description ?? "\(error)"
                    )
                }

                _ = try await sql.raw(
                    "SELECT pg_advisory_unlock(hashtext(\(bind: SchemaMigrator.lockName)))"
                ).all()
                return attempt
            }
        } catch {
            try? await holder.asyncShutdown()
            try? await waiter.shutdownForTesting()
            throw error
        }

        #expect(thrown.isSchemaMigrationError)
        let description = try #require(thrown.description)
        #expect(description.contains(SchemaMigrator.lockName))
        #expect(description.contains("Timed out"))

        try await holder.asyncShutdown()
        try await waiter.shutdownForTesting()
    }

    // MARK: - Half 2: atomicity

    @Test("A migration that fails partway leaves neither its schema change nor its log row")
    func failedMigrationLeavesNothingBehind() async throws {
        try await withTestApp { app in
            let migration = CreatesThenFails()

            var thrown: (any Error)?
            do {
                try await app.db.withConnection { connection in
                    try await SchemaMigrator.applyBatch(
                        [migration],
                        batch: 9999,
                        on: connection,
                        logger: app.logger
                    )
                }
            } catch {
                thrown = error
            }

            let error = try #require(thrown as? SchemaMigrationError)
            #expect(error.description.contains(migration.name))

            // The transaction rolled back: the table it created is gone, and no
            // row claims the migration ran. The next boot re-runs it cleanly.
            let sql = try #require(app.db as? any SQLDatabase)
            let present = try await sql.raw(
                "SELECT to_regclass('public.schema_migrator_probe') IS NOT NULL AS present"
            ).first(decodingColumn: "present", as: Bool.self)
            #expect(present == false)

            let logged = try await MigrationLog.query(on: app.db)
                .filter(\.$name == migration.name)
                .count()
            #expect(logged == 0)
        }
    }

    @Test("A successful migration commits its schema change and its log row together")
    func successfulMigrationRecordsItself() async throws {
        try await withTestApp { app in
            let migration = CreatesProbeTable()
            let batch = try await SchemaMigrator.nextBatchNumber(on: app.db)

            try await app.db.withConnection { connection in
                try await SchemaMigrator.applyBatch(
                    [migration],
                    batch: batch,
                    on: connection,
                    logger: app.logger
                )
            }

            let sql = try #require(app.db as? any SQLDatabase)
            let present = try await sql.raw(
                "SELECT to_regclass('public.schema_migrator_probe') IS NOT NULL AS present"
            ).first(decodingColumn: "present", as: Bool.self)
            #expect(present == true)

            let logged = try await MigrationLog.query(on: app.db)
                .filter(\.$name == migration.name)
                .all()
            #expect(logged.count == 1)
            #expect(logged.first?.batch == batch)

            try await sql.raw("DROP TABLE IF EXISTS schema_migrator_probe").run()
        }
    }

    @Test("A migration whose log row was lost is reported as a schema/log disagreement")
    func missingLogRowIsDiagnosed() async throws {
        let databaseName = try await PostgresTestDatabases.shared.createBareDatabaseForTest()
        let first = try await Application.makeForTesting(database: databaseName, owningDatabase: false)
        let second = try await Application.makeForTesting(database: databaseName, owningDatabase: true)

        var thrown: (any Error)?
        do {
            try await configure(first)

            // Exactly failure mode 2's aftermath: the schema change is present,
            // the row that records it is not.
            let lostMigration = CreateUser().name
            let sql = try #require(first.db as? any SQLDatabase)
            try await sql.raw("DELETE FROM _fluent_migrations WHERE name = \(bind: lostMigration)").run()

            do {
                try await configure(second)
            } catch {
                thrown = error
            }

            let error = try #require(thrown as? SchemaMigrationError)
            #expect(error.description.contains(lostMigration))
            #expect(error.description.contains("_fluent_migrations"))
            #expect(error.description.contains("INSERT INTO _fluent_migrations"))
        } catch {
            try? await first.asyncShutdown()
            try? await second.shutdownForTesting()
            throw error
        }

        try await first.asyncShutdown()
        try await second.shutdownForTesting()
    }

    // MARK: - STRATO_RUN_MIGRATIONS

    @Test("A process that does not migrate refuses to boot against a schema that is behind")
    func pendingMigrationsFailWhenMigrationsAreDisabled() async throws {
        try await withTestApp { app in
            // Nothing pending: the fully migrated clone verifies clean.
            try await SchemaMigrator.run(on: app, options: .init(runMigrations: false))

            // One migration this database has never seen.
            let pending = CreatesProbeTable()
            let migrations = Migrations()
            migrations.add(pending)

            var thrown: (any Error)?
            do {
                try await app.db.withConnection { connection in
                    let migrator = Migrator(
                        databaseFactory: { _ in connection },
                        migrations: migrations,
                        on: connection.eventLoop
                    )
                    try await SchemaMigrator.verifyNothingPending(migrator: migrator, logger: app.logger)
                }
            } catch {
                thrown = error
            }

            let error = try #require(thrown as? SchemaMigrationError)
            #expect(error.description.contains(pending.name))
            #expect(error.description.contains(SchemaMigrator.runMigrationsKey))

            // Verification is read-only: it must not have applied anything.
            let sql = try #require(app.db as? any SQLDatabase)
            let present = try await sql.raw(
                "SELECT to_regclass('public.schema_migrator_probe') IS NOT NULL AS present"
            ).first(decodingColumn: "present", as: Bool.self)
            #expect(present == false)
        }
    }
}

// MARK: - Fixtures

private struct MigrationName: Decodable {
    let name: String
}

private struct LockAttempt: Sendable {
    let isSchemaMigrationError: Bool
    let description: String?
}

/// Creates a table and then fails, so the test can assert the table is gone.
private struct CreatesThenFails: AsyncMigration {
    struct Boom: Error {}

    var name: String { "SchemaMigratorTests.CreatesThenFails" }

    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("CREATE TABLE schema_migrator_probe (id uuid PRIMARY KEY)").run()
        throw Boom()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS schema_migrator_probe").run()
    }
}

private struct CreatesProbeTable: AsyncMigration {
    var name: String { "SchemaMigratorTests.CreatesProbeTable" }

    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("CREATE TABLE schema_migrator_probe (id uuid PRIMARY KEY)").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS schema_migrator_probe").run()
    }
}
