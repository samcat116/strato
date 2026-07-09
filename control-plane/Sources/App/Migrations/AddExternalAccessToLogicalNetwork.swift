import Fluent
import SQLKit

/// Adds L3/uplink desired-state to logical networks (issue #342): whether a
/// network gets outbound SNAT to the host uplink (`external_access`), and a
/// monotonic `generation` agents use to reject replayed/reordered network syncs.
///
/// `external_access` defaults to true so the seeded "default" network (and any
/// existing operator-created networks) gain outbound internet once agents
/// realize routers; `generation` defaults to 1 as the first realized version.
struct AddExternalAccessToLogicalNetwork: AsyncMigration {
    func prepare(on database: Database) async throws {
        // One action per update() call: SQLite cannot combine multiple ALTER
        // TABLE actions in a single statement.
        try await database.schema("logical_networks")
            .field("external_access", .bool, .required, .sql(.default(true)))
            .update()

        try await database.schema("logical_networks")
            .field("generation", .int, .required, .sql(.default(1)))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("logical_networks").deleteField("generation").update()
        try await database.schema("logical_networks").deleteField("external_access").update()
    }
}
