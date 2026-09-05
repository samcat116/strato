import AppTestSupport
import Fluent
import Foundation
import SQLKit
import Testing
import Vapor

@testable import App

@Suite("Current schema baseline", .serialized)
struct CurrentSchemaBaselineTests {
    private static let expectedCatalogMD5 = "68575f5dc8fb318887deb3e6a471bd1a"
    private static let expectedCurrentCatalogMD5 = "c517ee5140368851dbb79c4933e62098"

    @Test("A fresh database reaches the reviewed schema from one migration")
    func freshDatabaseMatchesReviewedCatalog() async throws {
        let app = try await Application.makeForBareDatabaseTesting()
        do {
            app.migrations.add(CurrentSchemaBaseline())
            try await app.autoMigrate()

            let logs = try await MigrationLog.query(on: app.db).all()
            #expect(logs.map(\.name) == [CurrentSchemaBaseline().name])
            #expect(try await User.query(on: app.db).count() == 0)
            #expect(try await StoragePool.query(on: app.db).count() == 1)
            #expect(try await StoragePool.defaultPool(on: app.db).name == StoragePool.defaultPoolName)

            let sql = try #require(app.db as? any SQLDatabase)
            let fluentEnumRows = try await sql.raw("SELECT id FROM _fluent_enums").all()
            #expect(fluentEnumRows.count == 12)

            let counts = try await catalogCounts(on: app.db)
            #expect(counts.tables == 70)
            #expect(counts.columns == 914)
            #expect(counts.constraints == 320)
            #expect(counts.indexes == 216)
            #expect(counts.enums == 3)
            #expect(counts.triggers == 3)
            #expect(counts.functions == 2)

            let catalogMD5 = try await catalogMD5(on: app.db)
            #expect(catalogMD5 == Self.expectedCatalogMD5)
        } catch {
            try? await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test("The frozen baseline plus the complete forward chain reaches the reviewed current schema")
    func completeForwardChainReachesCurrentSchema() async throws {
        let app = try await Application.makeForBareDatabaseTesting()
        do {
            app.migrations.add(CurrentSchemaBaseline())
            try await app.autoMigrate()
            let baselineMD5 = try await catalogMD5(on: app.db)
            let baselineCounts = try await catalogCounts(on: app.db)

            app.registerForwardMigrations()
            try await app.autoMigrate()
            let upgradedMD5 = try await catalogMD5(on: app.db)
            let upgradedCounts = try await catalogCounts(on: app.db)

            #expect(baselineMD5 == Self.expectedCatalogMD5)
            #expect(upgradedMD5 == Self.expectedCurrentCatalogMD5)
            #expect(upgradedCounts.tables == 79)
            #expect(upgradedCounts.columns == 1035)
            #expect(upgradedCounts.constraints == 374)
            #expect(upgradedCounts.indexes == 243)
            #expect(upgradedCounts.enums == baselineCounts.enums)
            #expect(upgradedCounts.triggers == baselineCounts.triggers)
            #expect(upgradedCounts.functions == baselineCounts.functions)
            let logs = try await MigrationLog.query(on: app.db).sort(\.$batch).all()
            #expect(logs.first?.name == CurrentSchemaBaseline().name)
            #expect(logs.count > 1, "the equivalence check must exercise the forward chain")
        } catch {
            try? await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test("The guest-agent upgrade leaves a fresh schema unchanged")
    func guestAgentUpgradeIsIdempotentOnFreshSchema() async throws {
        let app = try await Application.makeForBareDatabaseTesting()
        do {
            try await CurrentSchemaBaseline().prepare(on: app.db)
            let catalogBeforeUpgrade = try await catalogMD5(on: app.db)

            let migration = AddGuestAgentEnabledToVM()
            try await migration.prepare(on: app.db)
            try await migration.prepare(on: app.db)

            #expect(try await catalogMD5(on: app.db) == catalogBeforeUpgrade)
        } catch {
            try? await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test("The resource-event run upgrade leaves a fresh schema unchanged")
    func resourceEventRunUpgradeIsIdempotentOnFreshSchema() async throws {
        let app = try await Application.makeForBareDatabaseTesting()
        do {
            try await CurrentSchemaBaseline().prepare(on: app.db)
            let catalogBeforeUpgrade = try await catalogMD5(on: app.db)

            let migration = AddRunResourceEventMutation()
            try await migration.prepare(on: app.db)
            try await migration.prepare(on: app.db)

            #expect(try await catalogMD5(on: app.db) == catalogBeforeUpgrade)
        } catch {
            try? await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test("The webhook claim-lease upgrade is idempotent and restores its queue index")
    func webhookClaimLeaseUpgradeIsIdempotentOnFreshSchema() async throws {
        let app = try await Application.makeForBareDatabaseTesting()
        do {
            try await CurrentSchemaBaseline().prepare(on: app.db)
            let sql = try #require(app.db as? any SQLDatabase)
            let catalogBeforeUpgrade = try await catalogMD5(on: app.db)

            let migration = AddWebhookDeliveryClaimLease()
            try await migration.prepare(on: app.db)
            try await migration.prepare(on: app.db)
            #expect(try await catalogMD5(on: app.db) == catalogBeforeUpgrade)

            try await sql.raw(
                """
                UPDATE pg_index
                SET indisvalid = false
                WHERE indexrelid =
                    'idx_webhook_deliveries_pending_subscription_due'::regclass
                """
            ).run()
            let invalid = try await sql.raw(
                """
                SELECT indisvalid
                FROM pg_index
                WHERE indexrelid =
                    'idx_webhook_deliveries_pending_subscription_due'::regclass
                """
            ).first(decodingColumn: "indisvalid", as: Bool.self)
            #expect(invalid == false)

            try await migration.prepare(on: app.db)
            let repaired = try await sql.raw(
                """
                SELECT indisvalid
                FROM pg_index
                WHERE indexrelid =
                    'idx_webhook_deliveries_pending_subscription_due'::regclass
                """
            ).first(decodingColumn: "indisvalid", as: Bool.self)
            #expect(repaired == true)
            #expect(try await catalogMD5(on: app.db) == catalogBeforeUpgrade)

            try await sql.raw(
                "DROP INDEX idx_webhook_deliveries_pending_subscription_due"
            ).run()
            #expect(try await catalogMD5(on: app.db) != catalogBeforeUpgrade)

            try await migration.prepare(on: app.db)
            try await migration.prepare(on: app.db)
            #expect(try await catalogMD5(on: app.db) == catalogBeforeUpgrade)

            try await sql.raw(
                "ALTER TABLE webhook_deliveries DROP COLUMN enqueued_at"
            ).run()
            #expect(try await catalogMD5(on: app.db) != catalogBeforeUpgrade)

            try await migration.prepare(on: app.db)
            try await migration.prepare(on: app.db)
            #expect(try await catalogMD5(on: app.db) == catalogBeforeUpgrade)
        } catch {
            try? await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test("The MAC ledger upgrade leaves a fresh schema unchanged")
    func macLedgerUpgradeIsIdempotentOnFreshSchema() async throws {
        let app = try await Application.makeForBareDatabaseTesting()
        do {
            try await CurrentSchemaBaseline().prepare(on: app.db)
            let catalogBeforeUpgrade = try await catalogMD5(on: app.db)

            let migration = CreateMACAddressLedger()
            try await migration.prepare(on: app.db)
            try await migration.prepare(on: app.db)
            #expect(try await catalogMD5(on: app.db) == catalogBeforeUpgrade)
        } catch {
            try? await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test("The administrative text-bound upgrade is idempotent and restores missing checks")
    func administrativeTextUpgradeIsIdempotentOnFreshSchema() async throws {
        let app = try await Application.makeForBareDatabaseTesting()
        do {
            try await CurrentSchemaBaseline().prepare(on: app.db)
            let sql = try #require(app.db as? any SQLDatabase)
            let catalogBeforeUpgrade = try await catalogMD5(on: app.db)

            let migration = AddAdministrativeTextLengthConstraints()
            try await migration.prepare(on: app.db)
            #expect(try await catalogMD5(on: app.db) == catalogBeforeUpgrade)

            for statement in [
                "ALTER TABLE iam_guardrails DROP CONSTRAINT ck_iam_guardrails_name_length",
                "ALTER TABLE iam_guardrails DROP CONSTRAINT ck_iam_guardrails_description_length",
                "ALTER TABLE iam_policies DROP CONSTRAINT ck_iam_policies_name_length",
                "ALTER TABLE iam_policies DROP CONSTRAINT ck_iam_policies_description_length",
                "ALTER TABLE iam_roles DROP CONSTRAINT ck_iam_roles_name_length",
                "ALTER TABLE iam_roles DROP CONSTRAINT ck_iam_roles_description_length",
            ] {
                try await sql.raw("\(unsafeRaw: statement)").run()
            }

            #expect(try await catalogMD5(on: app.db) != catalogBeforeUpgrade)
            try await migration.prepare(on: app.db)
            try await migration.prepare(on: app.db)

            #expect(catalogBeforeUpgrade == Self.expectedCatalogMD5)
            #expect(try await catalogMD5(on: app.db) == catalogBeforeUpgrade)
        } catch {
            try? await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test("The administrative text-bound upgrade reports incompatible existing rows")
    func administrativeTextUpgradeRejectsOversizedExistingRows() async throws {
        let app = try await Application.makeForBareDatabaseTesting()
        do {
            try await CurrentSchemaBaseline().prepare(on: app.db)
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw(
                "ALTER TABLE iam_policies DROP CONSTRAINT ck_iam_policies_name_length"
            ).run()
            try await sql.raw(
                """
                INSERT INTO iam_policies (
                    id, name, owner_type, owner_id, cedar_text, effect, enabled
                ) VALUES (
                    \(bind: UUID()), \(bind: String(repeating: "n", count: Validate.nameLength + 1)),
                    'organization', \(bind: UUID()), 'forbid(principal, action, resource);',
                    'forbid', true
                )
                """
            ).run()

            var thrown: (any Error)?
            do {
                try await AddAdministrativeTextLengthConstraints().prepare(on: app.db)
            } catch {
                thrown = error
            }
            let error = try #require(thrown)
            #expect(String(describing: error).contains("iam_policies"))
            #expect(String(describing: error).contains("existing rows exceed"))
        } catch {
            try? await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test("An existing schema is rejected without changing its data")
    func existingDatabaseRequiresExplicitRebuild() async throws {
        let app = try await Application.makeForBareDatabaseTesting()
        do {
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw(
                "CREATE TABLE operator_data (id integer PRIMARY KEY, value text NOT NULL)"
            ).run()
            try await sql.raw("INSERT INTO operator_data (id, value) VALUES (7, 'retain me')").run()

            var thrown: (any Error)?
            do {
                try await configure(app)
            } catch {
                thrown = error
            }

            let error = try #require(thrown as? SchemaMigrationError)
            #expect(error.description.contains(CurrentSchemaBaseline().name))
            #expect(error.description.contains("requires a fresh database"))
            #expect(error.description.contains("operator_data"))

            let retained = try await sql.raw(
                "SELECT value FROM operator_data WHERE id = 7"
            ).first(decodingColumn: "value", as: String.self)
            #expect(retained == "retain me")

            let recorded = try await MigrationLog.query(on: app.db)
                .filter(\.$name == CurrentSchemaBaseline().name)
                .count()
            #expect(recorded == 0)
        } catch {
            try? await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test("A custom search path cannot hide existing public data")
    func customSearchPathStillChecksPublicSchema() async throws {
        let app = try await Application.makeForBareDatabaseTesting()
        do {
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("CREATE SCHEMA baseline_shadow").run()
            try await sql.raw(
                "CREATE TABLE public.operator_data (id integer PRIMARY KEY, value text NOT NULL)"
            ).run()
            try await sql.raw(
                "INSERT INTO public.operator_data (id, value) VALUES (7, 'retain me')"
            ).run()

            try await app.db.transaction { database in
                let transactionSQL = try #require(database as? any SQLDatabase)
                try await transactionSQL.raw(
                    "SET LOCAL search_path TO baseline_shadow, public"
                ).run()

                let currentSchema = try await transactionSQL.raw(
                    "SELECT current_schema() AS schema"
                ).first(decodingColumn: "schema", as: String.self)
                #expect(currentSchema == "baseline_shadow")

                do {
                    try await CurrentSchemaBaseline().prepare(on: database)
                    Issue.record("Expected the baseline to reject the populated public schema")
                } catch let error as CurrentSchemaBaselineError {
                    #expect(error.description.contains("public schema"))
                    #expect(error.description.contains("operator_data"))
                }
            }

            let retained = try await sql.raw(
                "SELECT value FROM public.operator_data WHERE id = 7"
            ).first(decodingColumn: "value", as: String.self)
            #expect(retained == "retain me")
        } catch {
            try? await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private func catalogCounts(on database: any Database) async throws -> CatalogCounts {
        let sql = try #require(database as? any SQLDatabase)
        return try #require(
            try await sql.raw(
                """
                SELECT
                  (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                    WHERE n.nspname = 'public' AND c.relkind = 'r'
                      AND c.relname <> '_fluent_migrations')::int AS tables,
                  (SELECT count(*) FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
                    JOIN pg_namespace n ON n.oid = c.relnamespace
                    WHERE n.nspname = 'public' AND c.relkind = 'r'
                      AND c.relname <> '_fluent_migrations' AND a.attnum > 0
                      AND NOT a.attisdropped)::int AS columns,
                  (SELECT count(*) FROM pg_constraint con JOIN pg_class c ON c.oid = con.conrelid
                    JOIN pg_namespace n ON n.oid = c.relnamespace
                    WHERE n.nspname = 'public'
                      AND c.relname <> '_fluent_migrations')::int AS constraints,
                  (SELECT count(*) FROM pg_index x JOIN pg_class c ON c.oid = x.indrelid
                    JOIN pg_namespace n ON n.oid = c.relnamespace
                    WHERE n.nspname = 'public'
                      AND c.relname <> '_fluent_migrations')::int AS indexes,
                  (SELECT count(DISTINCT t.oid) FROM pg_type t
                    JOIN pg_namespace n ON n.oid = t.typnamespace
                    JOIN pg_enum e ON e.enumtypid = t.oid
                    WHERE n.nspname = 'public')::int AS enums,
                  (SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
                    JOIN pg_namespace n ON n.oid = c.relnamespace
                    WHERE n.nspname = 'public' AND NOT t.tgisinternal)::int AS triggers,
                  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname = 'public')::int AS functions
                """
            ).first(decoding: CatalogCounts.self)
        )
    }

    private func catalogMD5(on database: any Database) async throws -> String {
        let sql = try #require(database as? any SQLDatabase)
        return try #require(
            try await sql.raw(
                """
                WITH objects AS (
                  SELECT 'enum' AS kind, n.nspname || '.' || t.typname AS identity,
                    string_agg(e.enumlabel, ',' ORDER BY e.enumsortorder) AS definition
                  FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                    JOIN pg_enum e ON e.enumtypid = t.oid
                  WHERE n.nspname = 'public' GROUP BY n.nspname, t.typname
                  UNION ALL
                  SELECT 'column', n.nspname || '.' || c.relname || '.' || a.attname,
                    format_type(a.atttypid, a.atttypmod) || '|' || a.attnotnull::text || '|'
                      || coalesce(pg_get_expr(ad.adbin, ad.adrelid), '')
                  FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
                    JOIN pg_namespace n ON n.oid = c.relnamespace
                    LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
                  WHERE n.nspname = 'public' AND c.relkind = 'r'
                    AND c.relname <> '_fluent_migrations' AND a.attnum > 0 AND NOT a.attisdropped
                  UNION ALL
                  SELECT 'constraint', n.nspname || '.' || c.relname || '.' || con.conname,
                    pg_get_constraintdef(con.oid, true)
                  FROM pg_constraint con JOIN pg_class c ON c.oid = con.conrelid
                    JOIN pg_namespace n ON n.oid = c.relnamespace
                  WHERE n.nspname = 'public' AND c.relname <> '_fluent_migrations'
                  UNION ALL
                  SELECT 'index', n.nspname || '.' || c.relname || '.' || i.relname,
                    pg_get_indexdef(i.oid)
                  FROM pg_index x JOIN pg_class c ON c.oid = x.indrelid
                    JOIN pg_class i ON i.oid = x.indexrelid
                    JOIN pg_namespace n ON n.oid = c.relnamespace
                  WHERE n.nspname = 'public' AND c.relname <> '_fluent_migrations'
                  UNION ALL
                  SELECT 'trigger', n.nspname || '.' || c.relname || '.' || t.tgname,
                    pg_get_triggerdef(t.oid, true)
                  FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
                    JOIN pg_namespace n ON n.oid = c.relnamespace
                  WHERE n.nspname = 'public' AND NOT t.tgisinternal
                  UNION ALL
                  SELECT 'function', n.nspname || '.' || p.proname || '('
                      || pg_get_function_identity_arguments(p.oid) || ')',
                    pg_get_functiondef(p.oid)
                  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname = 'public'
                )
                SELECT md5(string_agg(
                  kind || chr(9) || identity || chr(9) || replace(definition, chr(10), ' '),
                  chr(10) ORDER BY kind, identity
                )) AS digest
                FROM objects
                """
            ).first(decodingColumn: "digest", as: String.self)
        )
    }
}

private struct CatalogCounts: Decodable, Equatable {
    let tables: Int
    let columns: Int
    let constraints: Int
    let indexes: Int
    let enums: Int
    let triggers: Int
    let functions: Int
}
