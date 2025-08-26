import Fluent

struct AddOIDCFieldsToUser: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("users")
            .field("oidc_provider_id", .uuid, .references("oidc_providers", "id", onDelete: .setNull))
            .field("oidc_subject", .string) // The 'sub' claim from OIDC provider
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("users")
            .deleteField("oidc_provider_id")
            .deleteField("oidc_subject")
            .update()
    }
}