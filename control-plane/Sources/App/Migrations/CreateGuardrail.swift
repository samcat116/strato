import Fluent
import SQLKit

/// IAM phase 2 (issue #479): the tier-2 guardrail store — ceilings on what
/// tier-3 grants can reach, forbid-only by construction.
struct CreateGuardrail: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("iam_guardrails")
            .id()
            .field("name", .string, .required)
            .field("description", .string)
            .field("node_type", .string, .required)
            .field("node_id", .uuid, .required)
            .field("effect", .string, .required)
            .field("actions", .array(of: .string), .required)
            .field("principal_match_kind", .string, .required)
            .field("principal_match_id", .uuid)
            .field("resource_match_kind", .string, .required)
            .field("resource_match_value", .string)
            .field("enabled", .bool, .required)
            .field("created_by", .uuid)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            // The name identifies the guardrail in a denial, so it has to be
            // unambiguous within the node it hangs on.
            .unique(on: "node_type", "node_id", "name")
            .create()

        if let sql = database as? SQLDatabase {
            // The lookup every evaluation does: all guardrails attached to the
            // nodes in an ancestry chain.
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_iam_guardrails_node ON iam_guardrails (node_type, node_id)"
            ).run()

            // Forbid-only, enforced by the database and not only by the code
            // that writes it. `GuardrailEffect` has a single case and the store
            // rejects a permit-shaped request with a 400; this is the backstop
            // for anything reaching the table another way (a repair script, a
            // future bulk import). Postgres only: SQLite cannot add a CHECK
            // outside CREATE TABLE, and the SQLite path is local tests, where
            // the two layers above are in force.
            if sql.dialect.name == "postgresql" {
                try await sql.raw(
                    """
                    ALTER TABLE iam_guardrails
                    ADD CONSTRAINT iam_guardrails_forbid_only CHECK (effect = 'forbid')
                    """
                ).run()
            }
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema("iam_guardrails").delete()
    }
}
