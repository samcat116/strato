import Fluent
import Foundation

/// Adds the observed guest-agent (qga) columns to `vms` (issue #563):
/// `qga_available` (was a responsive guest agent last seen?) and
/// `observed_hostname` (the guest OS's own hostname). Both nullable and
/// informational — populated only once the agent's guest-info poll reports them.
struct AddGuestInfoToVM: AsyncMigration {
    func prepare(on database: Database) async throws {
        // Single action per update() call: SQLite cannot combine multiple
        // ALTER TABLE actions in one statement.
        try await database.schema("vms")
            .field("qga_available", .bool)
            .update()
        try await database.schema("vms")
            .field("observed_hostname", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("vms")
            .deleteField("qga_available")
            .update()
        try await database.schema("vms")
            .deleteField("observed_hostname")
            .update()
    }
}
