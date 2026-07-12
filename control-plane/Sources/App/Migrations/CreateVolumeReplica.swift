import Fluent

/// Storage phase 1 (issue #349): `volume_replicas` records each physical copy
/// of a volume — which agent holds it, where, and its health. Replica rows are
/// owned by their volume (cascade delete); a `local`-pool volume has exactly
/// one.
struct CreateVolumeReplica: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(VolumeReplica.schema)
            .id()
            .field("volume_id", .uuid, .required, .references("volumes", "id", onDelete: .cascade))
            .field("agent_id", .string, .required)
            .field("dataset_path", .string)
            .field("state", .string, .required)
            .field("generation", .int64, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            // One copy of a volume per agent, in any pool mode.
            .unique(on: "volume_id", "agent_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(VolumeReplica.schema).delete()
    }
}
