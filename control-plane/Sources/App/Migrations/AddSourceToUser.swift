import Fluent
import SQLKit

/// Adds an explicit `source` provenance column to `users` (see UserSource) so
/// admin-created/self-registered accounts (`local`) can be distinguished from
/// externally-provisioned ones (`scim`, `oidc`) without inferring it from a
/// scatter of boolean/FK fields.
///
/// Existing rows are backfilled from the signals that previously implied
/// provenance: `oidc_provider_id` (linked to an IdP) → `oidc`, then
/// `scim_provisioned` → `scim` last so SCIM-managed accounts win even if the
/// user has also authenticated via OIDC. Everything else stays the `local`
/// default.
struct AddSourceToUser: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("users")
            .field("source", .string, .required, .custom("DEFAULT 'local'"))
            .update()

        guard let sql = database as? SQLDatabase else { return }

        try await sql.raw(
            """
            UPDATE users SET source = 'oidc' WHERE oidc_provider_id IS NOT NULL
            """
        ).run()

        try await sql.raw(
            """
            UPDATE users SET source = 'scim' WHERE scim_provisioned = \(bind: true)
            """
        ).run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("users")
            .deleteField("source")
            .update()
    }
}
