import Fluent

struct AddClaimMappingToOIDCProvider: AsyncMigration {
    func prepare(on database: Database) async throws {
        // SQLite doesn't support multiple ADD clauses in a single ALTER TABLE statement
        try await database.schema("oidc_providers")
            .field("groups_claim", .string)
            .update()

        try await database.schema("oidc_providers")
            .field("group_mappings", .string, .required, .custom("DEFAULT '[]'"))
            .update()

        try await database.schema("oidc_providers")
            .field("admin_claim_values", .string, .required, .custom("DEFAULT '[]'"))
            .update()

        try await database.schema("oidc_providers")
            .field("default_role", .string, .required, .custom("DEFAULT 'member'"))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("oidc_providers")
            .deleteField("groups_claim")
            .update()

        try await database.schema("oidc_providers")
            .deleteField("group_mappings")
            .update()

        try await database.schema("oidc_providers")
            .deleteField("admin_claim_values")
            .update()

        try await database.schema("oidc_providers")
            .deleteField("default_role")
            .update()
    }
}
