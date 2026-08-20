import Fluent
import SQLKit

struct CreateVMCommandExecutions: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("vm_command_executions")
            .id()
            .field("vm_id", .uuid, .required)
            .field("actor_type", .string, .required)
            .field("actor_id", .uuid, .required)
            .field("agent_key", .string, .required)
            .field("status", .string, .required)
            .field("error", .string)
            .field("deadline", .datetime, .required)
            .field("created_at", .datetime)
            .field("completed_at", .datetime)
            .create()

        try await database.schema("vm_command_payloads")
            .field(
                "execution_id", .uuid, .identifier(auto: false),
                .references("vm_command_executions", "id", onDelete: .cascade)
            )
            .field("command", .array(of: .string), .required)
            .field("stdout", .data)
            .field("stderr", .data)
            .field("exit_code", .int)
            .field("truncated", .bool)
            .create()

        if let sql = database as? any SQLDatabase {
            try await sql.raw(
                "ALTER TABLE vm_command_executions ADD CONSTRAINT ck_vm_command_executions_actor_type CHECK (actor_type = 'user')"
            ).run()
            try await sql.raw(
                "ALTER TABLE vm_command_executions ADD CONSTRAINT ck_vm_command_executions_status CHECK (status IN ('pending', 'succeeded', 'failed'))"
            ).run()
            try await sql.raw(
                "CREATE INDEX idx_vm_command_executions_vm_created ON vm_command_executions (vm_id, created_at DESC)"
            ).run()
            try await sql.raw(
                "CREATE INDEX idx_vm_command_executions_pending_deadline ON vm_command_executions (deadline) WHERE status = 'pending'"
            ).run()
            try await sql.raw(
                "ALTER TABLE vm_command_payloads ADD CONSTRAINT ck_vm_command_payloads_command CHECK (cardinality(command) > 0)"
            ).run()
            try await sql.raw(
                """
                ALTER TABLE vm_command_payloads
                ADD CONSTRAINT ck_vm_command_payloads_result
                CHECK (
                    (stdout IS NULL AND stderr IS NULL AND exit_code IS NULL AND truncated IS NULL)
                    OR
                    (stdout IS NOT NULL AND stderr IS NOT NULL AND exit_code IS NOT NULL AND truncated IS NOT NULL
                     AND octet_length(stdout) + octet_length(stderr) <= 1048576)
                )
                """
            ).run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema("vm_command_payloads").delete()
        try await database.schema("vm_command_executions").delete()
    }
}
