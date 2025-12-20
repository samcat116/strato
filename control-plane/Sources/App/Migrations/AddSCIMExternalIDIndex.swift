import Fluent
import FluentPostgresDriver
import FluentSQLiteDriver

/// Adds an index on scim_external_ids for internal_id lookups.
/// This optimizes the findExternalID method which queries by (organization_id, resource_type, internal_id).
struct AddSCIMExternalIDIndex: AsyncMigration {
    func prepare(on database: Database) async throws {
        if database is PostgresDatabase {
            try await (database as! SQLDatabase).raw("""
                CREATE INDEX IF NOT EXISTS idx_scim_external_ids_internal
                ON scim_external_ids (organization_id, resource_type, internal_id)
                """).run()
        } else if database is SQLiteDatabase {
            try await (database as! SQLDatabase).raw("""
                CREATE INDEX IF NOT EXISTS idx_scim_external_ids_internal
                ON scim_external_ids (organization_id, resource_type, internal_id)
                """).run()
        }
    }

    func revert(on database: Database) async throws {
        if database is PostgresDatabase || database is SQLiteDatabase {
            try await (database as! SQLDatabase).raw("""
                DROP INDEX IF EXISTS idx_scim_external_ids_internal
                """).run()
        }
    }
}
