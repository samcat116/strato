import Fluent

struct CreateCLISession: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("cli_sessions")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("client_name", .string, .required)
            .field("scopes", .array(of: .string), .required)
            .field("access_token_hash", .string, .required)
            .field("access_token_prefix", .string, .required)
            .field("access_token_expires_at", .datetime, .required)
            .field("refresh_token_hash", .string, .required)
            .field("previous_refresh_token_hash", .string)
            .field("refresh_token_expires_at", .datetime, .required)
            .field("revoked_at", .datetime)
            .field("last_used_at", .datetime)
            .field("last_used_ip", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "access_token_hash")
            .unique(on: "refresh_token_hash")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("cli_sessions").delete()
    }
}
