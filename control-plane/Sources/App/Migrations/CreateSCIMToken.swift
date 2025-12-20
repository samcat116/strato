import Fluent

struct CreateSCIMToken: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("scim_tokens")
            .id()
            .field("organization_id", .uuid, .required, .references("organizations", "id", onDelete: .cascade))
            .field("name", .string, .required)
            .field("token_hash", .string, .required)
            .field("token_prefix", .string, .required)
            .field("is_active", .bool, .required, .custom("DEFAULT TRUE"))
            .field("expires_at", .datetime)
            .field("last_used_at", .datetime)
            .field("last_used_ip", .string)
            .field("created_by_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "token_hash")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("scim_tokens").delete()
    }
}
