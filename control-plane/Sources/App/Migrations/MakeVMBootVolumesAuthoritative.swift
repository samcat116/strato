import Fluent
import Foundation
import SQLKit
import StratoShared

/// Final VM boot-storage cutover (STR-231).
///
/// Inventories ambiguous attachments first, creates a canonical managed boot
/// volume for every missing VM, adopts its existing bytes into a replica, and
/// only then removes the two VM-side compatibility columns. The migration
/// fails closed on ambiguity: picking one of two boot volumes, or stealing
/// `disk0` from a data volume, could boot different bytes after the deploy.
struct MakeVMBootVolumesAuthoritative: AsyncMigration {
    static let canonicalBootIndex = "uniq_volumes_vm_canonical_boot"
    static let canonicalBootConstraint = "volumes_canonical_boot"

    private struct InvalidRow: Decodable {
        let id: UUID
        let reason: String
    }

    struct InvalidBootVolumeInventory: Error, CustomStringConvertible, Sendable {
        let entries: [String]

        var description: String {
            "Cannot make VM boot volumes authoritative; repair these VMs first: "
                + entries.joined(separator: "; ")
                + ". See docs/operations/vm-boot-volume-cutover.md."
        }
    }

    func prepare(on database: any Database) async throws {
        let sql = try PostgresMigrationSQL.database(database)

        let invalid = try await sql.raw(
            """
            WITH inventory AS (
                SELECT vm.id,
                       vm.hypervisor_id IS NOT NULL AS placed,
                       COUNT(DISTINCT b.id)::bigint AS boot_count,
                       COUNT(DISTINCT c.id)::bigint AS canonical_slot_conflicts,
                       COUNT(DISTINCT r.id) FILTER (
                           WHERE r.state IN (
                               \(bind: VolumeReplicaState.healthy.rawValue),
                               \(bind: VolumeReplicaState.provisioning.rawValue)
                           )
                       )::bigint AS active_boot_replicas,
                       COUNT(DISTINCT r.id) FILTER (
                           WHERE r.state IN (
                               \(bind: VolumeReplicaState.healthy.rawValue),
                               \(bind: VolumeReplicaState.provisioning.rawValue)
                           ) AND vm.hypervisor_id IS NOT NULL
                             AND r.agent_id <> vm.hypervisor_id
                       )::bigint AS misplaced_boot_replicas,
                       COUNT(DISTINCT b.id) FILTER (
                           WHERE b.desired_status::text = \(bind: DesiredVolumeStatus.absent.rawValue)
                       )::bigint AS terminating_boot_count,
                       COUNT(DISTINCT b.id) FILTER (
                           WHERE b.project_id <> vm.project_id OR b.environment <> vm.environment
                       )::bigint AS ownership_mismatches,
                       COUNT(DISTINCT b.id) FILTER (
                           WHERE b.id IS NOT NULL
                             AND (b.pool_id IS NULL OR p.id IS NULL OR p.mode::text <> \(bind: StoragePoolMode.local.rawValue))
                       )::bigint AS storage_pool_mismatches,
                       COUNT(DISTINCT b.id) FILTER (
                           WHERE vm.hypervisor_id IS NOT NULL
                             AND COALESCE(cardinality(p.member_agent_ids), 0) > 0
                             AND NOT (vm.hypervisor_id = ANY(p.member_agent_ids))
                       )::bigint AS pool_membership_mismatches
                FROM vms vm
                LEFT JOIN volumes b ON b.vm_id = vm.id AND b.type::text = \(bind: VolumeType.boot.rawValue)
                LEFT JOIN volume_replicas r ON r.volume_id = b.id
                LEFT JOIN storage_pools p ON p.id = b.pool_id
                LEFT JOIN volumes c ON c.vm_id = vm.id
                  AND c.type::text <> \(bind: VolumeType.boot.rawValue)
                  AND (c.device_name = 'disk0' OR c.boot_order = 0)
                GROUP BY vm.id
            )
            SELECT id,
                   CASE
                     WHEN boot_count > 1 THEN 'has ' || boot_count::text || ' attached boot volumes'
                     WHEN canonical_slot_conflicts > 0
                       THEN 'disk0 or boot order 0 is occupied by a data volume'
                     WHEN terminating_boot_count > 0 THEN 'its boot volume is already terminating'
                     WHEN ownership_mismatches > 0 THEN 'boot-volume project or environment differs from the VM'
                     WHEN storage_pool_mismatches > 0 THEN 'boot volume does not belong to a supported local pool'
                     WHEN pool_membership_mismatches > 0 THEN 'VM agent is not a member of the boot volume pool'
                     WHEN boot_count = 1 AND placed AND active_boot_replicas <> 1
                       THEN 'placed boot volume does not have exactly one active replica'
                     WHEN boot_count = 1 AND NOT placed AND active_boot_replicas > 0
                       THEN 'unplaced boot volume already has an active replica'
                     WHEN misplaced_boot_replicas > 0 THEN 'boot replica is not on the VM agent'
                   END AS reason
            FROM inventory
            WHERE boot_count > 1
               OR canonical_slot_conflicts > 0
               OR terminating_boot_count > 0
               OR ownership_mismatches > 0
               OR storage_pool_mismatches > 0
               OR pool_membership_mismatches > 0
               OR (boot_count = 1 AND placed AND active_boot_replicas <> 1)
               OR (boot_count = 1 AND NOT placed AND active_boot_replicas > 0)
               OR misplaced_boot_replicas > 0
            ORDER BY id
            """
        ).all(decoding: InvalidRow.self)

        guard invalid.isEmpty else {
            throw InvalidBootVolumeInventory(
                entries: invalid.map { "\($0.id.uuidString) (\($0.reason))" })
        }

        let missingOwner = try await sql.raw(
            """
            SELECT vm.id, 'no user exists to own the backfilled volume' AS reason
            FROM vms vm
            WHERE NOT EXISTS (
                SELECT 1 FROM volumes b
                WHERE b.vm_id = vm.id AND b.type::text = \(bind: VolumeType.boot.rawValue)
            )
              AND NOT EXISTS (SELECT 1 FROM users)
            ORDER BY vm.id
            """
        ).all(decoding: InvalidRow.self)
        guard missingOwner.isEmpty else {
            throw InvalidBootVolumeInventory(
                entries: missingOwner.map { "\($0.id.uuidString) (\($0.reason))" })
        }

        guard
            let defaultPool = try await StoragePool.query(on: database)
                .filter(\.$name == StoragePool.defaultPoolName)
                .first(), defaultPool.mode == .local
        else {
            throw InvalidBootVolumeInventory(
                entries: ["default storage pool is missing or is not local"])
        }
        let defaultPoolID = try defaultPool.requireID()

        // UUID-derived names are stable, valid, and cannot collide with another
        // VM's boot volume in the same project. The source bytes already live
        // at the VM-side path; the replica adoption below records that fact.
        try await sql.raw(
            """
            INSERT INTO volumes (
                id, name, description, project_id, environment,
                size, format, type, status, desired_status,
                generation, observed_generation, readonly, finalizers,
                pool_id, attached_agent_id, vm_id, device_name, boot_order,
                source_image_id, source_volume_id, created_by_id,
                created_at, updated_at
            )
            SELECT gen_random_uuid(),
                   'boot-' || vm.id::text,
                   'Canonical boot volume for VM ' || vm.name,
                   vm.project_id, vm.environment,
                   vm.disk,
                   CASE WHEN vm.hypervisor_type::text = \(bind: HypervisorType.firecracker.rawValue)
                        THEN \(bind: VolumeFormat.raw.rawValue)
                        ELSE \(bind: VolumeFormat.qcow2.rawValue) END,
                   \(bind: VolumeType.boot.rawValue),
                   \(bind: VolumeStatus.creating.rawValue),
                   \(bind: DesiredVolumeStatus.present.rawValue),
                   1, 0,
                   false, ARRAY[]::text[],
                   \(bind: defaultPoolID), vm.hypervisor_id,
                   vm.id, 'disk0', 0,
                   vm.image_id, NULL,
                   COALESCE(
                       (
                           SELECT u.id
                           FROM role_bindings rb
                           JOIN users u ON u.id = rb.principal_id
                           WHERE rb.principal_type = \(bind: IAMPrincipalType.user.rawValue)
                             AND rb.node_type = \(bind: IAMNodeType.virtualMachine.rawValue)
                             AND rb.node_id = vm.id
                           ORDER BY rb.created_at NULLS LAST, u.created_at, u.id
                           LIMIT 1
                       ),
                       (SELECT id FROM users ORDER BY is_system_admin DESC, created_at, id LIMIT 1)
                   ),
                   COALESCE(vm.created_at, now()), now()
            FROM vms vm
            WHERE NOT EXISTS (
                SELECT 1 FROM volumes b
                WHERE b.vm_id = vm.id AND b.type::text = \(bind: VolumeType.boot.rawValue)
            )
            """
        ).run()

        // Historical boot rows already identify the correct bytes. Normalize
        // only ownership/device facts; retain their desired size and lineage.
        try await sql.raw(
            """
            UPDATE volumes b
            SET device_name = 'disk0',
                boot_order = 0,
                readonly = false,
                attached_agent_id = vm.hypervisor_id,
                format = CASE
                    WHEN vm.hypervisor_type::text = \(bind: HypervisorType.firecracker.rawValue)
                    THEN \(bind: VolumeFormat.raw.rawValue)
                    ELSE b.format::text
                END,
                source_image_id = COALESCE(b.source_image_id, vm.image_id),
                updated_at = now()
            FROM vms vm
            WHERE b.vm_id = vm.id AND b.type::text = \(bind: VolumeType.boot.rawValue)
            """
        ).run()

        // Preserve direct grants on the VM for the managed boot resource. The
        // boot volume still inherits project grants normally; this avoids
        // narrowing an explicit per-VM delegation during the cutover.
        try await sql.raw(
            """
            INSERT INTO role_bindings (
                id, principal_type, principal_id, role_id, node_type, node_id,
                condition, expires_at, created_by, created_at
            )
            SELECT gen_random_uuid(), rb.principal_type, rb.principal_id, rb.role_id,
                   \(bind: IAMNodeType.volume.rawValue), b.id,
                   rb.condition, rb.expires_at, rb.created_by, rb.created_at
            FROM volumes b
            JOIN role_bindings rb
              ON rb.node_type = \(bind: IAMNodeType.virtualMachine.rawValue)
             AND rb.node_id = b.vm_id
            WHERE b.type::text = \(bind: VolumeType.boot.rawValue)
            ON CONFLICT ON CONSTRAINT uq_role_bindings_principal_role_node DO NOTHING
            """
        ).run()

        // A placed VM's legacy disk is already on its agent. Record the
        // replica as provisioning so the agent must adopt and report the bytes
        // before the control plane claims they are healthy. Unplaced VMs
        // intentionally receive no replica until normal placement.
        try await sql.raw(
            """
            INSERT INTO volume_replicas (
                id, volume_id, agent_id, dataset_path, state, generation, created_at, updated_at
            )
            SELECT gen_random_uuid(), b.id, vm.hypervisor_id,
                   CASE WHEN vm.hypervisor_type::text = \(bind: HypervisorType.firecracker.rawValue)
                        THEN '/var/lib/strato/vms/' || vm.id::text || '/rootfs.raw'
                        ELSE COALESCE(
                            vm.disk_path,
                            '/var/lib/strato/vms/' || vm.id::text || '/disk.qcow2')
                   END,
                   \(bind: VolumeReplicaState.provisioning.rawValue),
                   b.generation, now(), now()
            FROM vms vm
            JOIN volumes b ON b.vm_id = vm.id AND b.type::text = \(bind: VolumeType.boot.rawValue)
            WHERE vm.hypervisor_id IS NOT NULL
              AND NOT EXISTS (
                  SELECT 1 FROM volume_replicas r WHERE r.volume_id = b.id
              )
            """
        ).run()

        // Before this cutover Firecracker ignored VM.disk_path and always
        // booted the image materialized as rootfs.raw. Point its one active
        // boot replica at those bytes so the agent adopts the disk the guest
        // actually used, rather than the unused qcow2 compatibility path.
        try await sql.raw(
            """
            UPDATE volume_replicas r
            SET dataset_path = '/var/lib/strato/vms/' || vm.id::text || '/rootfs.raw',
                generation = GREATEST(r.generation, b.generation),
                updated_at = now()
            FROM volumes b
            JOIN vms vm ON vm.id = b.vm_id
            WHERE r.volume_id = b.id
              AND b.type::text = \(bind: VolumeType.boot.rawValue)
              AND vm.hypervisor_type::text = \(bind: HypervisorType.firecracker.rawValue)
              AND vm.hypervisor_id IS NOT NULL
              AND r.agent_id = vm.hypervisor_id
              AND r.state IN (
                  \(bind: VolumeReplicaState.healthy.rawValue),
                  \(bind: VolumeReplicaState.provisioning.rawValue)
              )
            """
        ).run()

        try await sql.raw(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS \(unsafeRaw: Self.canonicalBootIndex)
            ON volumes (vm_id)
            WHERE vm_id IS NOT NULL AND type = 'boot'
            """
        ).run()
        try await sql.raw(
            """
            ALTER TABLE volumes
            ADD CONSTRAINT \(unsafeRaw: Self.canonicalBootConstraint)
            CHECK (
                type::text <> 'boot'
                OR (vm_id IS NOT NULL AND device_name = 'disk0' AND boot_order = 0 AND NOT readonly)
            )
            """
        ).run()

        let remaining = try await sql.raw(
            """
            SELECT vm.id,
                   'canonical boot volume count is ' || COUNT(b.id)::text AS reason
            FROM vms vm
            LEFT JOIN volumes b ON b.vm_id = vm.id AND b.type::text = 'boot'
            GROUP BY vm.id
            HAVING COUNT(b.id) <> 1
            ORDER BY vm.id
            """
        ).all(decoding: InvalidRow.self)
        guard remaining.isEmpty else {
            throw InvalidBootVolumeInventory(
                entries: remaining.map { "\($0.id.uuidString) (\($0.reason))" })
        }

        try await database.schema(VM.schema)
            .deleteField("disk_path")
            .deleteField("readonly_disk")
            .update()

        // The accounting source changed from VM.disk to Volume.size. Rebuild
        // every cached reservation before this migration commits.
        for quota in try await ResourceQuota.query(on: database).all() {
            try await QuotaEnforcementService.resyncReservations(quota, on: database)
            try await quota.save(on: database)
        }
    }

    func revert(on database: any Database) async throws {
        let sql = try PostgresMigrationSQL.database(database)
        try await sql.raw(
            "ALTER TABLE volumes DROP CONSTRAINT IF EXISTS \(unsafeRaw: Self.canonicalBootConstraint)"
        ).run()
        try await database.schema(VM.schema)
            .field("disk_path", .string)
            .field("readonly_disk", .bool, .required, .sql(.default("false")))
            .update()

        try await sql.raw(
            """
            UPDATE vms vm
            SET disk_path = r.dataset_path,
                readonly_disk = b.readonly
            FROM volumes b
            LEFT JOIN volume_replicas r ON r.volume_id = b.id
              AND r.state IN (
                  \(bind: VolumeReplicaState.healthy.rawValue),
                  \(bind: VolumeReplicaState.provisioning.rawValue)
              )
            WHERE b.vm_id = vm.id
              AND b.type::text = 'boot'
              AND (r.agent_id = vm.hypervisor_id OR r.id IS NULL)
            """
        ).run()
        try await sql.raw(
            "DROP INDEX IF EXISTS \(unsafeRaw: Self.canonicalBootIndex)"
        ).run()
    }
}
