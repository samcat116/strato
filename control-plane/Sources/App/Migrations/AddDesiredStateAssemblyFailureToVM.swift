import Fluent
import SQLKit

/// Persists a VM-local desired-state projection failure separately from the
/// agent-owned convergence fields (STR-287). Fresh databases already receive
/// these columns from `CurrentSchema.sql`; `IF NOT EXISTS` repairs preserved
/// databases and remains safe on both paths.
struct AddDesiredStateAssemblyFailureToVM: AsyncMigration {
    var name: String { "App.AddDesiredStateAssemblyFailureToVM" }

    func prepare(on database: Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw AddDesiredStateAssemblyFailureToVMError.sqlDatabaseRequired
        }
        try await sql.raw(
            """
            ALTER TABLE vms
                ADD COLUMN IF NOT EXISTS desired_state_assembly_error text,
                ADD COLUMN IF NOT EXISTS desired_state_assembly_error_generation bigint,
                ADD COLUMN IF NOT EXISTS desired_state_assembly_error_at timestamp with time zone
            """
        ).run()
    }

    /// The columns may belong to the fresh-schema baseline. A revert cannot
    /// distinguish that case from an upgraded database, so it leaves the
    /// compatible nullable columns in place.
    func revert(on database: Database) async throws {}
}

private enum AddDesiredStateAssemblyFailureToVMError: Error {
    case sqlDatabaseRequired
}
