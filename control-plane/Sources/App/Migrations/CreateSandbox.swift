import Fluent
import SQLKit

/// Creates the `sandboxes` table (issue #413): OCI-image Firecracker microVMs
/// as a first-class workload type, parallel to VMs. Carries the same
/// desired/observed state split and generation pair as `vms`.
///
/// No companion operations table: sandbox mutations reuse the generalized
/// `resource_operations` machinery (issue #412), whose partial unique index on
/// pending `(resource_kind, resource_id)` already guards sandboxes.
struct CreateSandbox: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("sandboxes")
            .id()
            .field("name", .string, .required)
            .field("project_id", .uuid, .required, .references("projects", "id"))
            .field("environment", .string, .required)
            .field("image", .string, .required)
            .field("image_digest", .string)
            .field("vcpus", .int, .required)
            .field("memory", .int64, .required)
            // Overrides over the OCI image config. Arrays bind as native SQL
            // arrays (text[] on Postgres, JSON text on SQLite); the env map is
            // a scalar JSON document.
            .field("entrypoint", .array(of: .string))
            .field("cmd", .array(of: .string))
            .field("env", .json, .required)
            .field("working_dir", .string)
            .field("ttl_seconds", .int)
            .field("hypervisor_id", .string)
            .field("status", .string, .required)
            .field("status_changed_at", .datetime)
            .field("exit_code", .int)
            .field("desired_status", .string, .required)
            .field("generation", .int64, .required)
            .field("observed_generation", .int64, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()

        // Sync assembly and observed-report application both read an agent's
        // full sandbox set by placement.
        if let sql = database as? SQLDatabase {
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_sandboxes_hypervisor_id ON sandboxes (hypervisor_id)"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_sandboxes_hypervisor_id").run()
        }
        try await database.schema("sandboxes").delete()
    }
}
