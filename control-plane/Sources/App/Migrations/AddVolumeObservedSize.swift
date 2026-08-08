import Fluent

/// The virtual size the owning agent reports a volume actually has (STR-199),
/// alongside the `size` a caller asked for.
///
/// One nullable column and no backfill, because NULL already means the right
/// thing for every existing row: no agent has reported a size yet, and the next
/// observed-state report from a v37 agent fills it in. Backfilling from `size`
/// would assert the very thing this column exists to stop asserting — that what
/// was asked for is what is on disk.
struct AddVolumeObservedSize: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Volume.schema)
            .field("observed_size_bytes", .int64)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Volume.schema)
            .deleteField("observed_size_bytes")
            .update()
    }
}
