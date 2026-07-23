import Fluent

/// User-managed webhook subscriptions (issue #559): one row per endpoint an
/// organization has subscribed to typed platform events.
struct CreateWebhookSubscription: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("webhook_subscriptions")
            .id()
            .field(
                "organization_id", .uuid, .required,
                .references("organizations", "id", onDelete: .cascade)
            )
            .field(
                "project_id", .uuid,
                .references("projects", "id", onDelete: .cascade)
            )
            .field("name", .string, .required)
            .field("url", .string, .required)
            .field("event_types", .string, .required, .custom("DEFAULT '[]'"))
            .field("signing_secret", .string, .required)
            .field("is_active", .bool, .required, .custom("DEFAULT TRUE"))
            .field("disabled_reason", .string)
            .field("failing_since", .datetime)
            .field(
                "created_by_id", .uuid, .required,
                .references("users", "id")
            )
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("webhook_subscriptions").delete()
    }
}
