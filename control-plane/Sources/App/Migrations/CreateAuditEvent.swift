import Fluent
import SQLKit

struct CreateAuditEvent: AsyncMigration {
    func prepare(on database: Database) async throws {
        // `user_id`, `api_key_id`, and `organization_id` have no foreign keys on
        // purpose: the audit trail must outlive the rows it describes.
        try await database.schema("audit_events")
            .id()
            .field("event_type", .string, .required)
            .field("user_id", .uuid)
            .field("username", .string)
            .field("api_key_id", .uuid)
            .field("organization_id", .uuid)
            .field("method", .string)
            .field("path", .string)
            .field("status", .int)
            .field("resource_type", .string)
            .field("resource_id", .string)
            .field("action", .string)
            .field("source_ip", .string)
            .field("admin_bypass", .bool, .required, .sql(.default(false)))
            .field("metadata", .string)
            .field("created_at", .datetime)
            .create()

        // The query API lists newest-first, scoped to an organization or
        // filtered by user/event type.
        if let sql = database as? SQLDatabase {
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_audit_events_org_created "
                    + "ON audit_events (organization_id, created_at)"
            ).run()
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_audit_events_created ON audit_events (created_at)"
            ).run()
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_audit_events_user_id ON audit_events (user_id)"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_audit_events_org_created").run()
            try await sql.raw("DROP INDEX IF EXISTS idx_audit_events_created").run()
            try await sql.raw("DROP INDEX IF EXISTS idx_audit_events_user_id").run()
        }
        try await database.schema("audit_events").delete()
    }
}
