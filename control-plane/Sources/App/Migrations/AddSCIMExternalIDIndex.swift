import Fluent
import FluentPostgresDriver

/// Adds an index on scim_external_ids for internal_id lookups.
/// This optimizes the findExternalID method which queries by (organization_id, resource_type, internal_id).
struct AddSCIMExternalIDIndex: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw(
            """
            CREATE INDEX IF NOT EXISTS idx_scim_external_ids_internal
            ON scim_external_ids (organization_id, resource_type, internal_id)
            """
        ).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw(
            """
            DROP INDEX IF EXISTS idx_scim_external_ids_internal
            """
        ).run()
    }
}
