import Fluent

/// STR-115: credentials carry a *restriction* in the ordinary IAM action and
/// node vocabulary instead of a bespoke `read`/`write`/`admin` scope enum.
///
/// This historical migration deliberately introduced nullable columns beside
/// the old storage. STR-227's `RemoveLegacyCredentialScopes` performs the
/// explicit backfill, makes `restriction_actions` required, and removes that
/// transitional representation.
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
