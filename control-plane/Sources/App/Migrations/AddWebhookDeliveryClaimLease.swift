import Fluent
import SQLKit

/// Separates an active drainer's lease from retry scheduling so queue shedding
/// can never turn an in-flight POST into a dropped delivery (STR-264).
struct AddWebhookDeliveryClaimLease: AsyncMigration, UntransactedMigration {
    private struct IndexState: Decodable {
        let isValid: Bool
    }

    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            try await database.schema("webhook_deliveries")
                .field("claimed_until", .datetime)
                .update()
            return
        }
        try await sql.raw(
            """
            ALTER TABLE webhook_deliveries
            ADD COLUMN IF NOT EXISTS claimed_until timestamptz
            """
        ).run()

        // A cancelled CREATE INDEX CONCURRENTLY can leave an invalid relation
        // behind. IF NOT EXISTS would accept that poisoned half-state forever,
        // so remove it before retrying the unlogged migration.
        if try await indexState(
            named: "idx_webhook_deliveries_pending_subscription_due", on: sql
        )?.isValid == false {
            try await sql.raw(
                "DROP INDEX CONCURRENTLY idx_webhook_deliveries_pending_subscription_due"
            ).run()
        }
        try await sql.raw(
            """
            CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_webhook_deliveries_pending_subscription_due
            ON webhook_deliveries (subscription_id, next_attempt_at, created_at, id)
            WHERE status = 'pending'
            """
        ).run()
        if try await indexState(
            named: "idx_webhook_deliveries_pending_subscription_created", on: sql
        )?.isValid == false {
            try await sql.raw(
                "DROP INDEX CONCURRENTLY idx_webhook_deliveries_pending_subscription_created"
            ).run()
        }
        try await sql.raw(
            """
            CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_webhook_deliveries_pending_subscription_created
            ON webhook_deliveries (subscription_id, created_at, id)
            WHERE status = 'pending'
            """
        ).run()
        if try await indexState(
            named: "idx_webhook_deliveries_subscription_updated", on: sql
        )?.isValid == false {
            try await sql.raw(
                "DROP INDEX CONCURRENTLY idx_webhook_deliveries_subscription_updated"
            ).run()
        }
        try await sql.raw(
            """
            CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_webhook_deliveries_subscription_updated
            ON webhook_deliveries (subscription_id, updated_at DESC, created_at DESC)
            """
        ).run()
        if try await indexState(
            named: "idx_webhook_deliveries_terminal_updated", on: sql
        )?.isValid == false {
            try await sql.raw(
                "DROP INDEX CONCURRENTLY idx_webhook_deliveries_terminal_updated"
            ).run()
        }
        try await sql.raw(
            """
            CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_webhook_deliveries_terminal_updated
            ON webhook_deliveries (updated_at)
            WHERE status <> 'pending'
            """
        ).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            try await database.schema("webhook_deliveries")
                .deleteField("claimed_until")
                .update()
            return
        }
        try await sql.raw(
            """
            DROP INDEX CONCURRENTLY IF EXISTS idx_webhook_deliveries_terminal_updated
            """
        ).run()
        try await sql.raw(
            """
            DROP INDEX CONCURRENTLY IF EXISTS idx_webhook_deliveries_subscription_updated
            """
        ).run()
        try await sql.raw(
            """
            DROP INDEX CONCURRENTLY IF EXISTS idx_webhook_deliveries_pending_subscription_created
            """
        ).run()
        try await sql.raw(
            """
            DROP INDEX CONCURRENTLY IF EXISTS idx_webhook_deliveries_pending_subscription_due
            """
        ).run()
        try await sql.raw(
            """
            ALTER TABLE webhook_deliveries
            DROP COLUMN IF EXISTS claimed_until
            """
        ).run()
    }

    private func indexState(named name: String, on sql: any SQLDatabase) async throws -> IndexState? {
        try await sql.raw(
            """
            SELECT index.indisvalid AS "isValid"
            FROM pg_index AS index
            JOIN pg_class AS relation ON relation.oid = index.indexrelid
            JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
            WHERE namespace.nspname = 'public'
              AND relation.relname = \(bind: name)
            """
        ).first(decoding: IndexState.self)
    }
}
