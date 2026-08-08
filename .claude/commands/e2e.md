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
sudo RUN_DIR=<printed> bash deploy/compose/e2e-agent.sh reset    # after --fresh
sudo RUN_DIR=<printed> bash deploy/compose/e2e-agent.sh start    # otherwise
```

`e2e-up.sh` prints the exact invocation with `RUN_DIR` filled in — relay that
verbatim. `sudo` does not forward the environment, so omitting it makes the
agent script look for a SPIRE config that was written somewhere else.

`e2e-up.sh` blocks until the agent registers, so just let it wait.

If the agent binary is missing, build it first — the default toolchain may be
too old for `swift-toml`:

```bash
swiftly run +6.3.2 swift build --package-path agent
```

## 3. Exercise a VM

`e2e-up.sh` prints the ids and a ready-made create call. Cover at least:

1. **Create** → 202 with `{resource, targetGeneration, mutationId}`. Lifecycle
   mutations are level-triggered: there is no operation object to poll and no
   "already pending" 409. Wait by refetching the resource — done ⇔ `conditions`
   `converged` at or past your `targetGeneration`, failed ⇔
   `degraded.sinceGeneration == targetGeneration`. Exactly one of the two ever
   holds (STR-191), so a resource reading both is a bug worth reporting.
2. **Start** → `POST /api/vms/{id}/start` (VMs are created in `Created`, not
   running).
3. **Boot proof** → poll `GET /api/vms/{id}` for
   `conditions.converged == true`, then confirm `guestMemoryUsedBytes` with a
   recent `guestMemoryStatsAt`. Those come from virtio-balloon guest-stats and
   only appear once the guest kernel binds the driver, so they are real evidence
   the guest booted — `status: Running` alone is not.
4. **Console** → WebSocket `GET /api/vms/{ID}/console`, id **uppercase**, API key
   needs `write` scope. Use an Ubuntu cloud image if you want boot output;
   cirros under UEFI puts no getty on ttyS0 and looks silent.
5. **Stop / start again**, watching `conditions` transition.
6. **Delete**, then verify the QEMU process, the OVN logical switch port, the
   TAP and the VM's directory under `/var/lib/strato/vms` are all gone. Delete
   is the one mutation conditions cannot report (success is the row's absence),
   so poll the façade `GET /api/operations/{mutationId}` instead.

Also worth checking on the host: `pgrep -f qemu-system`, the agent log at
`$RUN_DIR/strato-agent.log`, and the `resource_events` table
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

If the user will also be using the UI, pass `--admin-email <them>` so bootstrap
mints a passkey claim link. Without it the seeded admin is headless and the
first-user-becomes-admin slot is spent, so any passkey they register afterwards
lands with no privileges.

## Cleanup

```bash
sudo RUN_DIR=<same as setup> bash deploy/compose/e2e-agent.sh stop
cd deploy/compose && ./e2e-up.sh --down
```
