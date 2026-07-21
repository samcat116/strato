import Fluent
import SQLKit

/// IAM phase 1 (issue #477): the `role_bindings` policy store the Cedar
/// evaluator answers from.
struct CreateRoleBinding: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("role_bindings")
            .id()
            .field("principal_type", .string, .required)
            .field("principal_id", .uuid, .required)
            .field("role", .string, .required)
            .field("node_type", .string, .required)
            .field("node_id", .uuid, .required)
            .field("condition", .string)
            .field("expires_at", .datetime)
            .field("created_by", .uuid)
            .field("created_at", .datetime)
            // One row per (principal, role, node) makes dual-writes and
            // backfills idempotent upserts. Conditioned duplicates are a
            // later-phase concern; phase 1 writes no conditions.
            .unique(on: "principal_type", "principal_id", "role", "node_type", "node_id")
            .create()

        // Secondary lookup indexes: by node (who-can, resource cleanup) and by
        // principal (offboarding sweeps). Plain SQL works on both Postgres and
        // SQLite.
        if let sql = database as? SQLDatabase {
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_role_bindings_node ON role_bindings (node_type, node_id)"
            ).run()
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_role_bindings_principal ON role_bindings (principal_type, principal_id)"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema("role_bindings").delete()
    }
}
