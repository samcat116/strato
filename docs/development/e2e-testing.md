# End-to-end testing on a single host

Most Swift package tests need no running services. Control-plane tests are the
exception: they require PostgreSQL and clone a migrated template database per
test, as described in [local development](./local-development.md). This page
covers the full-system check: standing up a real control plane, attaching a
real hypervisor agent, and booting a real VM — the only way to catch bugs that
live in the seams between the control plane, the proxy, SPIRE, OVN, and QEMU.

Two scripts do the work:

| Script | Runs as | What it does |
| --- | --- | --- |
| `deploy/compose/e2e-up.sh` | you | Stack, admin key, node enrollment, fixtures, smoke test |
| `deploy/compose/e2e-agent.sh` | **root** | The node-side `spire-agent` + `strato-agent` |

The split exists because the agent must run as root — the SPIRE workload entry
`e2e-up.sh` provisions carries the default selector `unix:uid:0`, so a non-root
agent never gets an SVID and the control plane refuses it. (The default comes
from `SPIRE_AGENT_SELECTORS`; if your deployment overrides it, adjust to match.)

## Prerequisites

- Docker with the Compose plugin, and `deploy/compose/.env` (run `./setup.sh` once).
- KVM (`/dev/kvm`), plus OVS and OVN running, for `network_mode = "ovn"`.
- A Swift toolchain new enough for the agent's dependencies. `swift-toml` tracks
  a `swift-tools-version:6.3` manifest, so if your default `swift` is older:

  ```bash
  swiftly run +6.3.2 swift build --package-path agent
  ```

- `spire-agent` on the host, and an agent config at `/etc/strato/config.toml`.
  The scripts only check that the file exists — a wrong `control_plane_url`
  presents as an agent that starts cleanly and never registers, which is
  exactly the failure this page exists to prevent. A minimal one:

  ```toml
  control_plane_url = "wss://<host>:8443/agent/ws"
  network_mode = "ovn"          # or "user" for macOS / no-SDN hosts

  [spiffe]
  enabled = true
  trust_domain = "strato.local"
  workload_api_socket_path = "/var/run/spire/sockets/workload.sock"
  source_type = "workload_api"
  ```

  The host and port must match `EXTERNAL_HOSTNAME` in `deploy/compose/.env`,
  and the trust domain must match the SPIRE server's.

## Building from source

`docker-compose.yml` pins `image:` to GHCR tags, so a build only happens if an
override supplies `build:`. Put this in an untracked
`deploy/compose/docker-compose.override.yml`:

```yaml
services:
  control-plane:
    build: {context: ../.., dockerfile: control-plane/Dockerfile}
    pull_policy: never
  frontend:
    build: {context: ../../control-plane/web, dockerfile: Dockerfile}
    pull_policy: never
  # Shares the control-plane image tag. Without this it pulls GHCR :main and
  # seeds your deployment with a different build than the one under test.
  bootstrap:
    pull_policy: never
```

A cold build takes roughly 35 minutes, dominated by compiling dependencies. Run
it in the background.

## The loop

```bash
cd deploy/compose
./e2e-up.sh --fresh                 # DESTRUCTIVE: wipes volumes, rebuilds, sets up
```

It stops partway and prints the command you must run as root, then waits for the
agent to register:

```bash
sudo RUN_DIR=<printed by e2e-up.sh> bash deploy/compose/e2e-agent.sh reset
```

`sudo` does not forward the environment, so `RUN_DIR` has to be passed on the
command line — `e2e-up.sh` prints the whole invocation with it already filled
in, so copy that rather than typing it.

When it finishes you get an org, project, site (with its network controller
assigned), a network, a guest image, and a 16/16 smoke test.

Useful variants:

```bash
./e2e-up.sh --no-build              # reuse existing images
./e2e-up.sh --api-key sk_...        # DB already has users; supply your own key
./e2e-up.sh --stage stack           # stop once the stack is healthy
./e2e-up.sh --down                  # stop the stack, keep volumes
```

Stages run in order — `stack → key → enroll → agent → fixtures → smoke` — and
the whole script is idempotent, so re-running it reuses whatever already exists.

## Booting a VM

`e2e-up.sh` prints a ready-to-paste create call.

Lifecycle endpoints (create/start/stop/delete, plus VM pause/resume/resize) are
**level-triggered**, not job-queue style. They return **202 Accepted** with
`{resource, targetGeneration, mutationId}` — there is no operation object to
poll, and no "already pending" 409, because overlapping writes to desired state
are safe by construction.

To wait for one, refetch the resource and read its `conditions`:

```json
{"targetGeneration": 2, "observedGeneration": 2, "converged": true}
```

- **done** ⇔ `converged`, at or past the `targetGeneration` you were handed
- **failed** ⇔ `degraded.sinceGeneration == targetGeneration`

Exactly one of the two ever holds: a failure recorded at the target generation
makes `converged` false (STR-191). A `degraded` naming an *older* generation is
a failure a newer mutation is already retrying, and it can stand alongside a
converged resource — which is why the comparison is by generation, not presence.

Prefer that over `status` alone. VMs are still created in `Created` rather than
running, so start them explicitly with `POST /api/vms/{id}/start`.

### Live vCPU shrink contract

