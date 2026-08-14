import Fluent
import SQLKit

struct CreateVMCommandExecutions: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(VMCommandExecution.schema)
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

        try await database.schema(VMCommandOutput.schema)
            .field(
                "execution_id", .uuid, .identifier(auto: false),
                .references(VMCommandExecution.schema, "id", onDelete: .cascade)
            )
            .field("stdout", .data, .required)
            .field("stderr", .data, .required)
            .field("exit_code", .int, .required)
            .field("truncated", .bool, .required)
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
                "ALTER TABLE vm_command_outputs ADD CONSTRAINT ck_vm_command_outputs_combined_size CHECK (octet_length(stdout) + octet_length(stderr) <= 1048576)"
            ).run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(VMCommandOutput.schema).delete()
        try await database.schema(VMCommandExecution.schema).delete()
    }
}
