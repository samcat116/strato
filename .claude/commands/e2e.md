---
description: Stand up a full Strato stack + agent on this host and run an end-to-end VM test
---

Bring up a real control plane and hypervisor agent on this host, then exercise a
VM through its whole lifecycle. Full background in
`docs/development/e2e-testing.md` — read it if anything below is surprising.

Two scripts do the setup. Do not reimplement them inline.

## 1. Stand up the stack

```bash
cd deploy/compose && ./e2e-up.sh --no-build          # or --fresh to rebuild from source
```

- `--fresh` is **destructive** (`down -v`): it wipes the database, every
  organization/project/VM, and the operator's passkey credential. Confirm with
  the user before using it. Without it the existing deployment is reused.
- `--no-build` skips the image build. A cold source build takes ~35 minutes —
  always run it in the background with a generous timeout, never the default.
- Stages are `stack → key → enroll → agent → fixtures → smoke`; `--stage <name>`
  stops after one. The script is idempotent.

## 2. Start the agent (the user must do this)

The script pauses and prints the command. The agent needs root — the SPIRE
workload entry's selector is `unix:uid:0` — and `sudo` prompts for a password on
this host, so **hand it to the user and wait**; do not try to run it yourself.

```bash
sudo bash deploy/compose/e2e-agent.sh reset    # after --fresh
sudo bash deploy/compose/e2e-agent.sh start    # otherwise
```

`e2e-up.sh` blocks until the agent registers, so just let it wait.

If the agent binary is missing, build it first — the default toolchain may be
too old for `swift-toml`:

```bash
swiftly run +6.3.2 swift build --package-path agent
```

## 3. Exercise a VM

`e2e-up.sh` prints the ids and a ready-made create call. Cover at least:

1. **Create** → 202 with an operation whose `id` is *not* the VM id; poll
   `GET /api/operations/{id}` to terminal.
2. **Start** → `POST /api/vms/{id}/start` (VMs are created in `Created`, not
   running). Starting during a pending create is a 409 by design.
3. **Boot proof** → poll `GET /api/vms/{id}` for
   `conditions.converged == true`, then confirm `guestMemoryUsedBytes` with a
   recent `guestMemoryStatsAt`. Those come from virtio-balloon guest-stats and
   only appear once the guest kernel binds the driver, so they are real evidence
   the guest booted — `status: Running` alone is not.
4. **Console** → WebSocket `GET /api/vms/{ID}/console`, id **uppercase**, API key
   needs `write` scope. Use an Ubuntu cloud image if you want boot output;
   cirros under UEFI puts no getty on ttyS0 and looks silent.
5. **Stop / start again**, watching `conditions` transition.
6. **Delete**, then verify the QEMU process, the OVN logical switch port and the
   TAP are gone.

Also worth checking on the host: `pgrep -f qemu-system`, the agent log at
`/home/sam/strato-agent-run/strato-agent.log`, and the `resource_events` table
for the audit trail of every mutation.

## 4. Report

Say plainly what passed and what failed, with the evidence. If you find a bug,
confirm it against the source before reporting it — several things that look
wrong are deliberate:

- The `pg_strato_drop` "could not add port" warning is **fail-closed by design**
  and only logs on failure, so appearing once and not again means the retry
  succeeded.
- The libvirt version advisory is non-gating while
  `LibvirtProbe.driverBuilt == false`.

Known-open issues that will show up: STR-176 (VM delete leaks the boot disk —
clear `/var/lib/strato/vms` between runs), STR-177 (guest hostname disagrees
with `VM.hostname`), STR-178 (after bootstrap, no reachable system admin).

## Cleanup

```bash
sudo bash deploy/compose/e2e-agent.sh stop
cd deploy/compose && ./e2e-up.sh --down
```
