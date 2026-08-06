# End-to-end testing on a single host

Unit tests (`swift test`) need no running services. This page covers the other
kind of check: standing up a real control plane, attaching a real hypervisor
agent, and booting a real VM — the only way to catch bugs that live in the
seams between the control plane, the proxy, SPIRE, OVN, and QEMU.

Two scripts do the work:

| Script | Runs as | What it does |
| --- | --- | --- |
| `deploy/compose/e2e-up.sh` | you | Stack, admin key, node enrollment, fixtures, smoke test |
| `deploy/compose/e2e-agent.sh` | **root** | The node-side `spire-agent` + `strato-agent` |

The split exists because the agent must run as root — the SPIRE workload entry
`e2e-up.sh` provisions carries the selector `unix:uid:0`, so a non-root agent
never gets an SVID and the control plane refuses it.

## Prerequisites

- Docker with the Compose plugin, and `deploy/compose/.env` (run `./setup.sh` once).
- KVM (`/dev/kvm`), plus OVS and OVN running, for `network_mode = "ovn"`.
- A Swift toolchain new enough for the agent's dependencies. `swift-toml` tracks
  a `swift-tools-version:6.3` manifest, so if your default `swift` is older:

  ```bash
  swiftly run +6.3.2 swift build --package-path agent
  ```

- `spire-agent` on the host, and an agent config at `/etc/strato/config.toml`
  pointing `control_plane_url` at `wss://<host>:8443/agent/ws`.

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
sudo bash deploy/compose/e2e-agent.sh reset
```

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

Prefer that over `status` alone. VMs are still created in `Created` rather than
running, so start them explicitly with `POST /api/vms/{id}/start`.

Two carve-outs keep the older machinery:

- **Delete** is the one mutation whose success is the resource's *absence*, so
  conditions cannot report it. Poll the compatibility façade
  `GET /api/operations/{mutationId}` instead. Past its deadline a delete reads
  `pending`, not `failed` — a slow teardown is not a failed one.
- **VM restart** and every **snapshot** verb are imperative agent RPCs with no
  generation to converge on. They still write `ResourceOperation` rows and still
  return 409 when one is already pending.

### Confirming the guest actually booted

`status: Running` only means the hypervisor process started. For proof the guest
kernel is alive, look for `guestMemoryUsedBytes` together with a recent
`guestMemoryStatsAt` — those come from virtio-balloon `guest-stats`, which only
report once the guest binds the balloon driver.

`observedAddresses` stays empty unless the guest runs `qemu-guest-agent`.
Cirros does not ship one.

### Serial console

```
GET /api/vms/{ID}/console      (WebSocket, needs an API key with `write` scope)
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
exists. On a dirty database, mint a key in the UI under **Access → API Keys** and
pass `--api-key`, or start over with `--fresh`.

**Bootstrap consumes the first-user-becomes-admin slot.** A passkey registered
in the browser afterwards gets no privileges at all — no projects, and the
admin-only nav items stay hidden. Those are gated on `isSystemAdmin`, which
today can only be set at user creation. See
[STR-178](https://linear.app/stratocloud/issue/STR-178/bootstrap-leaves-the-deployment-with-no-reachable-system-admin).

**A `down -v` rotates the SPIRE CA.** The node's cached SVID in
`/var/lib/spire/agent` was issued by the old CA; `spire-agent` will try to
re-attest with it and silently ignore the fresh join token. `e2e-agent.sh reset`
clears it. It also clears `/var/lib/strato/vms`, whose VMs the new control plane
has never heard of and would otherwise report as orphans.

**The site needs a network controller.** Without
`networkControllerAgentId` on the site, nothing authors the OVN logical
switches and VMs hang in create. `e2e-up.sh` sets it once an agent is online.

**List endpoints do not share a shape.** `/api/projects` returns a bare array;
sites, networks, agents and VMs return `{items, total, limit, offset}`.

## Tearing down

```bash
cd deploy/compose
sudo bash e2e-agent.sh stop
./e2e-up.sh --down          # keep volumes
docker compose down -v      # discard everything
```
