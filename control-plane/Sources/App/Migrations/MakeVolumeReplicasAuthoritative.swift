import Fluent
import Foundation
import SQLKit
import StratoShared

/// Final storage phase-1 cutover (STR-232).
///
/// Re-runs the idempotent legacy backfill, inventories every live volume, and
/// refuses to drop the legacy placement/path columns unless every volume uses
/// the implemented local-pool policy and has one usable replica. A failed preflight is intentionally a
/// migration failure: inventing a host for already-observed bytes would be a
/// data-loss bug, while dropping the only recorded location would make repair
/// impossible.
struct MakeVolumeReplicasAuthoritative: AsyncMigration {
    private struct InvalidReplicaRow: Decodable {
        let id: UUID
        let reason: String
    }

    struct InvalidReplicaInventory: Error, CustomStringConvertible, Sendable {
        let entries: [String]

        var description: String {
            "Cannot make VolumeReplica authoritative; repair these live volumes first: "
                + entries.joined(separator: "; ")
                + ". See docs/operations/volume-replica-cutover.md."
        }
    }

    func prepare(on database: Database) async throws {
        let sql = try PostgresMigrationSQL.database(database)

        // The original backfill is guarded at every write and is safe to run
        // again. This repairs databases where a volume appeared between the
        // phase-1 migration and this cutover, or where the earlier migration
        // completed only part of its work before migrations became atomic.
        try await BackfillVolumePools().prepare(on: database)

        // Fill a missing path on an already-usable replica from the legacy
        // copy. Never revive a faulted/degraded replica from the less precise
        // legacy fields: those states carry newer health information and must
        // fail the inventory until an operator repairs them explicitly.
        try await sql.raw(
            """
            UPDATE volume_replicas AS r
            SET dataset_path = v.storage_path
            FROM volumes AS v
            WHERE r.volume_id = v.id
              AND r.agent_id = v.hypervisor_id
              AND v.hypervisor_id IS NOT NULL
              AND r.state IN (
                    \(bind: VolumeReplicaState.healthy.rawValue),
                    \(bind: VolumeReplicaState.provisioning.rawValue)
                  )
              AND r.dataset_path IS NULL
              AND v.storage_path IS NOT NULL
            """
        ).run()

        let invalid = try await sql.raw(
            """
            SELECT v.id,
                   CASE
                     WHEN v.pool_id IS NULL THEN 'missing storage pool'
                     WHEN p.id IS NULL THEN 'storage pool row is missing'
                     WHEN p.mode <> \(bind: StoragePoolMode.local.rawValue)
                       THEN 'storage pool mode ' || p.mode::text || ' is not implemented'
                     WHEN active.replica_count <> 1
                       THEN 'active replica count ' || active.replica_count::text
                            || ' does not match local pool policy'
                     WHEN active.invalid_agent_count > 0
                       THEN 'replica references a missing agent'
                     WHEN active.nonmember_count > 0
                       THEN 'replica agent is not a pool member'
                     WHEN active.pathless_healthy_count > 0
                       THEN 'healthy replica has no dataset path'
                   END AS reason
            FROM volumes AS v
            LEFT JOIN storage_pools AS p ON p.id = v.pool_id
            CROSS JOIN LATERAL (
                SELECT COUNT(*)::bigint AS replica_count,
                       COUNT(*) FILTER (
                           WHERE NOT EXISTS (
                               SELECT 1 FROM agents a
                               WHERE lower(a.id::text) = lower(r.agent_id)
                           )
                       )::bigint AS invalid_agent_count,
                       COUNT(*) FILTER (
                           WHERE p.id IS NOT NULL
                             AND cardinality(p.member_agent_ids) > 0
                             AND NOT (r.agent_id = ANY(p.member_agent_ids))
                       )::bigint AS nonmember_count,
                       COUNT(*) FILTER (
                           WHERE r.state = \(bind: VolumeReplicaState.healthy.rawValue)
                             AND r.dataset_path IS NULL
                       )::bigint AS pathless_healthy_count
                FROM volume_replicas AS r
                WHERE r.volume_id = v.id
                  AND r.state IN (
                      \(bind: VolumeReplicaState.healthy.rawValue),
                      \(bind: VolumeReplicaState.provisioning.rawValue)
                  )
            ) AS active
            WHERE v.desired_status::text <> \(bind: DesiredVolumeStatus.absent.rawValue)
              AND (
                  v.pool_id IS NULL
                  OR p.id IS NULL
                  OR p.mode <> \(bind: StoragePoolMode.local.rawValue)
                  OR active.replica_count <> 1
                  OR active.invalid_agent_count > 0
                  OR active.nonmember_count > 0
                  OR active.pathless_healthy_count > 0
              )
            ORDER BY v.id
            """
        ).all(decoding: InvalidReplicaRow.self)

        guard invalid.isEmpty else {
            throw InvalidReplicaInventory(
                entries: invalid.map { "\($0.id.uuidString) (\($0.reason))" })
        }

        // A terminating row with no active copy has nothing left that can
        // confirm teardown. Normalize the old single-agent token before its
        // fallback placement disappears so the orphan sweep can reap it.
        try await sql.raw(
            """
            UPDATE volumes AS v
            SET finalizers = CASE
                WHEN EXISTS (
                    SELECT 1 FROM volume_replicas r
                    WHERE r.volume_id = v.id
                      AND r.state IN (
                          \(bind: VolumeReplicaState.healthy.rawValue),
                          \(bind: VolumeReplicaState.provisioning.rawValue)
                      )
                ) THEN ARRAY[\(bind: ResourceFinalizer.agentAbsent.rawValue)]::text[]
                ELSE ARRAY[]::text[]
            END
            WHERE v.desired_status::text = \(bind: DesiredVolumeStatus.absent.rawValue)
            """
        ).run()

        try await sql.raw("DROP INDEX IF EXISTS idx_volumes_hypervisor_id").run()
        try await database.schema(Volume.schema)
            .deleteField("storage_path")
            .deleteField("hypervisor_id")
            .update()
    }

    func revert(on database: Database) async throws {
        let sql = try PostgresMigrationSQL.database(database)
        try await database.schema(Volume.schema)
            .field("storage_path", .string)
            .field("hypervisor_id", .string)
            .update()

        try await sql.raw(
            """
            WITH chosen AS (
                SELECT DISTINCT ON (r.volume_id)
                       r.volume_id, r.agent_id, r.dataset_path
                FROM volume_replicas r
                WHERE r.state IN (
                    \(bind: VolumeReplicaState.healthy.rawValue),
                    \(bind: VolumeReplicaState.provisioning.rawValue)
                )
                ORDER BY r.volume_id,
                         CASE WHEN r.state = \(bind: VolumeReplicaState.healthy.rawValue) THEN 0 ELSE 1 END,
                         r.created_at,
                         r.id
            )
            UPDATE volumes AS v
            SET hypervisor_id = chosen.agent_id,
                storage_path = chosen.dataset_path
            FROM chosen
            WHERE chosen.volume_id = v.id
            """
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_volumes_hypervisor_id ON volumes (hypervisor_id)"
        ).run()
    }
}
