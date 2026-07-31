import Fluent
import FluentPostgresDriver

/// Alters the SCIM token foreign key from CASCADE to RESTRICT on delete.
/// This prevents accidentally deleting all SCIM tokens when a user is deleted,
/// which could disrupt SCIM synchronization for an entire organization.
///
/// Note: altering a foreign key needs raw Postgres DDL, so the migration
/// guards on the database type.
struct AlterSCIMTokenForeignKey: AsyncMigration {
    func prepare(on database: Database) async throws {
        // Postgres-specific DDL.
        guard database is PostgresDatabase else {
            return
        }

        // Drop the existing foreign key constraint
        try await database.schema("scim_tokens")
            .deleteConstraint(name: "scim_tokens_created_by_id_fkey")
            .update()

        // Add the new foreign key with RESTRICT on delete
        try await database.schema("scim_tokens")
            .foreignKey(
                "created_by_id", references: "users", "id", onDelete: .restrict, name: "scim_tokens_created_by_id_fkey"
            )
            .update()
    }

    func revert(on database: Database) async throws {
        // Postgres-specific DDL.
        guard database is PostgresDatabase else {
            return
        }

        // Drop the RESTRICT constraint
        try await database.schema("scim_tokens")
            .deleteConstraint(name: "scim_tokens_created_by_id_fkey")
            .update()

        // Restore the CASCADE constraint
        try await database.schema("scim_tokens")
            .foreignKey(
                "created_by_id", references: "users", "id", onDelete: .cascade, name: "scim_tokens_created_by_id_fkey"
            )
            .update()
    }
}
