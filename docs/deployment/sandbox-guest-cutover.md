# Sandbox guest schema and protocol cutover

STR-223 removes sandbox guest manifest/config schema 1 and guest control
protocols before v4. Run this inventory before deploying the cutover to any
sandbox-capable agent. The command is read-only.

## Control-plane inventory

List every persisted sandbox checkpoint and the compatibility metadata reported
by its owning agent:

```sql
SELECT
    id,
    sandbox_id,
    status,
    desired_status,
    agent_id,
    guest_control_protocol_version,
    fork_layout_version,
    exported_at,
    storage_path
FROM sandbox_snapshots
ORDER BY agent_id NULLS LAST, sandbox_id, id;
```

This blocker query must return no rows:

```sql
SELECT
    id,
    sandbox_id,
    status,
    desired_status,
    agent_id,
    guest_control_protocol_version,
    fork_layout_version,
    exported_at,
    storage_path
FROM sandbox_snapshots
WHERE desired_status <> 'Absent'
  AND (
      guest_control_protocol_version IS DISTINCT FROM 4
      OR exported_at IS NOT NULL
  )
ORDER BY agent_id NULLS LAST, sandbox_id, id;
```

Every export created before this cutover is a conservative blocker even when
its recorded guest protocol is v4. The database records the exported
`config.img` checksum, but not its decoded schema, and an object-store-only copy
is absent from every host preflight. A network-free protocol-v4 sandbox could
still have been stamped with config schema 1 by the previous agent. Purge these
exports before deploying the v2-only writer, then recapture and re-export them
after the strict agent is running. This avoids declaring an uninspected object
restorable based only on its guest protocol metadata.

`fork_layout_version` is included in the inventory because it determines fork
eligibility. A missing layout is an unjailed/in-place-only checkpoint, not a
config schema signal by itself. Do not rewrite it to `1`: the artifact layout
cannot be upgraded by changing database metadata.

Also inventory active sandboxes. A guest init is frozen in a running microVM,
so replacing the installed image does not upgrade an already-running sandbox:

```sql
SELECT id, name, status, hypervisor_id
FROM sandboxes
WHERE desired_status <> 'Absent'
ORDER BY hypervisor_id NULLS LAST, id;
```

Plan to recreate every sandbox that was booted from a pre-v4 guest. The strict
agent will reject its next health handshake instead of inferring support.

## Agent-host inventory

Run the host preflight on every sandbox-capable agent:

```sh
agent/scripts/sandbox-guest-cutover-preflight.sh
```

The defaults match the packaged agent:

- guest image: `/var/lib/strato/sandbox/guest`
- VM storage and snapshot record: `/var/lib/strato/vms`
- jailer chroot base: `/var/lib/strato/vms/jailer`
- Firecracker executable basename: `firecracker`

Pass the effective agent configuration when a host overrides any path:

```sh
agent/scripts/sandbox-guest-cutover-preflight.sh \
  --guest-image-dir /srv/strato/guest \
  --vm-storage-dir /srv/strato/vms \
  --jailer-chroot-dir /srv/strato/jailer \
  --firecracker-name firecracker
```

The script reports:

- the installed `guest.json` schema and complete required manifest shape;
- active flat and jailed config-drive schema versions;
- every locally recorded sandbox checkpoint's guest protocol, fork layout,
  storage path, and archived config-drive schema.

It exits nonzero for a missing/unreadable installed manifest, a manifest that
does not fully match schema 2, a config schema other than 2 or missing its
identity fields, missing checkpoint metadata/artifacts, or guest control
protocol other than 4. A host with no installed guest image is not a blocker by
itself because it cannot advertise the sandbox runtime.

## Remediation

1. Drain new sandbox placement from the affected agent.
2. Install the schema-v2 guest image from the same Strato release as the new
   agent. Re-run the preflight to verify `guest.json` before restarting the
   agent.
3. Recreate active sandboxes whose config drive is schema 1 or whose running
   guest predates protocol v4. Config drives and guest memory are per-sandbox;
   replacing `/var/lib/strato/sandbox/guest` does not mutate them.
4. Delete every pre-cutover exported checkpoint and every other legacy
   checkpoint through
   `DELETE /api/sandboxes/{sandboxID}/snapshots/{snapshotID}`, or boot/recreate
   the source sandbox on the current guest after deploying the v2-only writer,
   capture a replacement checkpoint, and export the replacement when off-agent
   durability is required. Delete live forks first when lineage protection
   refuses the old checkpoint's deletion.
5. Do not remove `config.img`, snapshot directories, snapshot-record entries,
   or exported objects by hand. The asynchronous API deletion keeps agent
   inventory, control-plane rows, quota, lineage, and object storage consistent.

There is no in-place upgrade for checkpointed guest memory. Changing only
`guest_control_protocol_version`, `fork_layout_version`, or the JSON version in
an archived `config.img` would relabel old bytes and can invalidate exported
artifact integrity; recapture or purge is the supported path.

## Verification and deployment

Repeat both the database blocker query and the host preflight until every site
is zero. Then deploy the strict agent/control plane. After deployment, repeat
the same checks. An old artifact is now rejected with a message to replace the
guest/recreate the sandbox or delete and recapture its checkpoint; it is never
partially restored or feature-gated.
