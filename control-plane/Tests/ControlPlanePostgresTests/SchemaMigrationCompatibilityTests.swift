import AppTestSupport
import Foundation
import PostgresNIO
import Testing

@testable import ControlPlanePostgres

@Suite("Native schema migration compatibility", .serialized)
struct SchemaMigrationCompatibilityTests {
    @Test("Fresh schema matches the frozen origin/main Fluent catalog")
    func freshSchemaCatalogParity() async throws {
        try await withBareNativePostgresDatabase { database in
            let migrator = try SchemaMigrator(
                database: database,
                migrations: StratoMigrations.current,
                logger: testLogger()
            )
            try await migrator.run(options: migrationOptions())

            try await database.withSession(operation: "test.catalog_parity") { session in
                for expectation in Self.fluentCatalogBaseline {
                    let rows = try await session.query(
                        PostgresQuery(unsafeSQL: expectation.sql),
                        operation: "test.catalog_parity.query"
                    )
                    let row = try #require(rows.first)
                    #expect(rows.count == 1)
                    let (entryCount, digest) = try row.decode((Int, String).self)
                    #expect(entryCount == expectation.count)
                    #expect(digest == expectation.digest)
                }
            }
        }
    }

    @Test("Disabled migrations reject a pending schema and accept a current one")
    func disabledMigrationVerification() async throws {
        try await withBareNativePostgresDatabase { database in
            let migrator = try SchemaMigrator(
                database: database,
                migrations: StratoMigrations.current,
                logger: testLogger()
            )

            await #expect(throws: SchemaMigrationError.self) {
                try await migrator.run(options: migrationOptions(runMigrations: false))
            }

            try await migrator.run(options: migrationOptions())
            try await migrator.run(options: migrationOptions(runMigrations: false))
        }
    }

    @Test("A failed migration rolls back both DDL and its ledger row")
    func migrationAtomicity() async throws {
        try await withBareNativePostgresDatabase { database in
            let migration = CreateThenFailMigration()
            let migrator = try SchemaMigrator(
                database: database,
                migrations: [migration],
                logger: testLogger()
            )

            await #expect(throws: SchemaMigrationError.self) {
                try await migrator.run(options: migrationOptions())
            }

            try await database.withSession(operation: "test.migration_atomicity") { session in
                let tableRows = try await session.query(
                    "SELECT to_regclass('public.native_migration_probe') IS NOT NULL AS present",
                    operation: "test.migration_atomicity.table"
                )
                #expect(try tableRows.first?.decode(Bool.self) == false)

                let ledgerRows = try await session.query(
                    "SELECT count(*)::bigint AS count FROM _fluent_migrations WHERE name = \(migration.name)",
                    operation: "test.migration_atomicity.ledger"
                )
                #expect(try ledgerRows.first?.decode(Int.self) == 0)
            }
        }
    }

    @Test("Two migrators serialize and record every migration once")
    func concurrentMigrators() async throws {
        let databaseName = try await PostgresTestDatabases.shared.createBareDatabaseForTest()
        let configuration = try PostgresTestDatabases.nativeConfiguration(database: databaseName)
        let first = ControlPlanePostgres.PostgresDatabase(
            configuration: configuration,
            eventLoopGroup: PostgresTestDatabases.appEventLoopGroup,
            logger: testLogger()
        )
        let second = ControlPlanePostgres.PostgresDatabase(
            configuration: configuration,
            eventLoopGroup: PostgresTestDatabases.appEventLoopGroup,
            logger: testLogger()
        )

        do {
            try await first.start()
            try await second.start()
            let firstMigrator = try SchemaMigrator(
                database: first, migrations: StratoMigrations.current, logger: testLogger())
            let secondMigrator = try SchemaMigrator(
                database: second, migrations: StratoMigrations.current, logger: testLogger())

            async let firstRun: Void = firstMigrator.run(options: migrationOptions())
            async let secondRun: Void = secondMigrator.run(options: migrationOptions())
            _ = try await (firstRun, secondRun)

            try await first.withSession(operation: "test.concurrent_migrators") { session in
                let rows = try await session.query(
                    "SELECT count(*)::bigint AS count, count(DISTINCT name)::bigint AS distinct_count FROM _fluent_migrations",
                    operation: "test.concurrent_migrators.ledger"
                )
                let row = try #require(rows.first)
                let (count, distinctCount) = try row.decode((Int, Int).self)
                #expect(count == StratoMigrations.current.count)
                #expect(distinctCount == StratoMigrations.current.count)
            }

            await first.shutdown()
            await second.shutdown()
            await PostgresTestDatabases.shared.dropDatabase(databaseName)
        } catch {
            await first.shutdown()
            await second.shutdown()
            await PostgresTestDatabases.shared.dropDatabase(databaseName)
            throw error
        }
    }

    @Test("Migration timeout is restored to the serving timeout")
    func timeoutRestoration() async throws {
        try await withBareNativePostgresDatabase(statementTimeoutMilliseconds: 321) { database in
            let migrator = try SchemaMigrator(
                database: database,
                migrations: [NoOpMigration()],
                logger: testLogger()
            )
            try await migrator.run(
                options: migrationOptions(
                    servingStatementTimeoutMilliseconds: 321,
                    migrationStatementTimeoutMilliseconds: 4_000
                )
            )

            try await database.withSession(operation: "test.timeout_restoration") { session in
                let rows = try await session.query(
                    "SELECT current_setting('statement_timeout') AS value",
                    operation: "test.timeout_restoration.read"
                )
                #expect(try rows.first?.decode(String.self) == "321ms")
            }
        }
    }

    private static let fluentCatalogBaseline: [CatalogExpectation] = [
        .init(
            name: "relations", count: 71, digest: "e953794cac7964260ab5e965a27887c9",
            sql: """
                SELECT count(*)::bigint AS entry_count,
                       md5(string_agg(concat_ws('|', c.relname, c.relkind, c.relpersistence), E'\\n'
                           ORDER BY c.relname, c.relkind)) AS digest
                FROM pg_class c
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'S')
                """),
        .init(
            name: "columns", count: 925, digest: "d79ea7bb93a433093f9aa517cdcbca19",
            sql: """
                SELECT count(*)::bigint AS entry_count,
                       md5(string_agg(concat_ws('|', table_name, column_name, ordinal_position,
                           data_type, udt_name, is_nullable, COALESCE(column_default, '<null>'),
                           COALESCE(character_maximum_length::text, '<null>'),
                           COALESCE(numeric_precision::text, '<null>'),
                           COALESCE(datetime_precision::text, '<null>'), is_identity,
                           identity_generation, is_generated, generation_expression), E'\\n'
                           ORDER BY table_name, ordinal_position)) AS digest
                FROM information_schema.columns WHERE table_schema = 'public'
                """),
        .init(
            name: "constraints", count: 328, digest: "e5965b2127fce5f640bc1171854c7196",
            sql: """
                SELECT count(*)::bigint AS entry_count,
                       md5(string_agg(concat_ws('|', c.conrelid::regclass::text, c.conname,
                           c.contype, c.condeferrable, c.condeferred, c.convalidated,
                           pg_get_constraintdef(c.oid, true)), E'\\n'
                           ORDER BY c.conrelid::regclass::text, c.conname)) AS digest
                FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace
                WHERE n.nspname = 'public'
                """),
        .init(
            name: "indexes", count: 210, digest: "45af49bc929bfbaaf82dd6c876b70d46",
            sql: """
                SELECT count(*)::bigint AS entry_count,
                       md5(string_agg(concat_ws('|', tablename, indexname, indexdef), E'\\n'
                           ORDER BY tablename, indexname)) AS digest
                FROM pg_indexes WHERE schemaname = 'public'
                """),
        .init(
            name: "enums", count: 12, digest: "1b6a9b8ae9bc29bafc0663f3c1666878",
            sql: """
                SELECT count(*)::bigint AS entry_count,
                       md5(string_agg(concat_ws('|', t.typname, e.enumlabel, e.enumsortorder), E'\\n'
                           ORDER BY t.typname, e.enumsortorder)) AS digest
                FROM pg_type t JOIN pg_enum e ON e.enumtypid = t.oid
                JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname = 'public'
                """),
        .init(
            name: "triggers", count: 1, digest: "0a93402d631bf28e83d754d849fbe76b",
            sql: """
                SELECT count(*)::bigint AS entry_count,
                       md5(string_agg(concat_ws('|', c.relname, t.tgname,
                           pg_get_triggerdef(t.oid, true)), E'\\n' ORDER BY c.relname, t.tgname)) AS digest
                FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = 'public' AND NOT t.tgisinternal
                """),
        .init(
            name: "functions", count: 1, digest: "f42045aa59da47a5032d695f92e585c8",
            sql: """
                SELECT count(*)::bigint AS entry_count,
                       md5(string_agg(concat_ws('|', p.proname,
                           pg_get_function_identity_arguments(p.oid), pg_get_functiondef(p.oid)), E'\\n'
                           ORDER BY p.proname, pg_get_function_identity_arguments(p.oid))) AS digest
                FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'public'
                """),
        .init(
            name: "extensions", count: 1, digest: "e2789c545aaac4fd5c1fcbf1364795b0",
            sql: """
                SELECT count(*)::bigint AS entry_count,
                       md5(string_agg(concat_ws('|', e.extname, e.extversion, n.nspname), E'\\n'
                           ORDER BY e.extname)) AS digest
                FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
                """),
        .init(
            name: "migration_ledger", count: 16, digest: "c525fdfa47385a9e380ed6492c8a861e",
            sql: """
                SELECT count(*)::bigint AS entry_count,
                       md5(string_agg(concat_ws('|', name, batch), E'\\n'
                           ORDER BY batch, created_at, name)) AS digest
                FROM _fluent_migrations
                """),
    ]
}

private struct CatalogExpectation: Sendable {
    let name: String
    let count: Int
    let digest: String
    let sql: String
}

private struct CreateThenFailMigration: StratoMigration {
    struct Failure: Error {}

    let name = "ControlPlanePostgresTests.CreateThenFailMigration"

    func apply(on session: PostgresSession) async throws {
        try await session.command(
            "CREATE TABLE native_migration_probe (id UUID PRIMARY KEY)",
            operation: "test.migration.create_then_fail"
        )
        throw Failure()
    }
}

private struct NoOpMigration: StratoMigration {
    let name = "ControlPlanePostgresTests.NoOpMigration"
    func apply(on session: PostgresSession) async throws {}
}
