# Volume replica cutover

STR-232 removes `volumes.hypervisor_id` and `volumes.storage_path`. Before
deploying it, inventory live volumes whose active replica set does not match
their storage-pool policy:

```sql
SELECT v.id,
       v.name,
       p.name AS pool,
       p.mode,
       p.replication_factor,
       active.replica_count,
       active.missing_agent_count,
       active.nonmember_count,
       active.pathless_healthy_count
FROM volumes v
LEFT JOIN storage_pools p ON p.id = v.pool_id
CROSS JOIN LATERAL (
    SELECT COUNT(*) AS replica_count,
           COUNT(*) FILTER (
               WHERE NOT EXISTS (
                   SELECT 1 FROM agents a
                   WHERE lower(a.id::text) = lower(r.agent_id)
               )
           ) AS missing_agent_count,
           COUNT(*) FILTER (
               WHERE p.id IS NOT NULL
                 AND cardinality(p.member_agent_ids) > 0
                 AND NOT (r.agent_id = ANY(p.member_agent_ids))
           ) AS nonmember_count,
           COUNT(*) FILTER (
               WHERE r.state = 'healthy' AND r.dataset_path IS NULL
           ) AS pathless_healthy_count
    FROM volume_replicas r
    WHERE r.volume_id = v.id
      AND r.state IN ('healthy', 'provisioning')
) active
WHERE v.desired_status::text <> 'Absent'
  AND (
      p.id IS NULL
      OR active.replica_count
         <> CASE WHEN p.mode = 'local' THEN 1 ELSE p.replication_factor END
      OR active.missing_agent_count > 0
      OR active.nonmember_count > 0
      OR active.pathless_healthy_count > 0
  )
ORDER BY v.id;
```

The migration re-runs the idempotent phase-1 backfill from the legacy fields.
If anything remains, it stops before dropping either column and reports each
volume ID and reason. Repair the replica rows from storage inventory, rerun the
query, and restart the migration. Do not invent a healthy replica for bytes
whose physical location has not been verified.

After migration, verify that the query returns no rows and that the legacy
columns and index are absent:

```sql
SELECT column_name
FROM information_schema.columns
WHERE table_name = 'volumes'
  AND column_name IN ('hypervisor_id', 'storage_path');

SELECT indexname
FROM pg_indexes
WHERE tablename = 'volumes'
  AND indexname = 'idx_volumes_hypervisor_id';
```
