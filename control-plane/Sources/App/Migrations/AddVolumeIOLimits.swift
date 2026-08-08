import Fluent

/// Absolute per-volume I/O ceilings (STR-19): the pair a caller requests, and
/// the pair the owning agent echoes back as actually applied.
///
/// Four nullable columns and no backfill, because NULL already means the right
/// thing for every existing row — uncapped on the requested pair, and "the
/// agent has said nothing" on the applied pair. No enum column, so no
/// `PersistedEnumConstraint`.
///
/// The applied pair will read NULL for every row until the agent-side work
/// lands. That is the point rather than a gap: STR-19 ships no wire capability
/// gate, so an agent that drops `ioLimits` from its sync still advances
/// `observed_generation` and the generation pair alone would call an ignored
/// mutation converged. These two columns are what make the difference visible.
struct AddVolumeIOLimits: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Volume.schema)
            .field("iops_total", .int64)
            .field("bps_total", .int64)
            .field("applied_iops_total", .int64)
            .field("applied_bps_total", .int64)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Volume.schema)
            .deleteField("iops_total")
            .deleteField("bps_total")
            .deleteField("applied_iops_total")
            .deleteField("applied_bps_total")
            .update()
    }
}
