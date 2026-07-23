import Fluent
import SQLKit

/// IAM roles/policies authoring (issue #606): the authored-policy store —
/// permit/forbid policies written directly in Cedar, owned by an org or
/// project and compiled into the policy set alongside role permits and
/// guardrail forbids.
struct CreateIAMPolicy: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("iam_policies")
            .id()
            .field("name", .string, .required)
            .field("description", .string)
            .field("owner_type", .string, .required)
            .field("owner_id", .uuid, .required)
            .field("cedar_text", .string, .required)
            .field("effect", .string, .required)
            .field("enabled", .bool, .required)
            .field("created_by", .uuid)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            // The name identifies the policy in who-can results and API errors,
            // so it has to be unambiguous within its owner.
            .unique(on: "owner_type", "owner_id", "name")
            .create()

        if let sql = database as? SQLDatabase {
            // The listing every policies/who-can query does: rows by owner.
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_iam_policies_owner ON iam_policies (owner_type, owner_id)"
            ).run()

            // Effect is derived from the Cedar text and can only be `permit` or
            // `forbid`; the store enforces that, and this CHECK is the backstop
            // for anything reaching the table another way (a repair script, a
            // bulk import). Postgres is the only backend, but the guard keeps
            // this a no-op rather than a crash on any other dialect.
            if sql.dialect.name == "postgresql" {
                try await sql.raw(
                    """
                    ALTER TABLE iam_policies
                    ADD CONSTRAINT iam_policies_effect_check CHECK (effect IN ('permit', 'forbid'))
                    """
                ).run()
            }
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema("iam_policies").delete()
    }
}
