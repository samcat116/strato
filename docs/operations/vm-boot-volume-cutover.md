# VM boot-volume cutover

STR-231 makes a managed `Volume` the only representation of a VM boot disk.
Run the read-only inventory below before deploying the migration. In the first
query, a count of zero is the expected backfill set and a count above one is a
hard stop. Every subsequent query must be empty; repair any named VM or volume
before retrying.

## Preflight inventory

VMs without exactly one attached boot volume:

```sql
SELECT vm.id, vm.name, COUNT(v.id) AS boot_volume_count
FROM vms vm
LEFT JOIN volumes v ON v.vm_id = vm.id AND v.type::text = 'boot'
GROUP BY vm.id, vm.name
HAVING COUNT(v.id) <> 1
ORDER BY id;
```

VMs whose canonical `disk0`/boot-order-0 slot is occupied by a data volume:

```sql
SELECT vm.id, vm.name, v.id AS conflicting_volume_id,
       v.device_name, v.boot_order
FROM vms vm
JOIN volumes v ON v.vm_id = vm.id AND v.type::text <> 'boot'
WHERE v.device_name = 'disk0' OR v.boot_order = 0
ORDER BY vm.id, v.id;
```

Boot volumes whose pool or active local replica does not match the VM:

```sql
WITH inventory AS (
    SELECT vm.id, vm.hypervisor_id, v.id AS volume_id, p.name AS pool_name,
           p.mode AS pool_mode, p.member_agent_ids,
           r.agent_id, r.state, r.disk_attachment,
           COUNT(r.id) OVER (PARTITION BY v.id) AS replica_count
    FROM vms vm
    JOIN volumes v ON v.vm_id = vm.id AND v.type::text = 'boot'
    LEFT JOIN storage_pools p ON p.id = v.pool_id
    LEFT JOIN volume_replicas r ON r.volume_id = v.id
      AND r.state::text IN ('healthy', 'provisioning')
)
SELECT id, hypervisor_id, volume_id, pool_name, pool_mode,
       agent_id, state, disk_attachment
FROM inventory
WHERE pool_mode IS DISTINCT FROM 'local'
   OR (
       cardinality(member_agent_ids) > 0
       AND hypervisor_id IS NOT NULL
       AND NOT (hypervisor_id = ANY(member_agent_ids))
   )
   OR (hypervisor_id IS NOT NULL AND replica_count <> 1)
   OR (hypervisor_id IS NULL AND replica_count <> 0)
   OR (hypervisor_id IS NOT NULL AND agent_id IS DISTINCT FROM hypervisor_id)
ORDER BY id;
```

The last query is deliberately strict. Do not choose a replica arbitrarily.
Confirm the hypervisor and on-disk bytes, repair `volume_replicas`, then rerun
the inventory.

On every agent that hosts a legacy VM, verify the historical VM disk path and
the configured `volume_storage_dir` are on the same filesystem. The agent
adopts the existing bytes with a hard link before volume reconciliation; it
fails the volume closed instead of re-materializing the source image when the
path is missing or crosses filesystems.

```sh
df -P /var/lib/strato/vms/<vm-id>/disk.qcow2 /var/lib/strato/volumes
```

## Migration behavior

For a VM missing its boot volume, the migration creates `disk0` at boot order
0 in the default local pool. A placed QEMU VM adopts `vms.disk_path`; a placed
Firecracker VM adopts `/var/lib/strato/vms/<vm-id>/rootfs.raw`. Unplaced VMs
receive no replica until normal scheduler placement selects an agent.

The migration then creates a partial unique index on `volumes(vm_id)` for boot
volumes plus a canonical-attachment check constraint, drops `vms.disk_path`
and `vms.readonly_disk`, and rebuilds quota reservation caches from
managed-volume sizes. On the next sync, the agent hard-links the historical
path into `<volume_storage_dir>/<volume-id>/volume.<format>` before it samples
volume presence; deleting that boot volume later removes both names only when
they still identify the same inode.

## Post-migration verification

Both queries must return no rows:

```sql
SELECT vm.id, COUNT(v.id) AS boot_volume_count
FROM vms vm
LEFT JOIN volumes v ON v.vm_id = vm.id AND v.type::text = 'boot'
GROUP BY vm.id
HAVING COUNT(v.id) <> 1;

SELECT vm.id, v.id AS volume_id, v.device_name, v.boot_order, v.readonly
FROM vms vm
JOIN volumes v ON v.vm_id = vm.id AND v.type::text = 'boot'
WHERE v.device_name <> 'disk0' OR v.boot_order <> 0 OR v.readonly;
```

For each placed VM, also verify that its boot volume has one active replica on
`vm.hypervisor_id` and that the next desired-state/observed-state cycle reaches
the current VM and volume generations.