`deploy/compose/vcpu-shrink-test.sh` exercises STR-241 on the libvirt agent
host. It starts a 2-vCPU VM, checks that API convergence agrees with
`virsh vcpucount --live`, proves a running 2→1 request is rejected without
changing either result, then stops, resizes, and starts the VM and checks both
surfaces again at 1 vCPU:

```bash
sudo deploy/compose/vcpu-shrink-test.sh \
  --origin "$ORIGIN" --api-key "$(cat "$KEY_FILE")" \
  --project "$PROJECT_ID" --network "$NET_ID" --image "$IMAGE_ID"
```

Run it as an account that can read `qemu:///system`; the script deletes its VM
on exit. Running vCPU shrink is intentionally not pending-reboot state: the API
returns `422` and tells the caller to stop, resize, and start the VM.

One carve-out keeps the older machinery:

- **Delete** is the one mutation whose success is the resource's *absence*, so
  conditions cannot report it. Poll the compatibility façade
  `GET /api/operations/{mutationId}` instead. Past its deadline a delete reads
  `pending`, not `failed` — a slow teardown is not a failed one.

### Confirming the guest actually booted

`status: Running` only means the hypervisor process started. For proof the guest
kernel is alive, look for `guestMemoryUsedBytes` together with a recent
`guestMemoryStatsAt` — those come from virtio-balloon `guest-stats`, which only
report once the guest binds the balloon driver.

`observedAddresses` stays empty unless the guest runs `qemu-guest-agent`.
Cirros does not ship one.

### Serial console

```
GET /api/vms/{ID}/console      (WebSocket, needs `vm:viewConsole` in the key restriction)
```

The VM id in that path must be **uppercase** — the agent's `managedVMs` map is
case-sensitive, and a lowercase id resolves to "Hypervisor service not
available".

Not every image talks to the serial port. Cirros under UEFI/OVMF puts no getty
on `ttyS0`, so its console is silent even though the VM booted fine. The Ubuntu
cloud images do, and show the whole boot including cloud-init.

## Traps

**Compose volumes are named after the directory.** The project is `compose`, so
volumes are `compose_postgres_data`, not `strato_*`. `docker volume ls | grep
strato` finds nothing and will convince you the database is fresh when it is
not.

**`bootstrap` only works on an empty database.** It refuses once any user
exists. On a dirty database, export `STRATO_API_KEY` with a key minted in the UI
under **Access → API Keys**, or start over with `--fresh`.

**Pass `--admin-email` if you want to use the UI.** Without it, `bootstrap`
seeds a headless admin that has no passkey and cannot log in, and it spends the
first-user-becomes-admin slot — so a passkey you register in the browser
afterwards gets no privileges at all: no projects, and the admin-only nav items
stay hidden (they are gated on `isSystemAdmin`). With it, you get a one-time
claim link to enrol a passkey against a real admin account:

```bash
./e2e-up.sh --fresh --admin-email you@example.com
```

To rescue a deployment that is already in that state, promote an existing
account:

```bash
docker compose run --rm bootstrap grant-platform-admin --email you@example.com --claim
```

**A `down -v` rotates the SPIRE CA.** The node's cached SVID in
`/var/lib/spire/agent` was issued by the old CA; `spire-agent` will try to
re-attest with it and silently ignore the fresh join token. `e2e-agent.sh reset`
clears it. It also clears `/var/lib/strato/vms`, whose VMs the new control plane
has never heard of and would otherwise report as orphans.

**`reset` refuses on a managed hypervisor node.** It deletes
`/var/lib/spire/agent` and `/var/lib/strato/vms`, which are the same paths
`deploy/agent/install.sh` manages on a real node — so it stops outright when
systemd is running the `strato-agent` unit, or has it enabled to start at the
next boot. Clear that deliberately if you mean it:

```bash
systemctl disable --now strato-agent
```

A unit file that is merely *present* while disabled and inactive is treated as
a leftover from an earlier `install.sh` run: `reset` warns and continues, since
the confirmation prompt already gates the deletion. Remove the dead unit with
`rm /etc/systemd/system/strato-agent.service && systemctl daemon-reload` to
silence the warning.

**`reset` also refuses while guests are live on those paths**, whatever systemd
thinks. It looks for processes whose command line references
`/var/lib/strato/vms` — QEMU, Firecracker, and the jailer, whose chroot is under
the same tree — and stops with their pids rather than deleting disks out from
under them. Hypervisor processes outlive the agent by design, so `systemctl
disable --now strato-agent` alone does not make the tree safe to remove. This is
also the only half of the guard that engages on the non-systemd hosts
`install.sh` supports. Stop the guests first, or remove the paths by hand if you
know they are already dead.

**The site needs a network controller.** Without
`networkControllerAgentId` on the site, nothing authors the OVN logical
switches and VMs hang in create. `e2e-up.sh` sets it once an agent is online.

**List endpoints do not share a shape.** `/api/projects` returns a bare array;
sites, networks, agents and VMs return `{items, total, limit, offset}`.

## Tearing down

```bash
cd deploy/compose
sudo RUN_DIR=<same as setup> bash e2e-agent.sh stop
./e2e-up.sh --down          # keep volumes
docker compose down -v      # discard everything
```
