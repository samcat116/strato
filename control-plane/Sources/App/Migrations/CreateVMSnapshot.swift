import Fluent
import SQLKit

/// Creates the `vm_snapshots` table (issue #564): full-VM checkpoints — guest
/// RAM plus device state captured as an internal snapshot of the VM's qcow2
/// disks — with status lifecycle, machine-state size, agent placement, and the
/// QEMU version/architecture a restore must match.
///
/// `vm_id` cascades: a checkpoint lives inside the VM's own disks, so it is
/// gone from the host the moment the VM is deleted and the row would only
/// outlive what it describes. Operation records referencing a cascaded
/// snapshot are untouched (`resource_operations` deliberately has no FK).
struct CreateVMSnapshot: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("vm_snapshots")
            .id()
            .field("name", .string, .required)
            .field("description", .string, .required)
            .field("vm_id", .uuid, .required, .references("vms", "id", onDelete: .cascade))
            .field("project_id", .uuid, .required, .references("projects", "id"))
            .field("environment", .string, .required)
            .field("status", .string, .required)
            .field("size", .int64)
            .field("agent_id", .string)
            .field("qemu_version", .string)
            .field("architecture", .string)
            .field("error_message", .string)
            .field("created_by_id", .uuid, .required, .references("users", "id"))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()

        // Listing a VM's checkpoints, and quota resync summing ready snapshot
        // sizes per project scope, are the two read paths.
        if let sql = database as? SQLDatabase {
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_vm_snapshots_vm_id ON vm_snapshots (vm_id)"
            ).run()
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_vm_snapshots_project_id ON vm_snapshots (project_id)"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_vm_snapshots_vm_id").run()
            try await sql.raw("DROP INDEX IF EXISTS idx_vm_snapshots_project_id").run()
        }
        try await database.schema("vm_snapshots").delete()
    }
}
