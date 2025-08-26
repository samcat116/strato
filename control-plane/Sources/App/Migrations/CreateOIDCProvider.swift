import Fluent

struct CreateOIDCProvider: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("oidc_providers")
            .id()
            .field("organization_id", .uuid, .required, .references("organizations", "id", onDelete: .cascade))
            .field("name", .string, .required)
            .field("client_id", .string, .required)
            .field("client_secret", .string, .required)
            .field("discovery_url", .string)
            .field("authorization_endpoint", .string)
            .field("token_endpoint", .string)
            .field("userinfo_endpoint", .string)
            .field("jwks_uri", .string)
            .field("scopes", .string, .required) // JSON encoded array of scopes
            .field("enabled", .bool, .required, .custom("DEFAULT true"))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("oidc_providers").delete()
    }
}