import Fluent

/// Storage phase 1 (issue #349): a volume belongs to a pool (`pool_id`) and,
/// while attached, records the agent its attachment currently runs on
/// (`attached_agent_id`) — the replacement for `hypervisor_id`'s "single
/// owner" role. The legacy `hypervisor_id`/`storage_path` columns stay and are
/// dual-written this phase; they are dropped once nothing reads them.
struct AddStoragePoolToVolume: AsyncMigration {
    func prepare(on database: Database) async throws {
        // Nullable at the schema level; `BackfillVolumePools` fills all existing
        // rows and creation always sets it.
        try await database.schema(Volume.schema)
            .field("pool_id", .uuid, .references(StoragePool.schema, "id"))
            .update()

        try await database.schema(Volume.schema)
            .field("attached_agent_id", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(Volume.schema)
            .deleteField("pool_id")
            .update()

        try await database.schema(Volume.schema)
            .deleteField("attached_agent_id")
            .update()
    }
}
