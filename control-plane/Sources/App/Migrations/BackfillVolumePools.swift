import Fluent
import Foundation
import SQLKit

/// Snapshot of the `volumes` columns this backfill reads. Going through the
/// live `Volume` model would break this migration as soon as the model grows
/// a field whose column postdates this point in the migration order.
private final class BackfillVolume: Model, @unchecked Sendable {
    static let schema = "volumes"

    @ID(key: .id)
    var id: UUID?

    @OptionalField(key: "hypervisor_id")
    var hypervisorId: String?

    @OptionalField(key: "storage_path")
    var storagePath: String?

    init() {}
}

/// Snapshot of the `volume_replicas` columns as created by
/// `CreateVolumeReplica`, for the same reason as `BackfillVolume`.
private final class BackfillVolumeReplica: Model, @unchecked Sendable {
    static let schema = "volume_replicas"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "volume_id")
    var volumeId: UUID

    @Field(key: "agent_id")
    var agentId: String

    @OptionalField(key: "dataset_path")
    var datasetPath: String?

    @Field(key: "state")
    var state: String

    @Field(key: "generation")
    var generation: Int64

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}
}

/// Storage phase 1 (issue #349): adopts every pre-pool volume into the default
/// `local` pool and materializes its single physical copy as a `VolumeReplica`
/// row, derived from the legacy `hypervisor_id` + `storage_path` columns.
/// Attached volumes also get `attached_agent_id`, which for a local pool is
/// the same agent that holds the replica.
///
/// Every step is guarded (pool unset, replica absent) so a re-run is a no-op.
struct BackfillVolumePools: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }

        try await sql.raw(
            """
            UPDATE volumes
            SET pool_id = (SELECT id FROM storage_pools WHERE name = \(bind: StoragePool.defaultPoolName))
            WHERE pool_id IS NULL
            """
        ).run()

        try await sql.raw(
            """
            UPDATE volumes
            SET attached_agent_id = hypervisor_id
            WHERE attached_agent_id IS NULL AND hypervisor_id IS NOT NULL AND vm_id IS NOT NULL
            """
        ).run()

        // Replica rows need generated UUIDs, which portable SQL can't express;
        // create them through the (frozen) model instead.
        let placedVolumes = try await BackfillVolume.query(on: database)
            .filter(\.$hypervisorId != nil)
            .all()

        for volume in placedVolumes {
            guard let volumeId = volume.id, let agentId = volume.hypervisorId else { continue }

            let existing = try await BackfillVolumeReplica.query(on: database)
                .filter(\.$volumeId == volumeId)
                .filter(\.$agentId == agentId)
                .count()
            guard existing == 0 else { continue }

            let replica = BackfillVolumeReplica()
            replica.volumeId = volumeId
            replica.agentId = agentId
            replica.datasetPath = volume.storagePath
            replica.state = VolumeReplicaState.healthy.rawValue
            replica.generation = 0
            try await replica.create(on: database)
        }
    }

    func revert(on database: Database) async throws {
        // The backfilled columns are dropped by AddStoragePoolToVolume's revert
        // and the replica rows by CreateVolumeReplica's; nothing to undo here.
    }
}
