import Fluent
import SQLKit

/// The webhook transactional-outbox table (issue #559): one row per
/// (event × subscription), written in the same transaction as the state
/// change that produced the event and drained by the delivery sweep.
struct CreateWebhookDelivery: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("webhook_deliveries")
            .id()
            .field(
                "subscription_id", .uuid, .required,
                .references("webhook_subscriptions", "id", onDelete: .cascade)
            )
            .field("event_id", .uuid, .required)
            .field("event_type", .string, .required)
            .field("payload", .string, .required)
            .field("status", .string, .required, .custom("DEFAULT 'pending'"))
            .field("attempts", .int, .required, .custom("DEFAULT 0"))
            .field("next_attempt_at", .datetime, .required)
            .field("last_attempt_at", .datetime)
            .field("response_status", .int)
            .field("last_error", .string)
            .field("delivered_at", .datetime)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()

        // The sweep's hot query is `status = 'pending' AND next_attempt_at <= now`;
        // the history endpoint lists by subscription. Both need an index or the
        // outbox scans O(all deliveries ever) once history accumulates.
        if let sql = database as? SQLDatabase {
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_due ON webhook_deliveries (status, next_attempt_at)"
            ).run()
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_subscription ON webhook_deliveries (subscription_id, created_at)"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_webhook_deliveries_due").run()
            try await sql.raw("DROP INDEX IF EXISTS idx_webhook_deliveries_subscription").run()
        }
        try await database.schema("webhook_deliveries").delete()
    }
}
