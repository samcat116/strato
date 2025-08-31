import Fluent

struct AddOIDCFieldsToUser: AsyncMigration {
    func prepare(on database: Database) async throws {
        // SQLite doesn't support multiple ADD clauses in a single ALTER TABLE statement
        // So we need to do them separately
        try await database.schema("users")
            .field("oidc_provider_id", .uuid, .references("oidc_providers", "id", onDelete: .setNull))
            .update()
        
        try await database.schema("users")
            .field("oidc_subject", .string) // The 'sub' claim from OIDC provider
            .update()
    }

    func revert(on database: Database) async throws {
        // SQLite doesn't support multiple DROP clauses in a single ALTER TABLE statement
        // So we need to do them separately
        try await database.schema("users")
            .deleteField("oidc_provider_id")
            .update()
        
        try await database.schema("users")
            .deleteField("oidc_subject")
            .update()
    }
}