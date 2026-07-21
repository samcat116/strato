import Fluent
import Foundation
import SQLKit
import Vapor

/// Adds `vms.max_memory` (issue #568): the upper bound a VM's memory can be
/// hot-added to without a restart, the memory counterpart of the existing
/// `max_cpu`. Backfilled to each VM's current `memory` so existing VMs keep
/// exactly today's sizing — no headroom, and therefore no virtio-mem device
/// when they next boot.
struct AddMaxMemoryToVM: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("vms")
            .field("max_memory", .int64, .required, .sql(.default(0)))
            .update()

        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "AddMaxMemoryToVM requires an SQL database")
        }
        // Column-to-column assignment, which Fluent's query builder cannot
        // express. Raw SQL pins this to today's columns, matching the
        // frozen-model convention the other backfills follow.
        try await sql.raw("UPDATE vms SET max_memory = memory WHERE max_memory = 0").run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("vms")
            .deleteField("max_memory")
            .update()
    }
}
