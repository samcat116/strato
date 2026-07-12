import Fluent
import Foundation
import SQLKit

/// Snapshot of the `storage_pools` columns as created here. Seeding through
/// the live `StoragePool` model would break once it grows fields whose
/// columns postdate this migration.
private final class SeedStoragePool: Model, @unchecked Sendable {
    static let schema = "storage_pools"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "name")
    var name: String

    @Field(key: "mode")
    var mode: String

    @Field(key: "replication_factor")
    var replicationFactor: Int

    @Field(key: "member_agent_ids")
    var memberAgentIds: [String]

    @Field(key: "backing")
    var backing: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}
}

/// Storage phase 1 (issue #349): the pool abstraction. Creates `storage_pools`
/// and seeds the well-known default pool that expresses today's behavior —
/// `local` mode (one replica), `filesystem` backing, no member restriction —
/// so both fresh installs and existing databases always have a pool for new
/// volumes and for `BackfillVolumePools` to adopt existing ones into.
struct CreateStoragePool: AsyncMigration {
    func prepare(on database: Database) async throws {
        // `member_agent_ids` is `[String]` on the model; Fluent binds Swift
        // arrays as native SQL arrays on Postgres, so the column type must be
        // an array (see ReplaceAgentHypervisorTypeWithHypervisors).
        try await database.schema(StoragePool.schema)
            .id()
            .field("name", .string, .required)
            .field("mode", .string, .required)
            .field("replication_factor", .int, .required)
            .field("member_agent_ids", .array(of: .string), .required)
            .field("backing", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "name")
            .create()

        let defaultPool = SeedStoragePool()
        defaultPool.name = StoragePool.defaultPoolName
        defaultPool.mode = StoragePoolMode.local.rawValue
        defaultPool.replicationFactor = 1
        defaultPool.memberAgentIds = []
        defaultPool.backing = StoragePoolBacking.filesystem.rawValue
        try await defaultPool.create(on: database)
    }

    func revert(on database: Database) async throws {
        try await database.schema(StoragePool.schema).delete()
    }
}
