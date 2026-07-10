import Fluent

/// Shared Signals Framework receiver streams (issue #38): one row per
/// transmitter stream an organization consumes security events from.
struct CreateSSFStream: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("ssf_streams")
            .id()
            .field(
                "organization_id", .uuid, .required,
                .references("organizations", "id", onDelete: .cascade)
            )
            .field("name", .string, .required)
            .field("description", .string)
            .field("transmitter_url", .string, .required)
            .field("auth_token", .string)
            .field("expected_issuer", .string)
            .field("expected_audience", .string, .required, .custom("DEFAULT '[]'"))
            .field("delivery_method", .string, .required)
            .field("events_requested", .string, .required, .custom("DEFAULT '[]'"))
            .field("remote_stream_id", .string)
            .field("poll_endpoint", .string)
            .field("push_token_hash", .string)
            .field("push_token_prefix", .string)
            .field("enabled", .bool, .required, .custom("DEFAULT TRUE"))
            .field("verified_at", .datetime)
            .field("last_event_at", .datetime)
            .field("last_error", .string)
            .field(
                "created_by_id", .uuid, .required,
                .references("users", "id")
            )
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("ssf_streams").delete()
    }
}
