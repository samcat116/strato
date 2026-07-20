# Sandboxes

Sandboxes are a first-class workload type (umbrella issue #410): microVMs
booted from **OCI images** on Firecracker, with their own API surface
(`/api/sandboxes`) and data model, deliberately separate from VMs so the two
can diverge over time. Where a VM is a long-lived machine you manage,
a sandbox is a fast, disposable execution environment for a container-shaped
workload — an image reference, resource sizing, and overrides for
entrypoint/cmd/env/workdir.

> **Status**: phase 1 in progress. The wire protocol (issue #411), the
> generalized operation machinery (#412), the control-plane model/API (#413),
> registry pull secrets + tag→digest resolution (#414), scheduler gating
> + quota accounting (#415), the NIC/address model + IPAM integration
> (#416), the agent's OCI client + rootfs materialization (#418), and the
> guest base image — kernel + init/guest-agent (#419) — are landed; the rest
> of the agent runtime is tracked in issues #417 and #420–#422. Sections
> below describe the agreed design; anything not yet landed is marked with
> its issue.

## Decision: native Swift Firecracker path

Sandboxes extend the vendored `SwiftFirecracker/` package and the agent's
existing `FirecrackerService` machinery. **firecracker-containerd was
considered and rejected**: it brings a Go daemon and a devmapper thin-pool
host dependency, and fits poorly with the Swift agent's driver registry,
manifest, and reconciler. OCI pull/unpack, image caching, and vsock guest
control are built natively in the agent instead.

## Decision: guest rootfs & boot strategy

The guest base image (issue #419, landed) is what turns a booted microVM into a
running container workload. It lives in [`sandbox-guest/`](https://github.com/samcat116/strato/tree/main/sandbox-guest)
and ships two artifacts per architecture — an uncompressed Firecracker kernel
(`vmlinux-<arch>`) and a gzipped-cpio initramfs (`initramfs-<arch>.cpio.gz`)
holding a single static PID-1 init, `strato-sandbox-init`.

**Rootfs: initramfs + pivot onto a pristine drive.** The init boots from the
initramfs and `switch_root`s (the initramfs-correct form of `pivot_root`) onto
the flattened container rootfs (issue #418), which the runtime attaches as a
**separate block device** (default `/dev/vda`). The container image is never
mutated by init injection — issue #418's output stays a pristine container
filesystem, which was the deciding constraint. `SwiftFirecracker`'s `BootSource`
already carries an `initrd_path`, and `Drive` already supports the extra drive,
so no host-side model change is needed.

**Init language: Rust, static musl.** The init is a small fully-static binary
(no runtime deps inside the guest, fast boot) — the standard choice for a
microVM PID 1. It is isolated to the guest artifact and never linked into the
Swift agent, so it does not reintroduce the cross-language host dependency the
firecracker-containerd rejection avoided. Its portable logic (config merge,
vsock protocol) is unit-tested on any host; the Linux syscall paths are
exercised by the boot smoke test.

**Config delivery: a config drive, not vsock.** Because the v1 vsock surface is
deliberately health + exit only, the workload's launch configuration is handed
to the guest out-of-band on a tiny **read-only config block device** (default
`/dev/vdb`, named on the kernel cmdline as `strato.config=<dev>`). It carries a
single versioned JSON document (`GuestConfig`) with the rootfs mount spec, the
sandbox identity + vsock port, and the OCI **image config plus the sandbox
overrides** — the guest performs the OCI merge (entrypoint/cmd/env/workdir/user,
Docker-compatible rules), so those runtime semantics live in exactly one place.
This keeps the container image pristine and lets the workload launch without
waiting on the host to connect vsock (which #420 provides).

**vsock control surface (v1).** The init serves newline-delimited JSON on a
guest vsock port: `ping` → `pong`, and `get_status` → the workload's lifecycle
state and, once it ends, its exit code. Every response echoes `sandbox_id` +
boot `nonce` so the host can re-identify a guest after a phase-4
snapshot/resume. Exec/stdio streaming is out of scope for v1 (phase 2, #423).

**On-disk layout & capability gating.** The two artifacts install as a directory
at `sandbox_guest_image_path` (default `/var/lib/strato/sandbox/guest`)
alongside a `guest.json` manifest (schema version, image version, per-arch
checksums + default boot args). `StratoAgentCore/SandboxGuestImage` is the
resolver that reads that layout into concrete kernel/initramfs paths for the
host arch — the shared contract the sandbox runtime (#421) consumes so filenames
are not hard-coded at the call site. `SandboxRuntimeProbe` still only asserts the
path's presence (it must stay cheap and never fail a capability check on a parse
error); presence + a usable Firecracker is what lights up the `sandbox_runtime`
capability. The build/publish pipeline (`.github/workflows/sandbox-guest.yaml`)
builds both arches on a release tag and uploads the tarballs + `.sha256`
sidecars + a `sandbox-guest-manifest.json`, mirroring the agent release flow;
`task install-sandbox-guest` / `deploy/agent/install.sh --sandbox-guest` install
onto a host.

## Workload shape

A sandbox is described by `SandboxSpec`
(`shared/Sources/StratoShared/SandboxModels.swift`), which is deliberately
*not* a `VMSpec`:

- **Image**: an OCI reference (`registry/repo:tag`) plus the manifest digest
  it resolved to. The control plane resolves the tag at sync assembly, **at
  most once per sandbox**, and persists the pin so convergence is immutable —
  a re-tagged image never changes a sandbox out from under its generation.
  Resolution is best effort: a registry that is down never blocks the sync
  (the agent then resolves the tag itself until a later sync pins it).
- **Sizing**: vCPUs and memory bytes only.
- **Process**: optional entrypoint/cmd/workdir overrides and an env map,
  merged over the image config by the guest agent.
- **Networking**: at most one NIC on a `LogicalNetwork`, reusing the VM
  `NetworkSpec` so agents realize it through the same OVN/user-mode paths
  (#416, landed — see the control-plane section). **In v1 the NIC never goes
  on the wire**: the guest image has no in-guest networking (the init doesn't
  bring up eth0 and the kernel has no IP autoconfiguration), so the runtimes
  reject any spec with a non-nil network rather than mis-converge, and sync
  assembly omits the `NetworkSpec`
  (`SandboxSpecBuilder.guestNetworkingSupported`). The interface row and its
  IPAM allocation are still created at sandbox create, so the address is
  reserved and stable for when guest networking lands.
- **No** volumes, firmware, boot source, or hypervisor choice — sandboxes are
  Firecracker-only, and v1 has no attachable storage.

## Riding the reconciliation loop

Sandboxes reuse the level-triggered desired-state sync rather than growing a
parallel imperative path (see `docs/architecture/overview.md` for the loop
itself):

- `DesiredStateMessage.sandboxes` carries the full authoritative set of
  `DesiredSandboxState` entries for the agent, alongside `vms` and `networks`.
  Each entry has a monotonic per-sandbox `generation` with exactly the same
  drop/replay/reorder guarantees as VMs.
- Desired status is one of `running`, `stopped`, `absent` — strictly decoded,
  like `DesiredVMStatus`, because misreading a goal is destructive.
- `ObservedStateReport.sandboxes` reports observed status, the generation the
  observation reflects, a convergence phase while work is in flight, the last
  convergence error, and — new versus VMs — the workload's **exit code**.
- **Exited is not stopped.** A sandbox's workload can end on its own, which a
  VM never does from the control plane's perspective. The observed status
  `exited` satisfies both desired `running` ("the workload should have been
  started" — it ran to completion; phase 1 has no restart policy, so the
  reconciler must not relaunch one-shot workloads forever) and desired
  `stopped` (equally not-running). Exit-code surfacing to the API and richer
  lifecycle handling come with #423.
- Sandbox mutations create the same 202-Accepted async operation rows as VM
  mutations, via the operation machinery generalized in #412.

### Registry pull secrets and credentials on the wire

Private images need pull credentials agent-side (issue #414). Durable storage
is control-plane-only: a project stores at most one credential per registry
host under `/api/projects/:projectID/registry-credentials` (reads need
`view_project`, mutations `manage_project`), with the secret **encrypted at
rest** through the same `SecretsEncryptionService` machinery as OIDC client
secrets and never echoed back by the API.

`DesiredSandboxState` carries an optional `RegistryCredential` (registry host,
username, password/token, expiry, bearer flag) that the control plane mints
**fresh at every sync assembly** — the same slot where signed image URLs are
refreshed — so a long-lived desired entry never holds an expired secret. The
control plane speaks the distribution auth flow (`DistributionRegistryClient`:
challenge probe → token endpoint → manifest; Docker Hub, GHCR, and any
distribution-spec registry): when the registry has a token service it mints a
short-lived pull-scoped **bearer token** (`bearer: true`; agents present it
directly), and only for Basic-only registries — or when the token service is
unreachable — does it fall back to sending the stored credential itself
(`bearer: false`). Agents use the credential for the pull and never persist
it. Public images work with no credential and zero configuration; sandboxes
already pinned to a digest keep converging on it even if the credential is
later deleted.

### Protocol versioning

Sandbox sync is wire protocol **version 5** (`WireProtocol.swift`). The
change is additive — absent `sandboxes` lists decode to `[]` — but carries the
same asymmetric hazard as the v3 networks list:

- **Agent side**: a pre-v5 control plane omits the field entirely; the agent
  must not read the decoded-empty list as "tear down all sandboxes". Sandbox
  reconciliation is gated on `WireProtocol.supportsSandboxSync(senderVersion)`.
- **Control-plane side**: the wire version is deliberately *not* the placement
  signal. An agent built against v5 understands the fields but may predate the
  sandbox runtime (#421), and would silently ignore desired entries and report
  none back. Agents therefore advertise sandbox support explicitly at
  registration (`AgentRegisterMessage.sandboxCapable`), and the scheduler keys
  eligibility on that flag plus the version (#415) — never on the version
  alone. Agent-side, the flag comes from `SandboxRuntimeProbe`: the build must
  contain the runtime driver (`SandboxRuntimeProbe.runtimeBuilt`, hard-false
  until #421 lands — a runtime-less agent would silently ignore desired
  sandboxes), Firecracker must be usable (binary + KVM, from the hypervisor
  probe), **and** the sandbox guest base image (#419) must be present at
  `sandbox_guest_image_path` (default `/var/lib/strato/sandbox/guest`) — so
  the capability lights up exactly when a runtime-carrying agent has the
  artifacts installed on a capable host.

## Control plane (issues #412–#416)

- `Sandbox` model (`control-plane/Sources/App/Models/Sandbox.swift`) with the
  same desired/observed generation split as VMs, plus sandbox-only fields:
  the OCI ref and resolved digest, entrypoint/cmd/env/workdir overrides,
  `ttl_seconds` (enforced by the expiry sweep below), and the reported exit
  code (#413, landed).
- `/api/sandboxes` (`SandboxController`): list/create/show/update/delete +
  start/stop/restart + status + operations. Mutations insert a
  `resource_operations` row (`resource_kind = sandbox`) and bump desired state
  in one transaction, returning **202 Accepted** — the machinery generalized
  in #412. Restart is expressed as a fresh desired-`running` generation (there
  is no imperative sandbox reboot message); its agent-side interpretation
  lands with the runtime (#421).
- `definition sandbox` in SpiceDB: a near-copy of `virtual_machine` minus
  console/pause/promote, plus `exec` for phase 2. `SpiceDBAuthMiddleware`
  guards `/api/sandboxes` through the same route-prefix → resource-type
  mapping as VMs.
- Creation runs the quota admission check in the create transaction and places
  onto an agent that advertised the sandbox runtime (#415, see the versioning
  section above). Placement rides the same `filterEligibleAgents` pipeline and
  Valkey placement reservations as VMs; the reservation releases on the same
  triggers (send failure, the agent's observed-state reports accounting for
  the sandbox, deletion confirmation, TTL backstop).
- **TTL and auto-expiry (#424)**: sandboxes are ephemeral, and
  `sweepExpiredSandboxes` (on the `AgentService` heartbeat tick, a
  cluster-singleton under the `sandbox_expiry` sweep lock) is what makes that
  real. It deletes on two clocks: **TTL** — `ttl_seconds` past `created_at`,
  surfaced to clients as the derived `expiresAt` and counted down on the
  detail page — and **retention** — an exited or errored sandbox keeps its
  terminal record (status and exit code) for `SANDBOX_RETENTION_HOURS`
  (default 24; a non-positive value keeps terminal records forever), then the
  row goes. Errored sandboxes are included because they are terminal too and
  would otherwise hold their quota indefinitely. Both take the *same* path as
  `DELETE /api/sandboxes/:id` — a `resource_operations` row (attributed to a
  system sentinel user, so the unattended deletion stays auditable) plus
  desired `.absent` in one transaction, then agent teardown or, with no agent
  to converge on, a direct record delete — so quota and placement reservations
  release identically. Level-triggered like every sweep: a sandbox whose
  deletion is deferred (an operation is already pending) is simply
  re-evaluated next tick.
- **Quota accounting (#415)**: sandbox vCPUs and memory draw from the *same*
  `ResourceQuota` pools as VMs — `calculateActualUsage` and the reservation
  resync sum both workload kinds — while the count limit is a separate
  `max_sandboxes`/`sandbox_count` pair (backfilled from `max_vms`), so
  sandboxes never silently consume VM slots. Reservation happens in the create
  transaction (`QuotaEnforcementService.reserveSandbox`) and releases when the
  row is removed (deletion confirmed by agent report, or direct deletion for
  unplaced/agent-offline sandboxes). Sandboxes reserve no storage.
- Sandboxes reference images by OCI ref only — they do not use the
  `Image`/`ImageArtifact` model at all.

## Agent runtime (issues #417–#421)

The agent-side pipeline, all native Swift:

1. **OCI client + rootfs materialization** (#418, landed): `SandboxImageService`
   in `agent/Sources/StratoAgentCore/OCI/` turns a `SandboxSpec` image
   reference into a bootable ext4 rootfs. The distribution client mirrors the
   control plane's auth flow (anonymous/Basic/Bearer challenges, plus
   presenting control-plane-minted bearer tokens directly), narrows
   multi-platform indexes to the host's `CPUArchitecture`, verifies every
   manifest and blob against its digest, and retries transient failures the
   way `ImageCacheService` does. Layers (tar, tar+gzip, tar+zstd) are
   flattened with OCI whiteout handling and traversal-safe unpacking, then
   `mkfs.ext4 -d` builds the image sized to content plus configurable
   headroom, staged and published atomically. The cache is
   **content-addressed by platform manifest digest** (with index→platform
   alias files so digest-pinned sandboxes hit it offline) and evicted after
   each materialization: entries idle past a 7-day TTL, plus — when
   `sandbox_image_cache_max_size_gb` is set — least-recently-used entries
   beyond the size budget (recently used entries are grace-protected). v1
   caches flattened images only (no layer-level dedup/snapshotter). The image
   config's execution parameters (entrypoint/cmd/env/workdir/user) are staged
   as `config.json` beside `rootfs.ext4` — the rootfs stays a pristine
   container filesystem; how the config travels into the guest is the
   runtime's call (#421). Host prerequisites: gzip (and zstd for zstd layers)
   and e2fsprogs; sync-delivered registry credentials are used per pull and
   never persisted.
2. **Guest base image** (#419, landed): a maintained kernel plus a minimal
   static init/guest-agent. The init applies the OCI config
   (entrypoint/cmd/env/workdir), runs the workload, reaps zombies, and reports
   its exit over vsock — written with the phase-4 snapshot lifecycle (drain,
   re-listen, re-identify) in mind from the start. See the *guest rootfs & boot
   strategy* decision above for the rootfs/config-drive/vsock design and
   `sandbox-guest/` for the artifacts and build pipeline.
3. **vsock** (#420): SwiftFirecracker grows vsock device support for
   host↔guest control.
4. **`SandboxRuntimeService`** (#421): the driver that wires it together on
   the existing Firecracker machinery, registered in the agent's driver
   registry and manifest like any other backend, including orphan adoption
   after agent restarts. The reconciler and manifest are generalized over
   workload kinds first (#417, landed): the diff engine, generation guard,
   attempt cap, and per-workload serial lanes are shared across kinds — VM
   items route to hypervisor drivers, sandbox items to the
   `SandboxRuntimeService` seam (which stays nil, and the capability off,
   until #421 ships the driver) — and manifest entries carry a workload kind
   so sandbox orphans survive restarts with their resources reserved.

## Phase 2: exec/attach and workload logs (issue #423)

What makes sandboxes feel like sandboxes: getting into them and seeing their
output. Wire protocol **v8**.

### Guest control protocol v2

The guest agent's vsock surface (port 1024, newline-delimited JSON both ways)
grows beyond `ping`/`get_status`. The accept loop is now thread-per-connection
so health polls keep working while streams are active; the first request line
determines a connection's role:

- **Control** (`ping`, `get_status`): request/response, as v1.
- **Exec** (`exec {argv, env?, cwd?, tty?, rows?, cols?}`): the connection
  becomes a dedicated exec session. The guest spawns the process in the
  container context — the workload's resolved env (request env merged over
  it), cwd, and uid/gid — either on a PTY (`tty: true`; output arrives as one
  `stdout` stream, `resize` drives `TIOCSWINSZ`) or on pipes (stdout/stderr
  reported separately). Guest→host: `exec_started`, then `output` lines
  (base64), then a terminal `exec_exit {exit_code}` (killed-by-signal-N
  reported as 128+N, matching the workload convention). Host→guest:
  `stdin`/`stdin_eof`/`resize`. The host closing the connection early kills
  the exec process group.
- **Log follow** (`stream_logs {since_seq}`): the workload's stdout/stderr are
  no longer inherited from the serial console — the init captures them via
  pipes, mirrors every chunk to the console (serial debuggability is
  preserved), and appends them to a **256 KiB ring buffer** with a monotonic
  per-chunk sequence number. A follow connection replays retained records from
  `since_seq` (evicted records are silently skipped) and then streams new
  ones. Once every stdio pipe hits EOF and all retained records are delivered,
  the guest sends a terminal `log_eof` so the host can flush a partial final
  line (output that ended without a trailing newline) instead of holding it
  until teardown. Workload stdin is `/dev/null`.

PID 1's reaper is restructured to run forever with a child registry (exec
waiters + a bounded unclaimed-exit map), so exec exit codes are routed to
their sessions while the workload's exit still lands in the shared status the
control connections report.

### Host bridging and the wire

The agent bridges vsock streams to new **v8 stream messages** — correlated by
`sessionId`, ordered by the WebSocket, never answered with `success`/`error`:
`sandbox_exec_start/started/input/output/resize/exit/close/closed`. A
`sandbox_exec_start` is answered by `started` on success or `closed` (with a
reason) on failure. Like `agent_update` in v6 the gate is load-bearing on the
send side — a pre-v8 agent cannot decode the envelope and never replies — so
the control plane refuses exec for agents that registered with an older
version (`WireProtocol.supportsSandboxExec`).

Per running sandbox the agent also keeps a long-lived log-follow task
(reconnecting with backoff, resuming from the last seen sequence number),
assembles chunks into lines, and ships each as `sandbox_log {sandboxId,
stream, message}`. Both stream kinds react to control-plane connectivity:
when the agent's WebSocket drops, exec sessions are closed guest-side (the
control plane cannot close them over a dead socket, and a quiet process
would otherwise outlive its frontend) and log follows are suspended — output
waits in the guest ring buffer and ships after re-registration, rather than
being consumed toward a socket that cannot deliver it. The control plane verifies the reporting agent owns the
sandbox (the `vm_log` anti-spoofing rule) and pushes to Loki with labels
`sandbox_id`, `stream`, `source: workload` — the same Loki path VM logs use.
`GET /api/sandboxes/:id/logs` queries them back, mirroring the VM logs
endpoint.

### Control plane surface

- `POST /api/sandboxes/:id/exec` — guarded by the `exec` permission (an
  `actionVerbs` entry in `SpiceDBAuthMiddleware`, plus the in-handler check).
  Requires the sandbox running, placed, its agent socketed to **this replica**,
  and the agent at protocol ≥ 8. Returns `201 {sessionId, websocketPath,
  expiresAt}`; pending sessions expire unattached after 60s.
- `GET /api/sandboxes/:id/exec/:sessionId/attach` — WebSocket upgrade,
  modeled on the VM console tunnel (in-handler SpiceDB `exec` re-check,
  same-user binding to the pending session). Browser→CP: binary frames are
  stdin, text frames carry JSON `resize`. CP→browser: binary frames are
  output; text frames carry JSON `ready`/`exit`/`error` controls.

Like the VM console, exec is **single-replica**: the browser WebSocket must
land on the replica holding the agent socket (`SandboxExecSessionManager`
mirrors `ConsoleSessionManager` and does not forward over the coordination
RPC channels). Cross-replica stream forwarding is future work for both
tunnels; the POST fails fast with 503 when the agent is socketed elsewhere.

The frontend's sandbox detail page grows Terminal and Logs tabs mirroring the
VM page — the terminal drives exec sessions (default `/bin/sh`, PTY, resize
wired to xterm's fit addon), and the logs tab tails the Loki-backed endpoint.

## Phase 3: jailer hardening (issue #425)

Sandboxes run **untrusted** workloads by definition, so their VMM processes
get a hardening barrier VMs (operator-trusted workloads) don't: Firecracker's
own [jailer](https://github.com/firecracker-microvm/firecracker/blob/main/docs/jailer.md).
`SwiftFirecracker` grew `JailerOptions` and jail-aware spawn/adopt/destroy in
`FirecrackerClient`; the runtime derives everything per sandbox from a pure
`SandboxJailPlan` (`StratoAgentCore/SandboxJail.swift`), so create, adoption
after an agent restart, and teardown always agree on the layout with nothing
persisted.

**The barrier.** Each sandbox's Firecracker is spawned via
`jailer --id <sandboxId> --exec-file firecracker --uid/--gid ... --netns ...`:

- **Chroot**: `<sandbox_jailer_chroot_dir>/firecracker/<sandboxId>/root`
  becomes the process's `/`. Everything the microVM touches is staged inside
  before spawn — the writable rootfs copy and config drive are written
  directly there (jailed sandboxes don't use the flat per-sandbox directory at
  all), the shared kernel/initramfs are hard-linked in (copy across
  filesystems), and the Firecracker API receives in-jail paths (`/rootfs.ext4`,
  `/config.img`, `/kernel`, `/initramfs`). The API socket
  (`/run/firecracker.socket`) and vsock UDS (`/run/vsock.sock`) are created by
  the jailed process under `run/`; the host dials them through the chroot
  prefix. Phase-4 snapshot files will follow the same rule: staged into, and
  loaded from, in-jail paths. Teardown removes the whole jail subtree.
- **Privilege drop**: each sandbox runs as its own uid/gid, derived
  statelessly as `sandbox_jailer_uid_base + (FNV-1a-64(sandboxId) % 65536)` —
  stable across restarts, no allocation state. Writable artifacts are chowned
  to it; a slot collision between two sandboxes (rare at 2^16) weakens only
  their mutual isolation, never the host boundary.
- **Network namespace**: every jailed sandbox gets a dedicated netns
  (`strato-sbx-<id>`, created with `ip netns add`), today deliberately
  **empty** — a compromised VMM sees no host interfaces at all. This is the
  reconciliation point with the TAP/OVN attach flow: when guest networking
  lands, the agent creates the TAP in the host namespace, plugs it into the
  OVS integration bridge (exactly as for VMs), then moves it into the
  sandbox's netns before spawning the jailer with `--netns` — OVS keeps the
  port (datapath binding survives the namespace move) while the jailed
  process sees the device.
- **Seccomp**: Firecracker installs its own default seccomp filters
  unconditionally; the jailer adds no flag for it and the agent never passes
  `--no-seccomp`. Nothing to configure.

**Resource limits: one owner.** The agent's manifest-based reservation remains
the **only capacity/accounting owner** (what the scheduler sees), and the
Firecracker machine config remains the enforcement point for guest sizing
(vCPUs, guest RAM). The jailer cgroup adds exactly one thing on cgroup-v2
hosts: `memory.max = guest memory + 128 MiB`, a *host-protection backstop*
against a compromised VMM ballooning its host process — it feeds nothing back
into scheduling and is deliberately not a second accounting system. The
jailer never removes the per-VM cgroup directory it creates, so destroy
rmdir's it (after the process exits) and the crash-leftover sweep does the
same. No CPU
cgroup is set (vCPU count already bounds compute; host fairness is the kernel
scheduler's job). Cgroup-v1 hosts get the rest of the barrier and one warning.

**Policy: `sandbox_jailer_mode`.** `auto` (default) jails when the host can —
agent running as root and the jailer binary present (it ships in the
Firecracker release tarball; `task install-firecracker` and the agent's
default binary probe both know it) — and otherwise logs a prominent warning
and runs unjailed, keeping dev hosts working. `required` is the production
posture: if the jailer is unusable the agent **does not advertise the sandbox
capability** (the probe reports why) and the runtime refuses creates, because
silently running untrusted workloads unjailed on a host that demanded
hardening is not an option — while *existing* sandboxes stay fully manageable
(adopt/stop/delete need no new jailer spawn), so they never outlive their
deletion unmanaged.
`disabled` is the debugging escape hatch. Related knobs:
`sandbox_jailer_binary_path`, `sandbox_jailer_chroot_dir` (default
`<vm_storage_dir>/jailer` — each jail holds a full writable rootfs copy, so
it belongs on VM storage), `sandbox_jailer_uid_base` (default 100000).

**Adoption across config changes.** Orphan re-adoption always probes both
socket layouts (in-jail first, then flat), so a running sandbox survives an
operator flipping the jailer on or off between agent lives — the process
keeps whatever barrier it was born with until it is deleted (jailed PIDs are
rediscovered by the `--id` argument, since every jail shares the same
in-chroot `--api-sock` path). VMs (the
`FirecrackerService` path) remain unjailed for now; extending the barrier to
them is future work.

## Phase 4: snapshot primitives + checkpoint/resume (issue #426)

Firecracker snapshots capture the guest **memory + VMM/device state** of a
*paused* microVM — not the disk — and are tied to the Firecracker version,
host CPU, and device topology they were taken with. A Strato sandbox
checkpoint is therefore three artifacts taken as one consistent point in
time, plus recorded compatibility constraints:

- `memory.snap` + `vmstate.snap` — written by `PUT /snapshot/create` (full
  snapshots; `track_dirty_pages`/diff snapshots are wrapped in
  SwiftFirecracker but unused until #428).
- `rootfs.ext4` — a copy of the writable rootfs made **while the guest is
  paused**, via `cp --reflink=auto` (a free clone on reflink filesystems —
  btrfs/XFS today, the ZFS pool backend (#350) later — and a full copy
  otherwise). The tiny `config.img` rides along so a jailed restore can
  re-stage its chroot from the archive alone.

### Agent-side sequences

**Checkpoint** (`sandbox_snapshot_create`): drain host-side vsock connections
(exec sessions end terminally, the log follow suspends keeping its seq
checkpoint — Firecracker refuses to snapshot a vsock device with live
connections) → pause → `PUT /snapshot/create` → copy rootfs + config drive →
resume, or stay paused for **checkpoint-and-stop** (`mode: stop` — exactly
the paused state a control-plane stop produces, so the sandbox converges to
`stopped`). A `checkpointing` guard makes concurrent lifecycle calls
(boot/stop/exec) fail transient and keeps status polls off the drained vsock
channel. Jailed sandboxes stage the snapshot files inside the chroot (the
jailed VMM writes them) and the runtime moves them out to the host-owned
archive at `<sandbox storage>/<id>/snapshots/<snapshotId>/` — agent-owned
paths beside the sandbox (the volume-snapshot precedent), removed with it.

**Restore in place** (`sandbox_restore`, same agent, same identity): drain →
destroy the current Firecracker process → re-stage the layout from the
archive (for a jailed sandbox the whole chroot is rebuilt; kernel/initramfs
are deliberately absent — a snapshot load never reads the boot source) →
spawn a fresh process → `PUT /snapshot/load` (`resume_vm: true`) → guest-agent
health check (ping + identity nonce, which the checkpointed memory carries) →
best-effort `sync_clock` over vsock (the restored guest's wall clock froze at
checkpoint time; PID 1 sets `CLOCK_REALTIME`) → log follow resumes from its
seq checkpoint. The restored device topology re-binds the original vsock UDS
path; the (future) TAP devices come back under their original names the same
way.

### Control plane

`SandboxSnapshot` rows track status (`creating`/`ready`/`deleting`/`error`),
size, agent placement, and the compat constraints (Firecracker version,
architecture). `POST /api/sandboxes/:id/snapshots` (+ list/delete/restore)
ride the generalized 202-operation machinery (#412) with new operation kinds
`snapshot`/`snapshot_delete`/`restore`; the agent round-trip is an imperative
request/response RPC like volume operations (replica-forwarded, capability-
gated on `sandbox_snapshot_create`, wire protocol v9). Restore pins to the
snapshot's agent in v1 and flips desired state to `running` in the same
transaction (IPAM allocations stay held while checkpointed, so the sandbox
keeps its addresses). Snapshot storage draws from the shared storage quota
pool (#415): admission reserves the guest-memory size as an estimate, the
agent's reported actual sizes replace it, and quota resync sums non-error
snapshot rows.

### Warm start (issue #426, folded in from #425)

Warm start turns sandbox creation from "boot a guest" into "restore a
snapshot": the agent boots one throwaway **template** microVM per
(image, guest version, Firecracker build, machine shape) to the
ready-to-launch point, snapshots it, and provisions subsequent sandboxes for
that combination by restoring the template instead of cold-booting. Purely
agent-internal — no control-plane API, no wire-protocol change — and every
warm failure falls back to a cold boot, so the feature trades only latency,
never correctness. `sandbox_warm_start` (default true) gates it;
`sandbox_warm_cache_max_size_gb` (default 20) bounds the template cache at
`<vm_storage_dir>/warm-snapshots/`, LRU-swept like the image caches.

**Jailed-only.** Snapshot vmstate records drive/vsock backing files *by
path*. Jailed, those paths are chroot-relative constants (`/rootfs.ext4`,
`/snapshots/...`) identical in every jail, so a template snapshot loads
cleanly under any new sandbox's chroot with different files staged at the
same names. Unjailed, the recorded paths are the template's absolute host
paths — gone after template teardown — so warm start silently deactivates
on unjailed runtimes rather than restoring against deleted files. Template
builds run in the background (one at a time — a template is an unaccounted,
guest-memory-sized microVM), coalesced per key, with failures retried no
sooner than 15 minutes; crash-leaked templates are swept on the first
create of the next agent life (their self-describing `warm-template-` id
prefix is what makes that safe without manifest bookkeeping).

**The held point.** A template's config drive sets `warm_hold: true`: the
guest boots fully — mounts the rootfs, switch_roots onto it, starts the
vsock listener — but parks in the new `held` state instead of resolving and
spawning a workload. That point is deliberately **before any per-sandbox
identity is consumed**: no workload argv/env, no network identity (none
exists yet — #524), nothing but the template's own throwaway nonce in
memory. This is the "snapshot before identity" sidestep the issue calls out:
it keeps most of the fork-identity problem (#427) off the table.

**Template build**: cold-provision under a throwaway id with `warm_hold`
set → boot → verify over vsock that the guest actually reports `held` with
the template's identity (an older guest ignores the unknown field and execs
the image's default command — that build is abandoned rather than
snapshotted) → pause → snapshot → copy the template's rootfs **as of the
snapshot** (the held guest has it mounted, so restores must clone exactly
these bytes, not the pristine image) → publish into the cache with an
atomic rename, alongside a meta sidecar recording the template's id +
nonce → tear the template down.

**Warm provision + launch.** Create stages the new sandbox's jail with
reflink clones of the template's rootfs/memory/vmstate and the sandbox's
*own* config drive, then `PUT /snapshot/load` without resuming — landing in
`Paused`, exactly where a created-but-not-booted sandbox sits. Boot resumes
it and requires the guest to answer in the `held` state with **exactly the
template identity recorded in the cache meta** (so a workload can never be
launched into some other process answering on the deterministic UDS); it
then sends `sync_clock` and the new `launch` control request — carrying the
sandbox id, nonce, image config + overrides (the guest resolves them with
the identical cold-boot merge rules), and 32 bytes of host entropy the
guest mixes into `/dev/urandom` as best-effort warm-template divergence —
and verifies the guest now echoes the new identity. The
launch payload is reconstructed from the staged config drive, so the flow
survives agent restarts between create and boot with no extra persisted
state (identity delivery rides vsock rather than a guest re-read of the
config device, whose pre-snapshot page cache could serve the template's
stale bytes). The guest adopts the delivered identity only after the
workload actually spawns, so an interrupted launch (an agent crash
mid-flow) leaves it held under the template identity and the next boot
simply retries; boot also re-launches a held guest that already echoes the
sandbox identity, covering skewed guests that swapped early. A failed
launch demotes the sandbox to a freshly cold-provisioned microVM —
re-materialized with the create-time registry credential, provisioned
before the held guest is destroyed — and boots it once with warm launch
disallowed, so convergence can neither wedge nor loop.

One more mechanical enabler: every config drive is padded to one fixed
capacity (`SandboxConfigDrive.standardBlockImageBytes`, 256 KiB — part of
the warm key) so the config device's size always matches what the template
snapshot recorded, whatever document it carries; documents that exceed it
are cold-only. Boot logs `bootPath=warm|cold` with `bootMillis`, which is
the measurement hook for the cold-vs-warm latency comparison on strato-dev.

### Fork into a new sandbox (issue #427)

`POST /api/sandboxes` accepts `restoreFrom: <snapshot UUID>` instead of an
image. The caller needs `read` on the source `sandbox_snapshot` and
`create_resources` on the target project. Machine and process overrides are
rejected: the fork preserves the checkpointed image, vCPU/memory shape, and
process configuration, while the target supplies its own name, project,
environment, and TTL. `sandboxes.restored_from_snapshot_id` records lineage;
the API and web detail page expose it, and the snapshot list offers the fork
action.

Snapshot artifacts start agent-local, so scheduling pins to the snapshot's
`agent_id` (wire protocol **version 12**) until the snapshot is exported —
then any compatible agent is a candidate (see snapshot mobility below). The agent
also captures the checkpointed guest's own control-protocol version from its
versioned `pong` and persists it on the snapshot. Fork admission and placement
require guest control protocol v3; an upgraded v12 agent therefore cannot
mistake an older guest frozen in memory for one that understands
`reidentify`, and legacy/unknown snapshots remain usable for in-place restore
only. Snapshot creation also persists a fork-layout version only for jailed
sources; unjailed and legacy snapshots remain in-place-only because their
Firecracker device paths cannot be reused under a new jail root. The runtime
repeats the guest capability check after loading the checkpoint as defense in
depth. The agent
reflink-copies, or normally copies, `rootfs.ext4`, `memory.snap`,
`vmstate.snap`, and `config.img` into a new jailed sandbox layout and loads
the snapshot resumed. It first proves that the resumed guest has the source
sandbox id + nonce, then sends a one-shot `reidentify` request over the
restored vsock listener. That request supplies a fresh target nonce,
hostname, host entropy, and wall clock; PID 1 strictly reseeds `/dev/urandom`,
rewrites machine-id when the image provides one (scratch/distroless images may
omit `/etc` entirely), sets the hostname and `CLOCK_REALTIME`, and swaps its
reported sandbox identity last. Retained guest log history is cleared at that
boundary (sequence numbers and live stdio writers continue), so source output
is never replayed under the target. A second ping must return the target id +
nonce before the agent publishes the sandbox as managed. The target config
drive is then rewritten with the new identity so adoption and future
snapshots remain self-describing.

The create transaction always allocates a new sandbox row and default NIC,
MAC, and IPAM reservation. Guest networking is still disabled (#524), so
current snapshots contain no Firecracker network device to remap; when that
device is enabled, fork restore must additionally pass Firecracker
`network_overrides` and reconfigure the guest interface/DHCP lease before
health succeeds.

### Clone-safety policy

Cold-created sandboxes attach Firecracker's entropy device where the running
VMM supports it, and snapshot resume receives a new VM generation id from
Firecracker. Fork additionally requires the explicit guest RNG reseed above.
These measures diverge future randomness, identity, and time, but cannot make
all duplicated application memory safe: a checkpoint can contain reusable
tokens, application-generated identifiers, and TCP state. The API/UI therefore
states that inherited TCP connections are not portable. Operators must
checkpoint at an application-safe boundary and reconnect external services in
the fork.

To avoid multiplying or rewinding the exact same live state unexpectedly, a
snapshot with live descendants cannot be deleted or restored in place, and
its source sandbox cannot be deleted. Desired-state reconciliation may need
the original agent-local archive to recreate a fork after host/process loss,
so the snapshot remains a conservative lifetime dependency: delete the forks
first. Fork admission and all three destructive transitions—including
TTL/retention expiry of the source—take the same transaction-scoped Postgres
advisory lock per snapshot, then re-read status, source deletion/restore state,
and descendants in the transaction that writes their new state. Thus a racing
fork either commits lineage before deletion checks descendants or observes the
snapshot/source transition and is refused.
The target retains the opaque lineage UUID for audit/display.

### Snapshot mobility (issue #428)

Export makes a checkpoint durable and portable:
`POST /api/sandboxes/:id/snapshots/:snapshotId/export` (202 + operation,
kind `snapshot_export`, wire protocol **version 13**) asks the snapshot's
agent to stream all four artifacts to pre-signed upload URLs. Bytes flow
through the control plane into the image object store (`ImageObjectStore`,
filesystem or S3) under `sandbox-snapshots/{projectId}/{snapshotId}/...` —
agents never talk to the store directly, mirroring image downloads. The
upload route hashes and sizes each stream as it lands (integrity material is
never agent-supplied) and records per-artifact entries on the snapshot row;
the export operation stamps `exported_at` only once every artifact is
recorded. Transfer URLs are HMAC-signed with the method bound into the
payload, so an upload URL cannot be replayed as a download. Deleting the
snapshot (or cascading its sandbox) deletes the exported prefix.

An exported snapshot unlocks:

- **Cross-agent restore** — `.../restore` no longer requires the sandbox to
  sit on the snapshot's agent. The target must satisfy the recorded compat
  constraints (`SandboxSnapshotCompatibility`): wire v13, same architecture,
  the **same Firecracker version** (probed from `firecracker --version` at
  registration and carried on `HypervisorSupport.version`), and a matching
  guest CPU surface — either the snapshot records a CPU template, or the
  source and target hosts report identical CPU models. Missing information
  is always incompatible.
- **Cross-agent fork** — fork placement widens from the pinned agent to
  every compatible agent, and survives losing the snapshot's home agent
  entirely. Sync assembly injects signed, checksummed download descriptors
  into `restoreFrom` (re-minted every sync, like image URLs); the restore
  RPC carries the same descriptors. The target agent stages the archive
  into an LRU-swept import cache (`<sandbox storage>/snapshot-imports/`,
  sharing the warm-cache byte budget), verifying each artifact's size and
  SHA-256 before the atomic publish; concurrent forks of one snapshot on a
  host share a single download.

**CPU templates** are the mobility keystone: `POST /api/sandboxes` accepts
`cpuTemplate` (validated against Firecracker's static templates — C3/T2/
T2S/T2CL/T2A on x86_64, V1N1 on aarch64), applied at boot and thereby baked
into every checkpoint. The decision is deliberately create-time-only — a
template can never be applied at restore time, and an un-templated snapshot
only restores on identical CPU models. Templated creates are gated on v13
agents (an older agent would silently boot passthrough); the template is
part of the warm-snapshot cache key.

## Later phases
- **Phase 4 (remaining)**: the warm-vs-cold boot-latency measurement on
  strato-dev; diff snapshots via `track_dirty_pages` (wrapped in
  SwiftFirecracker, still unused) plus a periodic auto-checkpoint policy;
  uffd lazy-load restore for fork latency; and snapshot retention policies
  beyond delete-time cleanup (#428).

## Non-goals (v1)

- Layer-level dedup or a snapshotter — flattened-image cache only.
- Warm pools / pre-booted guests (phase 4 explores snapshot warm start first).
- Volumes, disk hot-plug, or live migration for sandboxes.
- macOS agents — Firecracker is Linux/KVM-only; capability gating keeps them
  out of placement.
