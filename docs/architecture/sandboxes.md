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
running container workload. It lives in [`sandbox-guest/`](../../sandbox-guest/)
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
  (#416, landed — see the control-plane section).
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
  the OCI ref and resolved digest, entrypoint/cmd/env/workdir overrides, a
  stored-but-unenforced `ttl_seconds` (enforcement is #424), and the reported
  exit code (#413, landed).
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
   alias files so digest-pinned sandboxes hit it offline), TTL-evicted — v1
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

## Later phases

- **Phase 2 (remaining)**: TTL/auto-expiry (#424).
- **Phase 3**: jailer hardening (#425).
- **Phase 4**: snapshot/checkpoint primitives and resume (#426), fork into new
  sandboxes (#427), and snapshot mobility — off-node export, cross-agent
  restore, diff snapshots (#428). Cross-agent restore is why the CPU-template
  decision is forced at sandbox create time.

## Non-goals (v1)

- Layer-level dedup or a snapshotter — flattened-image cache only.
- Warm pools / pre-booted guests (phase 4 explores snapshot warm start first).
- Volumes, disk hot-plug, or live migration for sandboxes.
- macOS agents — Firecracker is Linux/KVM-only; capability gating keeps them
  out of placement.
