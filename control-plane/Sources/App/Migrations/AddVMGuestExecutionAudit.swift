import Fluent
import SQLKit

/// Durable request attribution for asynchronous VM command completion facts,
/// plus the composite access path used by newest-first VM audit history.
struct AddVMGuestExecutionAudit: AsyncMigration {
    static let historicalTimeoutReason = "Command execution timed out"

    func prepare(on database: any Database) async throws {
        try await database.schema(VMCommandExecution.schema)
            .field("actor_username", .string)
            .field("api_key_id", .uuid)
            .field("organization_id", .uuid)
            .field("source_ip", .string)
            .field("admin_bypass", .bool, .required, .sql(.default(false)))
            .field("timed_out_by_sweeper", .bool, .required, .sql(.default(false)))
            .update()

        guard let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" else {
            throw AddVMGuestExecutionAuditError.postgresRequired
        }
        try await Self.backfillLegacyTimeouts(on: database)
        try await sql.raw(
            "CREATE INDEX idx_audit_events_resource_created ON audit_events (resource_type, resource_id, created_at DESC)"
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" else {
            throw AddVMGuestExecutionAuditError.postgresRequired
        }
        try await sql.raw("DROP INDEX IF EXISTS idx_audit_events_resource_created").run()
        try await database.schema(VMCommandExecution.schema)
            .deleteField("timed_out_by_sweeper")
            .deleteField("admin_bypass")
            .deleteField("source_ip")
            .deleteField("organization_id")
            .deleteField("api_key_id")
            .deleteField("actor_username")
            .update()
    }

    /// Existing timeout rows predate the typed provenance marker. Backfill only
    /// the exact sentinel emitted by the old sweeper; all future terminal
    /// transitions rely exclusively on the marker.
    static func backfillLegacyTimeouts(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" else {
            throw AddVMGuestExecutionAuditError.postgresRequired
        }
        try await sql.raw(
            """
            UPDATE vm_command_executions
            SET timed_out_by_sweeper = TRUE
            WHERE status = 'failed'
              AND error = \(bind: historicalTimeoutReason)
              AND timed_out_by_sweeper = FALSE
            """
        ).run()
    }
}

private enum AddVMGuestExecutionAuditError: Error {
    case postgresRequired
}
