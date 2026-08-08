# Sandboxes

Sandboxes are a first-class workload type (umbrella issue #410): microVMs
booted from **OCI images** on Firecracker, with their own API surface
(`/api/sandboxes`) and data model, deliberately separate from VMs so the two
can diverge over time. Where a VM is a long-lived machine you manage,
a sandbox is a fast, disposable execution environment for a container-shaped
workload — an image reference, resource sizing, and overrides for
entrypoint/cmd/env/workdir.

> **Status**: implemented end to end — the lifecycle and data model, the full
> agent runtime (OCI pull + rootfs materialization, the guest base image,
> vsock control, `FirecrackerSandboxRuntime`, jailer hardening), exec/attach
> + workload logs, and snapshots (checkpoint/restore, warm start, fork,
> cross-agent mobility) are all landed. The main open front is **guest
> networking**: the NIC/address model and IPAM allocation exist, agents can
> wire a NIC into the jail, and the guest configures it — but the NIC stays
> off the wire — see
> [Guest networking](#guest-networking-the-holding-pattern).
> [History](#history) maps the build-out; issue numbers throughout mark which
> change delivered each piece.

## Lifecycle and data model

### Workload shape

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
  (#416). The NIC is modeled, IPAM-allocated, attachable into the jail, and
  configurable by the guest — but not yet on the wire spec — see
  [Guest networking](#guest-networking-the-holding-pattern).
- **No** volumes, firmware, boot source, or hypervisor choice — sandboxes are
  Firecracker-only, with no attachable storage.

### Model and API

- `Sandbox` model (`control-plane/Sources/App/Models/Sandbox.swift`) with the
  same desired/observed generation split as VMs, plus sandbox-only fields:
  the OCI ref and resolved digest, entrypoint/cmd/env/workdir overrides,
  `ttl_seconds` (enforced by the expiry sweep — see
  [Quotas, TTL, and expiry](#quotas-ttl-and-expiry)), and the reported exit
  code (#413).
- `/api/sandboxes` (`SandboxController`): list/create/show/update/delete +
  start/stop/restart + status + operations. Mutations write the desired-state
  change plus an append-only `resource_events` row in one transaction and
  return **202 Accepted** with `{resource, targetGeneration, mutationId}`; the
  client refetches the sandbox and reads its `conditions` (ADR 0001 stage 4,
  STR-147). Restart is expressed as a fresh desired-`running` generation (there
  is no sandbox reboot nonce — unlike a VM's, whose reboot became one in
  STR-151); the runtime (#421) interprets it agent-side.
- `sandbox` is an IAM node type of its own: the same action families as
  `virtual_machine` minus console/pause/promote, plus `exec`.
  `AuthorizationMiddleware` guards `/api/sandboxes` through the same
  route-prefix → resource-type mapping as VMs, with the sandbox action verbs
  (`start`, `stop`, `restart`, `exec`).
- Creation runs the quota admission check in the create transaction (see
  [Quotas, TTL, and expiry](#quotas-ttl-and-expiry)) and places onto an agent
  that advertised the sandbox runtime (#415; see
  [Protocol versioning and placement gating](#protocol-versioning-and-placement-gating)).
  Placement rides the same `filterEligibleAgents` pipeline and Valkey
  placement reservations as VMs; the reservation releases on the same
  triggers (send failure, the agent's observed-state reports accounting for
  the sandbox, deletion confirmation, TTL backstop).
- Sandboxes reference images by OCI ref only — they do not use the
  `Image`/`ImageArtifact` model at all.

### Riding the reconciliation loop

Sandboxes reuse the level-triggered desired-state sync rather than growing a
parallel imperative path (see [overview](./overview.md) for the loop itself):

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
  started" — it ran to completion; there is no restart policy, so the
  reconciler must not relaunch one-shot workloads forever) and desired
  `stopped` (equally not-running). Exit-code surfacing to the API and richer
  lifecycle handling landed with #423.
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
**fresh at every sync assembly**, so a long-lived desired entry never holds an
expired secret. The
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

### Protocol versioning and placement gating

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
  contain the runtime driver (`SandboxRuntimeProbe.runtimeBuilt` — true now
  that #421's runtime ships; a runtime-less agent would silently ignore
  desired sandboxes), Firecracker must be usable (binary + KVM, from the hypervisor
  probe), **and** the sandbox guest base image (#419) must be present at
  `sandbox_guest_image_path` (default `/var/lib/strato/sandbox/guest`) — so
  the capability lights up exactly when a runtime-carrying agent has the
  artifacts installed on a capable host.

## Agent runtime

The agent side is all native Swift, extending the vendored
`SwiftFirecracker/` package and the agent's existing Firecracker machinery.
**firecracker-containerd was considered and rejected**: it brings a Go daemon
and a devmapper thin-pool host dependency, and fits poorly with the Swift
agent's driver registry, manifest, and reconciler. OCI pull/unpack, image
caching, and vsock guest control (#420 grew SwiftFirecracker the vsock device
support) are built natively in the agent instead.

The driver is `FirecrackerSandboxRuntime`
(`agent/Sources/StratoAgent/FirecrackerSandboxRuntime.swift`, #421), behind
the `SandboxRuntimeService` seam
(`StratoAgentCore/SandboxRuntimeProtocol.swift`), registered in the agent's
driver registry and manifest like any other backend, including orphan
adoption after agent restarts. The reconciler and manifest are generalized
over workload kinds (#417): the diff engine, generation guard, attempt cap,
and per-workload serial lanes are shared across kinds — VM items route to
hypervisor drivers, sandbox items to the `SandboxRuntimeService` seam,
populated with `FirecrackerSandboxRuntime` on capable Linux hosts (nil only
on hosts that cannot run sandboxes, which keeps the capability off there) —
and manifest entries carry a workload kind so sandbox orphans survive
restarts with their resources reserved.

### From OCI image to rootfs

`SandboxImageService` in `agent/Sources/StratoAgentCore/OCI/` (#418) turns a
`SandboxSpec` image reference into a bootable ext4 rootfs. The distribution
client mirrors the control plane's auth flow (anonymous/Basic/Bearer
challenges, plus presenting control-plane-minted bearer tokens directly),
narrows multi-platform indexes to the host's `CPUArchitecture`, verifies
every manifest and blob against its digest, and retries transient failures
the way `ImageCacheService` does. Layers (tar, tar+gzip, tar+zstd) are
flattened with OCI whiteout handling and traversal-safe unpacking, then
`mkfs.ext4 -d` builds the image sized to content plus configurable headroom,
staged and published atomically.

The cache is **content-addressed by platform manifest digest** (with
index→platform alias files so digest-pinned sandboxes hit it offline) and
evicted after each materialization: entries idle past a 7-day TTL, plus —
when `sandbox_image_cache_max_size_gb` is set — least-recently-used entries
beyond the size budget (recently used entries are grace-protected). Only
flattened images are cached (no layer-level dedup/snapshotter). The image
config's execution parameters (entrypoint/cmd/env/workdir/user) are staged as
`config.json` beside `rootfs.ext4` — the rootfs stays a pristine container
filesystem; the config travels into the guest on the config drive described
below. Host prerequisites: gzip (and zstd for zstd layers) and e2fsprogs;
sync-delivered registry credentials are used per pull and never persisted.

### Guest image and boot

The guest base image (#419) is what turns a booted microVM into a running
container workload. It lives in
[`sandbox-guest/`](https://github.com/samcat116/strato/tree/main/sandbox-guest)
and ships two artifacts per architecture — an uncompressed Firecracker kernel
(`vmlinux-<arch>`) and a gzipped-cpio initramfs (`initramfs-<arch>.cpio.gz`)
holding a single static PID-1 init, `strato-sandbox-init`. The init applies
the OCI config (entrypoint/cmd/env/workdir), runs the workload, reaps
zombies, and reports its exit over vsock — written with the snapshot
lifecycle (drain, re-listen, re-identify) in mind from the start.

**Rootfs: initramfs + pivot onto a pristine drive.** The init boots from the
initramfs and `switch_root`s (the initramfs-correct form of `pivot_root`) onto
the flattened container rootfs (#418), which the runtime attaches as a
**separate block device** (default `/dev/vda`). The container image is never
mutated by init injection — the materialized rootfs stays a pristine container
filesystem, which was the deciding constraint. `SwiftFirecracker`'s `BootSource`
already carries an `initrd_path`, and `Drive` already supports the extra drive,
so no host-side model change was needed.

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
sandbox identity + vsock port, the OCI **image config plus the sandbox
overrides** — the guest performs the OCI merge (entrypoint/cmd/env/workdir/user,
Docker-compatible rules), so those runtime semantics live in exactly one place —
and, at schema v2, the NIC's static L3 configuration (STR-101, see
[Guest networking](#guest-networking-the-holding-pattern)). This keeps the
container image pristine and lets the workload launch without waiting on the
host to connect vsock. The host stamps the **minimum schema version the
document needs** and the guest refuses anything past what it understands, so a
guest image older than its agent keeps booting the drives it fully understands
and fails loudly only on one carrying something it would otherwise ignore.

**vsock control surface.** The init serves newline-delimited JSON on a guest
vsock port (default 1024). The v1 surface is health + exit only: `ping` →
`pong`, and `get_status` → the workload's lifecycle state and, once it ends,
its exit code. Every response echoes `sandbox_id` + boot `nonce` so the host
can re-identify a guest after a snapshot/resume. The surface has grown twice
since: protocol v2 added the exec and log-follow stream modes (#423 — see
[Exec, attach, and workload logs](#exec-attach-and-workload-logs)), and the
snapshot era added `sync_clock`, the warm-start `launch` request and `held`
state, the fork `reidentify` request, and a versioned `pong` — guests
advertise their control-protocol version, and fork admission keys on v3 (see
[Snapshots](#snapshots-warm-start-fork-and-mobility)).

**On-disk layout & capability gating.** The two artifacts install as a directory
at `sandbox_guest_image_path` (default `/var/lib/strato/sandbox/guest`)
alongside a `guest.json` manifest (schema version, image version, per-arch
checksums + default boot args). `StratoAgentCore/SandboxGuestImage` is the
resolver that reads that layout into concrete kernel/initramfs paths for the
host arch — the shared contract the sandbox runtime consumes so filenames are
not hard-coded at the call site. `SandboxRuntimeProbe` only asserts the
path's presence (it must stay cheap and never fail a capability check on a parse
error); presence + a usable Firecracker is what lights up the `sandbox_runtime`
capability. The build/publish pipeline (`.github/workflows/sandbox-guest.yaml`)
builds both arches on a release tag and uploads the tarballs + `.sha256`
sidecars + a `sandbox-guest-manifest.json`, mirroring the agent release flow;
`task install-sandbox-guest` / `deploy/agent/install.sh --sandbox-guest` install
onto a host.

### Jailer hardening

Sandboxes run **untrusted** workloads by definition, so their VMM processes
get a hardening barrier VMs (operator-trusted workloads) don't: Firecracker's
own [jailer](https://github.com/firecracker-microvm/firecracker/blob/main/docs/jailer.md)
(#425). `SwiftFirecracker` grew `JailerOptions` and jail-aware spawn/adopt/destroy
in `FirecrackerClient`; the runtime derives everything per sandbox from a pure
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
  prefix. Snapshot files follow the same rule: staged into, and
  loaded from, in-jail paths. Teardown removes the whole jail subtree.
- **Privilege drop**: each sandbox runs as its own uid/gid, derived
  statelessly as `sandbox_jailer_uid_base + (FNV-1a-64(sandboxId) % 65536)` —
  stable across restarts, no allocation state. Writable artifacts are chowned
  to it; a slot collision between two sandboxes (rare at 2^16) weakens only
  their mutual isolation, never the host boundary.
- **Network namespace**: every jailed sandbox gets a dedicated netns
  (`strato-sbx-<id>`, created with `ip netns add`) which the jailer enters via
  `--netns` — a compromised VMM sees no host interfaces at all. A network-free
  sandbox's namespace stays empty; a sandbox **with** a NIC gets it wired in
  before the VMM is spawned, by the network orchestrator on the reconcile lane
  (STR-100). The wiring recipe — and why the TAP is created inside the
  namespace rather than moved in (the measured STR-99 failure) — is owned by
  [Sandbox NICs](./networking.md#sandbox-nics); the jail-specific detail is
  that the TAP is created owned by the sandbox's derived uid, because the
  jailer drops `CAP_NET_ADMIN` before Firecracker's `TUNSETIFF`.
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

## Exec, attach, and workload logs

What makes sandboxes feel like sandboxes: getting into them and seeing their
output (#423). Wire protocol **v8**.

### Guest control protocol v2

The guest agent's vsock surface (port 1024, newline-delimited JSON both ways)
grows beyond `ping`/`get_status`. The accept loop is thread-per-connection
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

**What the host will accept.** Guest→host lines are hostile input by
definition — a trap in the host parser aborts the agent and takes every VM on
the node with it, not just one tenant's session — so `GuestControlProtocol`
(agent-side) is a total function over them: every response either lands inside
these bounds or throws, closing the connection. The walls, all far outside
what the in-repo guest produces (it reads workload and exec output in 8 KiB
chunks), live in `GuestControlProtocol.Limits`:

| Bound | Value | Applies to |
| --- | --- | --- |
| Line length | 1 MiB | every response line; matches the transport's line framer, which fails the channel rather than accumulating an unterminated line |
| Decoded stdio payload | 64 KiB | `output`/`log` `data` (checked on the base64 text first, so an oversized chunk is never materialized) |
| Identity fields | 256 B | `sandbox_id`, `nonce` |
| `error` message | 4 KiB | **truncated with a marker**, not rejected — it is purely diagnostic, and throwing would discard the guest's actual complaint |
| `seq` | 2^53 | `log` records; keeps the host's `lastSeq + 1` resume arithmetic clear of overflow |
| `stream` | `stdout` \| `stderr` only | `output`/`log`; the host buffers a partial line per stream *name*, so arbitrary labels would grow host memory without bound |
| `exit_code` | `i32` range | `exec_exit`, `status` |
| `control_protocol_version` | `u32` range | `pong` |

A future guest that wants to stream larger records has to move these
deliberately, on both sides. Note that a *valid* `seq` near its ceiling still
pins that sandbox's follow resume point permanently (the guest only replays
`seq >= since_seq`); it is self-inflicted and silent, and a plausibility check
on per-record seq advance is the outstanding fix.

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

### Control-plane surface

- `POST /api/sandboxes/:id/exec` — guarded by the `exec` permission (an
  `actionVerbs` entry in `AuthorizationMiddleware`, plus the in-handler check).
  Requires the sandbox running, placed, its agent socketed to **this replica**,
  and the agent at protocol ≥ 8. Returns `201 {sessionId, websocketPath,
  expiresAt}`; pending sessions expire unattached after 60s.
- `GET /api/sandboxes/:id/exec/:sessionId/attach` — WebSocket upgrade,
  modeled on the VM console tunnel (in-handler `exec` re-check through the
  evaluator, same-user binding to the pending session). Browser→CP: binary frames are
  stdin, text frames carry JSON `resize`. CP→browser: binary frames are
  output; text frames carry JSON `ready`/`exit`/`error` controls.

Like the VM console, exec is **single-replica**: the browser WebSocket must
land on the replica holding the agent socket (`SandboxExecSessionManager`
mirrors `ConsoleSessionManager` and does not forward over the coordination
RPC channels). Cross-replica stream forwarding is future work for both
tunnels; the POST fails fast with 503 when the agent is socketed elsewhere.

The frontend's sandbox detail page has Terminal and Logs tabs mirroring the
VM page — the terminal drives exec sessions (default `/bin/sh`, PTY, resize
wired to xterm's fit addon), and the logs tab tails the Loki-backed endpoint.

## Snapshots, warm start, fork, and mobility

Firecracker snapshots capture the guest **memory + VMM/device state** of a
*paused* microVM — not the disk — and are tied to the Firecracker version,
host CPU, and device topology they were taken with (#426). A Strato sandbox
checkpoint is therefore three artifacts taken as one consistent point in
time, plus recorded compatibility constraints:

- `memory.snap` + `vmstate.snap` — written by `PUT /snapshot/create` (full
  snapshots; `track_dirty_pages`/diff snapshots are wrapped in
  SwiftFirecracker but unused — see [Open threads](#open-threads)).
- `rootfs.ext4` — a copy of the writable rootfs made **while the guest is
  paused**, via `cp --reflink=auto` (a free clone on reflink filesystems —
  btrfs/XFS today, the ZFS pool backend (#350) later — and a full copy
  otherwise). The tiny `config.img` rides along so a jailed restore can
  re-stage its chroot from the archive alone.

### Checkpoint and restore in place

**Checkpoint** (a desired artifact since wire v33): drain host-side vsock connections
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

**Restore in place** (`DesiredSandboxState.restore`, same identity): drain →
destroy the current Firecracker process → re-stage the layout from the
archive (for a jailed sandbox the whole chroot is rebuilt; kernel/initramfs
are deliberately absent — a snapshot load never reads the boot source) →
spawn a fresh process → `PUT /snapshot/load` (`resume_vm: true`) → guest-agent
health check (ping + identity nonce, which the checkpointed memory carries) →
best-effort `sync_clock` over vsock (the restored guest's wall clock froze at
checkpoint time; PID 1 sets `CLOCK_REALTIME`) → log follow resumes from its
seq checkpoint. The restored device topology re-binds the original vsock UDS
path; the (future — STR-104) TAP devices come back under their original names
the same way.

### Snapshot rows and convergence

`SandboxSnapshot` rows track status (`creating`/`ready`/`deleting`/`error`),
size, agent placement, and the compat constraints (Firecracker version,
architecture, guest control-protocol version, fork layout, CPU template).

A snapshot is a **desired artifact** since ADR 0001 stage 8 (STR-150, wire
v33): capture, delete and export are desired state the owning agent converges
on, and the row is a `ConvergingResource` with its own generation and
finalizer. `POST /api/sandboxes/:id/snapshots` and `DELETE` answer `202
{resource, targetGeneration, mutationId}`; the client polls the snapshot's
`conditions`. The delete's row survives until the agent's full-list report
omits the artifact. See
[the storage doc](./storage.md#snapshots-and-checkpoints-as-desired-artifacts)
for the shared shape, including retention.

Two sandbox-specific details. **Checkpoint-and-stop writes two halves in one
transaction**: `captureMode: .stop` on the artifact — read by the agent only
while the artifact is absent, so a replayed sync cannot re-pause a live guest —
and `desiredStatus: .stopped` on the sandbox itself, without which "and stop"
would last exactly until the next level-triggered pass. And the source host's
**CPU model** is recorded at admission rather than waited for: it is a fact
about the *agent*, which the agent's own report has no reason to carry, and an
un-templated snapshot needs it to be mobile at all.

`restore` is an **edge-nonce** on the sandbox's desired entry (wire v34, ADR
stage 9, STR-151). Loading a checkpoint back over a live microVM is genuinely an
edge rather than a state, so it became one by being counted:
`DesiredSandboxState.restore` carries a monotonic generation and the snapshot to
load, and the agent applies it once against the record it keeps in its own
durable manifest — a dropped or replayed sync converges rather than rewinding
the guest twice. It is refused with `409` when the sandbox's agent predates v34,
since such an agent would ignore the field and report the bumped generation as
converged. Restore pins to the snapshot's agent — until the snapshot is exported (see
[Snapshot mobility](#snapshot-mobility)) — and flips desired state to
`running` in the same transaction (IPAM allocations stay held while
checkpointed, so the sandbox keeps its addresses). Snapshot storage draws
from the shared storage quota pool (#415): admission reserves the
guest-memory size as an estimate, the agent's reported actual sizes replace
it, and quota resync sums non-error snapshot rows.

### Warm start

Warm start (#426, folded in from #425) turns sandbox creation from "boot a
guest" into "restore a snapshot": the agent boots one throwaway **template**
microVM per (image, guest version, Firecracker build, machine shape) to the
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
vsock listener — but parks in the `held` state instead of resolving and
spawning a workload. That point is deliberately **before any per-sandbox
identity is consumed**: no workload argv/env, no network identity (a template
is shared across sandboxes, so it carries no NIC at all — see
[Guest networking](#guest-networking-the-holding-pattern)), nothing but the
template's own throwaway nonce in memory. This is the "snapshot before
identity" sidestep the issue calls out: it keeps most of the fork-identity
problem (#427) off the table.

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
then sends `sync_clock` and the `launch` control request — carrying the
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

### Fork into a new sandbox

`POST /api/sandboxes` accepts `restoreFrom: <snapshot UUID>` instead of an
image (#427). The caller needs `read` on the source `sandbox_snapshot` and
`create_resources` on the target project. Machine and process overrides are
rejected: the fork preserves the checkpointed image, vCPU/memory shape, and
process configuration, while the target supplies its own name, project,
environment, and TTL. `sandboxes.restored_from_snapshot_id` records lineage;
the API and web detail page expose it, and the snapshot list offers the fork
action.

Snapshot artifacts start agent-local, so scheduling pins to the snapshot's
`agent_id` (wire protocol **version 12**) until the snapshot is exported —
then any compatible agent is a candidate (see
[Snapshot mobility](#snapshot-mobility)). The agent
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
MAC, and IPAM reservation — though, like every sandbox NIC, it stays off the
wire, and snapshots of networked sandboxes are their own open thread (see
[Guest networking](#guest-networking-the-holding-pattern)).

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

### Snapshot mobility

Export makes a checkpoint durable and portable (#428):
`POST /api/sandboxes/:id/snapshots/:snapshotId/export` (202, wire protocol
**version 14** for the transfer client and **v33** for the entry) records that
the snapshot's artifacts should *also* exist in project storage. A **placement
fact**, not a verb, since STR-150: the desired entry carries one upload slot
per artifact, the agent converges by streaming to them, and the snapshot's
`conditions` stay unconverged until the copy is complete. Withdrawing an export
plans nothing on the agent — un-exporting is the control plane's own
object-store bookkeeping.

Bytes flow through the control plane into the image object store
(`ImageObjectStore`, filesystem or S3) under
`sandbox-snapshots/{projectId}/{snapshotId}/...` — agents never talk to the
store directly, mirroring image downloads. The transfer routes authenticate
the agent's SPIFFE SVID forwarded by the Envoy mTLS sidecar
(`AgentMTLSAuthenticator`, the v13 image-download model; both Envoy configs
add an agents-only RBAC route for them), with deliberately no user-session
fallback. The upload route hashes and sizes each stream as it lands
(integrity material is never agent-supplied), records per-artifact entries on
the snapshot row, and stamps `exported_at` on the PUT that completes the set.
The agent saying "I finished uploading" is deliberately never what stamps it:
only a copy this route hashed itself may authorize a cross-agent restore. An
existing `exported_at` is left alone by a re-upload, so a re-export that dies
partway cannot demote a snapshot whose stored copy is still complete and valid.
Deleting the snapshot (or cascading its sandbox) deletes the exported prefix.

An exported snapshot unlocks:

- **Cross-agent restore** — `.../restore` no longer requires the sandbox to
  sit on the snapshot's agent. The target must satisfy the recorded compat
  constraints (`SandboxSnapshotCompatibility`): wire v14, same architecture,
  the **same Firecracker version** (probed from `firecracker --version` at
  registration and carried on `HypervisorSupport.version`), and a matching
  guest CPU surface — either the snapshot records a CPU template, or the
  source and target hosts report identical CPU models. Missing information
  is always incompatible.
- **Cross-agent fork** — fork placement widens from the pinned agent to
  every compatible agent, and survives losing the snapshot's home agent
  entirely. Sync assembly injects checksummed download descriptors into
  `restoreFrom` (relative paths the agent fetches over SVID mTLS); the restore
  nonce carries the same descriptors, minted at assembly rather than stored so a
  nonce that waits in the desired state never goes stale. The target agent stages the
  archive into an LRU-swept import cache
  (`<sandbox storage>/snapshot-imports/`, sharing the warm-cache byte
  budget), verifying each artifact's size and SHA-256 before the atomic
  publish; concurrent forks of one snapshot on a host share a single
  download.

**CPU templates** are the mobility keystone: `POST /api/sandboxes` accepts
`cpuTemplate` (validated against Firecracker's static templates — C3/T2/
T2S/T2CL/T2A on x86_64, V1N1 on aarch64), applied at boot and thereby baked
into every checkpoint. The decision is deliberately create-time-only — a
template can never be applied at restore time, and an un-templated snapshot
only restores on identical CPU models. Templated creates are gated on v14
agents (an older agent would silently boot passthrough); the template is
part of the warm-snapshot cache key.

## Guest networking: the holding pattern

A sandbox models **at most one NIC** on a `LogicalNetwork`, reusing the VM
`NetworkSpec` (#416) so agents realize it through the same OVN paths as VM
NICs. The interface row, MAC, and IPAM allocation are created at sandbox
create, so the address is reserved and stable from day one. Agent-side the
attach path exists too: STR-100 wires a veth + TAP into the jail's network
namespace and binds it to OVN before the VMM is spawned. The mechanics — the
tc-redirect-tap topology, why the TAP is created inside the namespace rather
than moved in (the measured STR-99 failure), teardown, MTU, and host
requirements — are owned by [Sandbox NICs](./networking.md#sandbox-nics) in
the networking doc; this section owns the sandbox-side status.

**The guest configures its own NIC** (STR-101). The config drive grew a
`network` block at schema v2 — MAC, per-family address/prefix/gateway, MTU,
resolvers, search domain, hostname — and the init applies it: `lo` up (for
every sandbox, networked or not), the NIC matched **by MAC**, addressed,
routed, and `/etc/resolv.conf` + `/etc/hosts` written into the rootfs before
the switch. Three decisions worth keeping:

- **Static, not DHCP.** The control plane's IPAM knows the address before the
  microVM boots, so a DHCP exchange would spend a cold-start round trip — and
  a client binary in a size-optimized initramfs — rediscovering it. OVN's
  responder stays programmed for the port, so an image that runs its own
  client keeps working; the guest just must not depend on one.
- **Fatal on failure.** A half-configured interface is indistinguishable from
  a healthy one host-side, so the init powers the microVM off rather than let
  a sandbox report `running` with a dead NIC. The resolver files are the
  exception (best effort — a read-only rootfs is legitimate), and `/etc` is
  created rather than assumed for scratch/distroless images.
- **The schema version stamps what the document needs, not what the host
  knows.** A network-free drive is stamped v1 even by an agent that can write
  v2, and the guest accepts `1...SCHEMA_VERSION` — so a node whose
  separately-distributed guest image lags the agent keeps booting sandboxes
  whose drives carry nothing new. A drive with a `network` block is stamped
  v2 and an older guest refuses it, loudly, rather than booting a sandbox
  whose NIC it would ignore in silence. The strictness bites exactly where it
  buys something.

**Not on the config drive: metadata routes.** A VM's static guest gets
explicit routes to the instance-metadata addresses from its cloud-init seed,
and a DHCP guest gets the v4 half via option 121 (STR-53). A sandbox guest is
static *and* runs no DHCP client, so it gets neither — `metadataEnabled` is
carried on the NIC's spec but ignored when the guest's network block is built.
Instance metadata for sandboxes is unimplemented rather than deliberately
excluded; delivering it means a `routes` field on the block, and it belongs
with whichever arm picks up sandbox metadata rather than with the interface
bring-up.

**The NIC still does not go on the wire.**
`SandboxSpecBuilder.guestNetworkingSupported` is `false` (#524), so no
sandbox `NetworkSpec` reaches an agent, for one remaining reason:

- **The flag is fleet-wide while the capability is per-agent** (STR-103): an
  unjailed, non-Linux, or older agent cannot realize a sandbox NIC and would
  fail every placement. STR-103 replaces the flag with a per-agent gate and
  is what flips it.

Two more arms are queued behind those:

- **Security groups** (STR-34): the NIC joins the project's default group —
  or the groups named in `securityGroupIds` — through
  `sandbox_interface_security_groups`, and attach/detach accept a
  `sandboxId`, but the membership filters nothing yet: STR-102 grows the
  sync's membership assembly a sandbox arm, and until then a sandbox port
  would come up in no port groups at all — not even the drop group — which
  is part of why the wire gate stays shut. Details in
  [Security groups](./networking.md#security-groups).
- **Snapshots of networked sandboxes** (STR-104): current checkpoints
  contain no Firecracker network device to remap, so restore and fork
  refuse networked sandboxes until STR-104 passes Firecracker
  `network_overrides` on load and reconfigures the guest interface/DHCP
  lease before health succeeds.

## Quotas, TTL, and expiry

**Quota accounting** (#415): sandbox vCPUs and memory draw from the *same*
`ResourceQuota` pools as VMs — `calculateActualUsage` and the reservation
resync sum both workload kinds — while the count limit is a separate
`max_sandboxes`/`sandbox_count` pair (backfilled from `max_vms`), so
sandboxes never silently consume VM slots. Reservation happens in the create
transaction (`QuotaEnforcementService.reserveSandbox`) and releases when the
row is removed (deletion confirmed by agent report, or direct deletion for
unplaced/agent-offline sandboxes). Sandboxes reserve no storage — though
snapshots do, from the shared storage pool (see
[Snapshot rows and operations](#snapshot-rows-and-operations)).

**TTL and auto-expiry** (#424): sandboxes are ephemeral, and
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

## History

Sandboxes were designed and built as a phased roadmap under umbrella issue
#410; older issues and PRs still speak in phase numbers, so here is the map:

- **Phase 1 — model to runtime**: the wire protocol (v5, #411), the
  generalized operation machinery (#412), the control-plane model/API (#413),
  registry pull secrets + tag→digest resolution (#414), scheduler gating +
  quota accounting (#415), the NIC/address model + IPAM integration (#416),
  the workload-kind generalization of the reconciler and manifest (#417), the
  OCI client + rootfs materialization (#418), the guest base image (#419),
  vsock support in SwiftFirecracker (#420), the `FirecrackerSandboxRuntime`
  driver (#421), and the frontend UI (#422).
- **Phase 2 — exec/attach, logs, expiry**: exec/attach + workload logs and
  guest control protocol v2 (#423, wire v8); TTL / auto-expiry (#424).
- **Phase 3 — jailer hardening** (#425): the chroot/uid/netns/cgroup barrier
  around untrusted VMMs.
- **Phase 4 — snapshots**: checkpoint/restore primitives and warm start
  (#426, warm start folded in from #425's plan; wire v9), fork into a new
  sandbox (#427, wire v12), and export + cross-agent mobility with CPU
  templates (#428, wire v14).

Guest networking was deliberately scoped out — #524 kept the NIC off the wire
spec — and re-planned as STR-99..104: the measured move-a-TAP failure
(STR-99), the netns attach path (STR-100), and the in-guest network config
(STR-101, config-drive schema v2) are landed; security-group membership
assembly (STR-102), the per-agent gate that flips the wire flag (STR-103),
and networked-snapshot remapping (STR-104) remain — see
[Guest networking](#guest-networking-the-holding-pattern).

### Open threads

- The warm-vs-cold boot-latency measurement on strato-dev (the
  `bootPath=warm|cold` / `bootMillis` boot logs are the measurement hook).
- Diff snapshots via `track_dirty_pages` (wrapped in SwiftFirecracker, still
  unused) plus a periodic auto-checkpoint policy; uffd lazy-load restore for
  fork latency; snapshot retention policies beyond delete-time cleanup
  (#428).
- **Guest identity** (#496, design in [guest-identity](./guest-identity.md)):
  a SPIFFE Workload API socket inside the sandbox, served by strato-agent
  over a v4 control-protocol identity port. Sandboxes are the ready half of
  that proposal — vsock and an in-house PID 1 are already here — and the
  fork case composes with the clone-safety policy, because identity arrives
  over a live channel rather than baked into the config drive.
- Guest networking, STR-102..104 — see
  [Guest networking](#guest-networking-the-holding-pattern).

## Non-goals

- Layer-level dedup or a snapshotter — the image cache holds flattened
  images only.
- Pre-booted warm pools — warm start restores per-image template snapshots
  instead.
- Volumes, disk hot-plug, or live migration for sandboxes.
- macOS agents — Firecracker is Linux/KVM-only; capability gating keeps them
  out of placement.
