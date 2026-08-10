# VM manifest cutover

STR-225 removes the agent's always-reachable migration from
`qemu-manifest.json` and makes `kind` required on every entry in the unified
`vm-manifest.json`. Before deploying a version containing that removal, every
agent host must have been converged by the preceding, migration-capable agent
version.

## Read-only fleet inventory

Run the preflight as root on every agent host. It defaults to the standard VM
storage directory; pass the configured `vm_storage_dir` when a host overrides
it:

```sh
agent/scripts/vm-manifest-preflight.sh
agent/scripts/vm-manifest-preflight.sh /srv/strato/vms
```

For an Ansible inventory, the `script` module transfers and runs the same local
check on every host:

```sh
ansible strato_agents --become \
  -m ansible.builtin.script \
  -a 'agent/scripts/vm-manifest-preflight.sh /var/lib/strato/vms'
```

The script only checks file presence and reads JSON with `jq`; it never changes
a manifest. It exits nonzero for either unsafe state:

- `qemu-manifest.json` exists without `vm-manifest.json`. The output also names
  entries in the pre-VMSpec `VmConfig` shape when it can parse them.
- An entry in `vm-manifest.json` has no `kind`. This is the unified shape from
  before the manifest covered both VMs and sandboxes.

An unreadable or non-object unified manifest also fails because the inventory
cannot prove that every workload has a kind-complete entry. This cutover check
does not replace the agent's per-entry decoder: unrelated future or corrupt
fields still use its normal quarantine and partial-recovery path. A
`qemu-manifest.json` beside a kind-complete unified manifest is reported as a
shadow file but does not fail because the unified manifest is already
authoritative.

## Remediate with the migration-capable agent

Do not delete a legacy-only manifest. It may be the only durable record that a
live VM owns capacity and disks on the host.

For each failed host, keep the preceding agent version installed and start it
once. Wait for the agent to reconnect, receive an authoritative sync, and
re-adopt every live workload. That version writes `vm-manifest.json` before it
removes a legacy-only `qemu-manifest.json`; re-adoption also rewrites kindless
entries with the current shape.

Verify the unified manifest before advancing the host:

```sh
jq -r 'to_entries[] | [.key, .value.kind, .value.hypervisorType] | @tsv' \
  /var/lib/strato/vms/vm-manifest.json
agent/scripts/vm-manifest-preflight.sh /var/lib/strato/vms
```

Match the listed workload IDs against the control plane and the host's live
libvirt/Firecracker workloads. Investigate any missing ID; do not manufacture
or delete entries to make the check pass. A shadow legacy file may be archived
only after this comparison proves that the unified manifest preserves every
live workload.

Repeat the fleet inventory until every host exits zero. Record that result as
the deployment gate, then deploy the STR-225 version one host at a time. After
each restart, verify the same workload IDs remain in `vm-manifest.json` and the
agent reports them before advancing to the next host. The post-deployment check
is the same script; any legacy-only or kindless result is an unsupported
pre-cutover host and must be investigated rather than silently migrated.
