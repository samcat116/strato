import Fluent
import SQLKit

struct CreateVMFleetRuns: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(VMFleetRun.schema).id()
            .field("actor_id", .uuid, .required)
            .field("api_key_id", .uuid)
            .field("command", .array(of: .string), .required)
            .field("entries", .json, .required)
            .field("confirmed", .bool, .required)
            .field("deadline", .datetime, .required)
            .field("created_at", .datetime).create()
        if let sql = database as? any SQLDatabase {
            try await sql.raw(
                "CREATE INDEX idx_vm_fleet_runs_queue ON vm_fleet_runs (created_at) WHERE confirmed AND (entries -> 'values') @> '[{\"state\":\"queued\"}]'::jsonb"
            ).run()
            try await sql.raw("CREATE INDEX idx_vms_fleet_tags ON vms USING gin (tags jsonb_path_ops)").run()
        }
    }
    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_vms_fleet_tags").run()
        }
        try await database.schema(VMFleetRun.schema).delete()
    }
}
