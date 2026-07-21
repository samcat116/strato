import Fluent

struct CreateDeviceAuthorization: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("oauth_device_authorizations")
            .id()
            .field("device_code_hash", .string, .required)
            .field("user_code", .string, .required)
            .field("client_name", .string, .required)
            .field("scopes", .array(of: .string), .required)
            .field("status", .string, .required)
            .field("user_id", .uuid, .references("users", "id", onDelete: .cascade))
            .field("request_ip", .string)
            .field("expires_at", .datetime, .required)
            .field("last_polled_at", .datetime)
            .field("poll_interval", .int, .required)
            .field("created_at", .datetime)
            .unique(on: "device_code_hash")
            .unique(on: "user_code")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("oauth_device_authorizations").delete()
    }
}
