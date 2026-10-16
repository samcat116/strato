import Fluent
import Vapor
import SQLKit

struct CreateGuestExecSessionLimits: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { throw Abort(.internalServerError) }
        try await sql.raw(
            """
            CREATE TABLE vm_exec_sessions (
                id uuid PRIMARY KEY, vm_id uuid NOT NULL, user_id uuid NOT NULL,
                username text, attached_at timestamptz, last_activity_at timestamptz NOT NULL,
                expires_at timestamptz NOT NULL, termination_requested boolean NOT NULL DEFAULT false
            )
            """
        ).run()
        try await sql.raw("CREATE INDEX idx_vm_exec_sessions_vm_expiry ON vm_exec_sessions (vm_id, expires_at)").run()
        try await sql.raw("CREATE INDEX idx_vm_exec_sessions_expiry ON vm_exec_sessions (expires_at)").run()
        try await sql.raw(
            "CREATE INDEX idx_vm_commands_pending_vm ON vm_command_executions (vm_id) WHERE status = 'pending'"
        ).run()
        try await sql.raw(
            """
            CREATE TABLE vm_run_rate_limits (
                project_id uuid PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE,
                accepted_at timestamptz[] NOT NULL DEFAULT '{}'
            )
            """
        ).run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("vm_run_rate_limits").delete()
        try await database.schema("vm_exec_sessions").delete()
        guard let sql = database as? any SQLDatabase else { throw Abort(.internalServerError) }
        try await sql.raw("DROP INDEX idx_vm_commands_pending_vm").run()
    }
}
