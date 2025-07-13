import Fluent

struct CreateUser: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("users")
            .id()
            .field("username", .string, .required)
            .field("email", .string, .required)
            .field("display_name", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "username")
            .unique(on: "email")
            .create()

        try await database.schema("user_credentials")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("credential_id", .data, .required)
            .field("public_key", .data, .required)
            .field("sign_count", .int32, .required)
            // Store transports as JSON string for compatibility
            .field("transports", .string, .required)
            .field("backup_eligible", .bool, .required)
            .field("backup_state", .bool, .required)
            .field("device_type", .string, .required)
            .field("name", .string)
            .field("created_at", .datetime)
            .field("last_used_at", .datetime)
            .unique(on: "credential_id")
            .create()

        try await database.schema("authentication_challenges")
            .id()
            .field("challenge", .string, .required)
            .field("user_id", .uuid)
            .field("operation", .string, .required)
            .field("created_at", .datetime)
            .field("expires_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("authentication_challenges").delete()
        try await database.schema("user_credentials").delete()
        try await database.schema("users").delete()
    }
}