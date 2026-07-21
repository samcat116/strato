import Fluent
import Foundation

/// Adds the observed guest memory columns to `vms` (issue #567):
/// `guest_memory_total_bytes` / `guest_memory_available_bytes` (the
/// virtio-balloon device's guest statistics) and `guest_memory_stats_at`
/// (when the agent last reported them). All nullable and informational —
/// populated only for guests whose virtio_balloon driver reports.
struct AddGuestMemoryStatsToVM: AsyncMigration {
    func prepare(on database: Database) async throws {
        // Single action per update() call: SQLite cannot combine multiple
        // ALTER TABLE actions in one statement.
        try await database.schema("vms")
            .field("guest_memory_total_bytes", .int64)
            .update()
        try await database.schema("vms")
            .field("guest_memory_available_bytes", .int64)
            .update()
        try await database.schema("vms")
            .field("guest_memory_stats_at", .datetime)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("vms")
            .deleteField("guest_memory_total_bytes")
            .update()
        try await database.schema("vms")
            .deleteField("guest_memory_available_bytes")
            .update()
        try await database.schema("vms")
            .deleteField("guest_memory_stats_at")
            .update()
    }
}
