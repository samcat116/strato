import Fluent

/// Adds the per-provider claim→role map (issue #611): a JSON array of
/// `OIDCRoleMapping` values, so an OIDC login can bind a scoped custom role on
/// the org node, not just the seeded admin/member vocabulary.
struct AddRoleMappingsToOIDCProvider: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("oidc_providers")
            .field("role_mappings", .string, .required, .custom("DEFAULT '[]'"))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("oidc_providers")
            .deleteField("role_mappings")
            .update()
    }
}
