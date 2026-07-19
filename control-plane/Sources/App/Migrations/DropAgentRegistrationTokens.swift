import Fluent
import SQLKit

/// Retires token-based agent enrollment: SPIRE-issued SVIDs are now the only
/// way an agent authenticates, so the table holds nothing but dead bearer
/// secrets. The migrations that built it are deliberately left in place —
/// reverting this one has to land on the schema they produced.
///
/// Not revertible to its former *contents*: the tokens themselves are gone with
/// the table, and no live agent depends on them, since the socket no longer has
/// a token auth path to present them to.
struct DropAgentRegistrationTokens: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("agent_registration_tokens").delete()
    }

    func revert(on database: Database) async throws {
        // Recreate the shape the prior migrations left behind (create, plus the
        // site_id, org scope, and spire_provisioned columns added later), so a
        // revert of this migration alone leaves a consistent schema.
        try await database.schema("agent_registration_tokens")
            .id()
            .field("token", .string, .required)
            .field("agent_name", .string, .required)
            .field("is_used", .bool, .required)
            .field("spire_provisioned", .bool, .required, .sql(.default(false)))
            .field("site_id", .uuid, .references("sites", "id", onDelete: .setNull))
            .field("organization_id", .uuid, .references("organizations", "id", onDelete: .restrict))
            .field(
                "organizational_unit_id", .uuid,
                .references("organizational_units", "id", onDelete: .restrict)
            )
            .field("expires_at", .datetime, .required)
            .field("created_at", .datetime)
            .field("used_at", .datetime)
            .unique(on: "token")
            .create()
    }
}
