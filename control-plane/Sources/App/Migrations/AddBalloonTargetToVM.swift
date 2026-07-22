import Fluent
import Foundation

/// Adds the balloon-target columns to `vms` (issue #567 phase 2):
/// `balloon_target` (the operator's requested memory ceiling for the running
/// guest) and `guest_memory_balloon_actual_bytes` (`query-balloon`'s `actual`,
/// what the balloon has actually reached). Both nullable; a null target means
/// no ballooning, which is every VM's state before this migration.
struct AddBalloonTargetToVM: AsyncMigration {
    func prepare(on database: Database) async throws {
        // Single action per update() call, matching the convention the rest of
        // the `vms` column migrations follow.
        try await database.schema("vms")
            .field("balloon_target", .int64)
            .update()
        try await database.schema("vms")
            .field("guest_memory_balloon_actual_bytes", .int64)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("vms")
            .deleteField("balloon_target")
            .update()
        try await database.schema("vms")
            .deleteField("guest_memory_balloon_actual_bytes")
            .update()
    }
}
