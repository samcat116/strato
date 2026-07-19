import Fluent
import SQLKit

/// Generalizes the async-operation table beyond VMs (issue #412):
/// `vm_operations` becomes `resource_operations`, `vm_id` becomes
/// `resource_id`, and a `resource_kind` discriminator says which table the id
/// points into. Every existing row is a VM operation, so the new column
/// backfills to `virtual_machine` via its default.
///
/// The column keeps its deliberate no-FK property: a delete operation must
/// outlive the row it removes. Each step is its own statement because SQLite
/// cannot combine multiple ALTER TABLE actions.
struct GeneralizeVMOperations: AsyncMigration {
    func prepare(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("ALTER TABLE vm_operations RENAME TO resource_operations").run()
            try await sql.raw("ALTER TABLE resource_operations RENAME COLUMN vm_id TO resource_id").run()
        }

        try await database.schema("resource_operations")
            .field("resource_kind", .string, .required, .sql(.default("virtual_machine")))
            .update()

        // Rebuild the indexes under the generalized names and shapes. The
        // renames above already retargeted the old indexes (both engines
        // follow table/column renames), but the pending guard must now be
        // per (resource_kind, resource_id) — one pending operation per
        // resource, not per VM — and per-resource history reads filter on the
        // kind + id pair.
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_vm_operations_vm_id").run()
            try await sql.raw("DROP INDEX IF EXISTS idx_vm_operations_status").run()
            try await sql.raw("DROP INDEX IF EXISTS idx_vm_operations_pending_vm").run()
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_resource_operations_resource "
                    + "ON resource_operations (resource_kind, resource_id)"
            ).run()
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_resource_operations_status ON resource_operations (status)"
            ).run()
            // At most one pending operation per resource, enforced by the
            // database so two concurrent mutations cannot both slip past the
            // controller's pending-check (the loser's insert fails and
            // surfaces as 409). Partial indexes work on both SQLite and
            // Postgres.
            try await sql.raw(
                "CREATE UNIQUE INDEX IF NOT EXISTS idx_resource_operations_pending_resource "
                    + "ON resource_operations (resource_kind, resource_id) WHERE status = 'pending'"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_resource_operations_resource").run()
            try await sql.raw("DROP INDEX IF EXISTS idx_resource_operations_status").run()
            try await sql.raw("DROP INDEX IF EXISTS idx_resource_operations_pending_resource").run()
        }

        try await database.schema("resource_operations")
            .deleteField("resource_kind")
            .update()

        if let sql = database as? SQLDatabase {
            try await sql.raw("ALTER TABLE resource_operations RENAME COLUMN resource_id TO vm_id").run()
            try await sql.raw("ALTER TABLE resource_operations RENAME TO vm_operations").run()
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_vm_operations_vm_id ON vm_operations (vm_id)"
            ).run()
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_vm_operations_status ON vm_operations (status)"
            ).run()
            try await sql.raw(
                "CREATE UNIQUE INDEX IF NOT EXISTS idx_vm_operations_pending_vm "
                    + "ON vm_operations (vm_id) WHERE status = 'pending'"
            ).run()
        }
    }
}
