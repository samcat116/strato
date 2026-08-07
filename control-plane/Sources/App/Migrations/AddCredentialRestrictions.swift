import Fluent

/// STR-115: credentials carry a *restriction* in the ordinary IAM action and
/// node vocabulary instead of a bespoke `read`/`write`/`admin` scope enum.
///
/// All three columns are nullable on every table, and the legacy `scopes`
/// column stays. A row with `restriction_actions IS NULL` predates this
/// migration and resolves through `CredentialRestriction(legacyScopes:)`, so
/// existing keys and sessions keep working with no backfill — and no backfill
/// is attempted, because "what did this key's scopes mean" is a question the
/// shim answers correctly at read time and a data migration could only freeze
/// wrong.
struct AddCredentialRestrictions: AsyncMigration {
    private static let tables = ["api_keys", "cli_sessions", "oauth_device_authorizations"]

    func prepare(on database: Database) async throws {
        for table in Self.tables {
            try await database.schema(table)
                .field("restriction_actions", .array(of: .string))
                .field("restriction_node_type", .string)
                .field("restriction_node_id", .uuid)
                .update()
        }
    }

    func revert(on database: Database) async throws {
        for table in Self.tables {
            try await database.schema(table)
                .deleteField("restriction_actions")
                .deleteField("restriction_node_type")
                .deleteField("restriction_node_id")
                .update()
        }
    }
}
