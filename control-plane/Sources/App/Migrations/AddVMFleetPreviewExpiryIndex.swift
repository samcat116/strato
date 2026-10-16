import Fluent
import SQLKit
import Vapor

/// Keep expiry cleanup proportional to a bounded batch rather than accumulated
/// confirmed history. This forward migration leaves the frozen baseline fixed.
struct AddVMFleetPreviewExpiryIndex: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { throw Abort(.internalServerError) }
        try await sql.raw(
            """
            CREATE INDEX IF NOT EXISTS idx_vm_fleet_runs_preview_deadline
            ON vm_fleet_runs (deadline, id) WHERE NOT confirmed
            """
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { throw Abort(.internalServerError) }
        try await sql.raw("DROP INDEX IF EXISTS idx_vm_fleet_runs_preview_deadline").run()
    }
}
