import Fluent
import SQLKit

struct CreateVMOperation: AsyncMigration {
    func prepare(on database: Database) async throws {
        // `vm_id` has no foreign key on purpose: delete operations must outlive
        // the VM row they remove so clients can poll them to a terminal state.
        try await database.schema("vm_operations")
            .id()
            .field("vm_id", .uuid, .required)
            .field("user_id", .uuid, .required)
            .field("kind", .string, .required)
            .field("status", .string, .required)
            .field("error", .string)
            .field("created_at", .datetime)
            .field("completed_at", .datetime)
            .create()

        // Per-VM history reads and the pending-conflict check filter on vm_id;
        // the stuck-operation sweep filters on status.
        if let sql = database as? SQLDatabase {
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_vm_operations_vm_id ON vm_operations (vm_id)"
            ).run()
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_vm_operations_status ON vm_operations (status)"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_vm_operations_vm_id").run()
            try await sql.raw("DROP INDEX IF EXISTS idx_vm_operations_status").run()
        }
        try await database.schema("vm_operations").delete()
    }
}
