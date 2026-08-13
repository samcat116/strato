import Fluent
import SQLKit

/// Repairs preserved databases that predate the VM guest-agent opt-in
/// (STR-246). Fresh databases already receive this column from
/// `CurrentSchema.sql`, so the upgrade must also be safe when it is present.
struct AddGuestAgentEnabledToVM: AsyncMigration {
    var name: String { "App.AddGuestAgentEnabledToVM" }

    func prepare(on database: Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw AddGuestAgentEnabledToVMError.sqlDatabaseRequired
        }
        try await sql.raw(
            "ALTER TABLE vms ADD COLUMN IF NOT EXISTS guest_agent_enabled boolean DEFAULT false NOT NULL"
        ).run()
    }

    /// The column may predate this migration because the fresh-schema baseline
    /// already owns it. A revert cannot distinguish that case from a repaired
    /// preserved database, and leaving the compatible column in place is safe.
    func revert(on database: Database) async throws {}
}

private enum AddGuestAgentEnabledToVMError: Error {
    case sqlDatabaseRequired
}
