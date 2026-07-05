import Fluent
import FluentPostgresDriver
import FluentSQLiteDriver
import SQLKit

/// Adds indexes on the hottest `vms` columns (issue #182).
///
/// `status`, `hypervisor_id`, and `project_id` are full-table-scanned by the
/// busiest control-plane background queries: `AgentService.reconcileVMs` (every
/// heartbeat), `sweepStuckTransitionalVMs` (every 30s), `restoreVMToAgentMappings`,
/// and quota calculations. Neither the plain `.field(...)` columns nor the
/// `.references(...)` foreign key created an index (PostgreSQL does not index the
/// referencing column of a foreign key automatically), so these scans were O(n)
/// in the VM count.
struct AddVMHotColumnIndexes: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }

        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_vms_status ON vms (status)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_vms_hypervisor_id ON vms (hypervisor_id)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_vms_project_id ON vms (project_id)").run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }

        try await sql.raw("DROP INDEX IF EXISTS idx_vms_status").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_vms_hypervisor_id").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_vms_project_id").run()
    }
}
