# Agent Code Architecture

The agent is the Swift service that runs on every hypervisor node: it
connects out to the control plane over a WebSocket, converges on the desired
state it receives, and drives VMs and sandboxes through hypervisor drivers.
This page maps the code under `agent/` (plus the vendored `SwiftFirecracker/`
package) for contributors; the protocol it speaks is documented in
[wire-protocol](./wire-protocol.md).

## Target split

`agent/Package.swift` defines four targets, split around one constraint —
SwiftPM cannot unit-test an executable target:

- **`StratoAgentCore`** (library) — the testable core. Depends only on
  `StratoShared`, Logging, Toml, and Crypto — deliberately **no SwiftQEMU,
  SwiftFirecracker, or SwiftOVN** — so the reconcile engine, config parsing,
  storage backend, OCI pipeline, manifest store, and updater are all unit
  tests away from any hypervisor.
- **`StratoAgentSPIFFE`** (library) — SPIFFE/SPIRE support (SVID types, TLS
  config, Workload API client), split out so tests can import it.
- **`StratoAgent`** (executable) — the binary and everything touching native
  libraries: the `Agent` actor, `QEMUService`, `FirecrackerService`,
  `FirecrackerSandboxRuntime`, the platform network services, and
  `WebSocketClient`. SwiftOVN and SwiftFirecracker link only on Linux (but
  are declared unconditionally so `Package.resolved` is identical on every
  host; imports are `#if os(Linux)`-guarded).
- **`StratoAgentTests`** — imports Core + SPIFFE. The executable has no
  direct tests; anything worth testing gets pushed down into Core.

## Startup, registration, reconnect

`StratoAgent.swift` is an ArgumentParser `@main` whose `run` subcommand (the
default) funnels into `launchAgent`.

- **Config**: TOML (`AgentConfig` in `StratoAgentCore/AgentConfig.swift`),
  resolved field-by-field with precedence **CLI flag > config file >
  platform default**. Default path is `/etc/strato/config.toml` on Linux,
  falling back to `./config.toml`. Enum-valued fields (network mode,
  hypervisor type, jailer mode) are validated at load.
- **Which URL to dial** (helpers in `StratoAgentCore/WebSocketURLs.swift`):
  the configured `control_plane_url`
  with the agent's name appended as a `?name=` query parameter. There is no
  bearer credential in the URL or in a header — every connection is
  authenticated by the client certificate alone.
- **Identity**: the agent's X.509 SVID, fetched from the SPIRE Workload API
  (or from PEM files, per the `[spiffe]` config block) by
  `StratoAgentSPIFFE` and presented as the mTLS client certificate. SVIDs
  rotate underneath the agent, so a long-lived fleet needs no credential
  bookkeeping; a node that loses its SPIRE registration simply stops being
  able to connect. The agent persists no credential state at all — its name
  comes from `--agent-id` (defaulting to the hostname) and its identity from
  SPIRE, so there is nothing on disk to rotate, corrupt, or leak.
- **Server identity is pinned, not just chain-verified**: every workload in
  the trust domain holds a bundle-signed SVID, so "chains to the bundle"
  would accept a compromised workload impersonating the control plane. The
  agent instead pins the control plane's SPIFFE ID
  (`[spiffe] control_plane_spiffe_id`, defaulting to
  `spiffe://<trust_domain>/control-plane` — what both supported deployments
  provision for Envoy) and verifies it against the leaf certificate's URI SAN
  in a custom TLS verification callback. websocket-kit cannot carry that
  callback, so `SPIFFEWebSocketConnector` builds the client pipeline itself
  (`NIOSSLClientHandler` → HTTP upgrade → hand-off to websocket-kit); the
  shared `SPIFFEVerification` target holds the verifier, which the control
  plane also uses to pin the SPIRE server's identity. See issue #552.
- **`WebSocketClient`** (actor, executable target): WebSocketKit with a
  16 MiB max frame (the desired-state sync is one frame; must match the
  control plane), inbound frames decoded and yielded into an `AsyncStream`
  to preserve arrival order, and a connection-scoped 20s heartbeat.
  Connection loss triggers `Agent.runReconnectLoop`: exponential backoff
  (1s → 30s cap, with jitter), re-registering on success; a
  registration-rejected error is terminal (the node's SPIRE identity is no
  longer accepted — re-enroll it).

## Shutdown

**VMs outlive the agent.** A SIGINT/SIGTERM runs `Agent.stop()` —
unregistering from the control plane, closing the socket and its event loop,
closing console channels, disconnecting networking, stopping the SVID manager
— but it deliberately does not touch running hypervisor processes. The
manifest keeps them, and the next incarnation re-adopts them (see
[Storage](#storage)). This is why the systemd unit must set
`KillMode=process`: QEMU and Firecracker are children of the agent and share
its cgroup, so systemd's default would kill every VM on the host on any
restart.

Shutdown is bounded on both ends. `launchAgent` exits the process explicitly
once `stop()` returns rather than letting the runtime unwind, and a watchdog
armed by the signal handler exits anyway if the process has not gone away
within 20s of the signal.
Before that, a completed shutdown could leave the process alive on some
straggling thread until systemd's `TimeoutStopSec` SIGKILLed it — taking every
VM in the cgroup with it (issue #522).

## Hypervisor driver registry

`HypervisorProtocol.swift` defines `protocol HypervisorService: Actor` —
create/boot/shutdown/reboot/pause/resume/delete, status/info queries,
console endpoints, disk hot-(de)attach, `reservedResources()`, and an
opt-in `adoptVM` for orphan re-adoption.

The registry is a dictionary on the `Agent` actor keyed by
`HypervisorType`, populated once at `start()`. That dictionary and
`getHypervisorService(for:)` are the **only** places message handling
touches concrete drivers — adding a backend is one registration line plus
the enum case, not new switch sites. An unregistered type returns nil, so a
host cleanly rejects placements it can't serve.

- **`QEMUService`** (`.qemu`): Linux KVM / macOS HVF via SwiftQEMU.
  Materializes boot disks through the storage backend, wires serial/console
  sockets, and re-adopts orphaned VMs over a deterministic QMP socket path.
- **`FirecrackerService`** (`.firecracker`, Linux only): translates the
  neutral spec into Firecracker API calls; requires direct-kernel boot and
  `.tap` network attachments. Shares one `FirecrackerClient` with the
  sandbox runtime, so VMs and sandboxes go through a single process
  registry and socket layout.
- **`MockHypervisorService`**: the no-op backend used as a build fallback
  and in simulation mode (one mock per hypervisor type). It tracks specs
  and status so reservations and reconciliation behave realistically.

## Firmware and the machine profile

`VMSpec.machine` (`MachineProfile`, wire v17) carries the two guest features
that are not resource sizing: Secure Boot and a TPM 2.0. Both default off, so
a spec that omits the field describes exactly the machine the agent built
before issue #565.

`StratoAgentCore/FirmwareResolver.swift` decides which EDK2 files a QEMU VM
boots with. It prefers the **split CODE/VARS pair** every distribution
actually ships, copying the VARS template into `nvram.fd` in the VM's own
directory and attaching both as pflash drives. The pre-#565 agent passed a
single blob as `-bios`, which runs firmware with no writable variable store:
UEFI boot entries the guest writes are silently discarded on the next
respawn — a bug Linux guests hit too — and Secure Boot keys can never be
enrolled at all. The monolithic `-bios` form survives as a fallback so hosts
(and operator configs) that only have a single image keep booting.

Candidates are matched as **pairs**, never as a cross product: OVMF's 4MB
build requires its own 4MB variable store, and pairing `OVMF_CODE_4M.fd` with
the 2MB `OVMF_VARS.fd` yields a firmware that fails to boot in a way that
looks like a corrupt guest image. Secure Boot narrows the candidate list to
the signed build (`OVMF_CODE_4M.secboot.fd` plus the pre-enrolled
`OVMF_VARS_4M.ms.fd`) and adds `q35,smm=on` with
`-global driver=cfi.pflash01,property=secure,value=on`; if no signed pair
resolves, the create **fails** rather than falling back to an unsigned build,
since booting without Secure Boot would quietly contradict what the API says
the VM has. macOS hosts ship no signed EDK2 build, so Secure Boot is a
Linux-hypervisor-node feature.

`StratoAgentCore/SwtpmSupervisor.swift` runs the vTPM: one `swtpm socket
--tpm2` process per VM, state in `<vmdir>/tpm`, control socket at
`<vmdir>/swtpm.sock`, pid file alongside it, attached to QEMU as
`-chardev socket,id=chrtpm,... -tpmdev emulator,id=tpm0,chardev=chrtpm
-device tpm-tis,tpmdev=tpm0` (`tpm-tis-device` on the ARM `virt` machine).
swtpm is spawned with `--daemon`, so it reparents to init and outlives the
agent exactly as QEMU does — a re-adopted VM keeps talking to the swtpm it was
started with. The converse does not hold: a swtpm that died under a live QEMU
cannot be reattached mid-flight and needs a VM stop/start. The state directory
persists across that, so anything the guest sealed to the TPM (BitLocker keys)
is not lost.

Whether the host has a usable `swtpm` is what the agent advertises as
`tpmCapable` at registration (plus a `vtpm` capability string), and the host
preflight reports its absence as an advisory — a host without swtpm is
perfectly useful, it just never receives a TPM placement.

## Guest provisioning (cloud-init)

`StratoAgentCore/CloudInitProvisioner.swift` generates the NoCloud seed ISO
QEMU disk-boot VMs consume (`meta-data`, `user-data`, and — when the control
plane allocated static addressing — a v2 `network-config`). Guest bootstrap
is deliberately per-backend: Firecracker VMs inject configuration through
kernel args instead and do not use this path.

The `user-data` document has two shapes:

- **No caller user data**: a single `#cloud-config` carrying Strato's
  provisioning — a serial-console password (dev convenience for SLIRP
  networks with no SSH route), GRUB/getty serial-console setup, and the
  VM's authorized SSH keys.
- **Caller user data present** (`VMSpec.userData`, any cloud-init format:
  `#cloud-config`, `#!` script, `#include`, jinja template): a
  `multipart/mixed` MIME document. The caller's payload is the **last**
  part — cloud-init's `CloudConfigPartHandler` merges parts with the
  default `dict(replace)+list()+str()` policy, replacing keys of prior
  parts, so on conflicting keys the caller wins and Strato's config acts
  as defaults (a caller's `ssh_pwauth: false` really disables password
  SSH auth). Strato's console setup travels as a `text/x-shellscript`
  part rather than `bootcmd`/`runcmd` keys, because those list keys in a
  caller part would replace Strato's — script parts always compose. The
  multipart boundary is extended until it appears in no part, so hostile
  payloads can't truncate a part.
- **Caller user data is itself a full MIME document**: used as the seed's
  `user-data` verbatim — the escape hatch for callers who want complete
  control (this skips Strato's console/password/SSH-key provisioning).

Both non-passthrough shapes also install and enable the **QEMU guest agent**
(issue #563) so stock cloud images gain verified shutdown, fs-freeze snapshots,
and guest IP reporting without image changes. The no-caller path uses cloud-init's
native `packages:` key; the multipart path installs it from a `text/x-shellscript`
part instead, because a caller cloud-config's own `packages:` list would replace
a merged key under cloud-init's `dict(replace)+list()` policy (the same reason
console setup travels as a script part).

## QEMU guest agent (qga)

`StratoAgentCore/QGA/` holds `QGAClient` (issue #563): a testable JSON-over-
unix-socket client for the guest agent, sitting in Core behind a `QGATransport`
seam so its framing and resync logic unit-test against an in-memory fake, with
`NIOQGATransport` the real unix-socket transport. Unlike QMP there is no
greeting or `qmp_capabilities` handshake — every operation opens a channel,
resynchronizes the stream with `guest-sync-delimited` (a `0xFF` marker frames
the reply so stale bytes are discarded, and its success is the guest-is-alive
proof), issues its command(s), and closes.

Every VM already carries a `virtio-serial-pci` bus for the console channel, so
`QEMUService.convertToQEMUConfiguration` just adds one more `virtserialport`
named `org.qemu.guest_agent.0` on a deterministic `<vmStoragePath>/<vmId>/qga.sock`
(so re-adopted VMs reconnect too). qga is **unresponsive whenever the guest is
not running the agent**, so every call is bounded by a short `StageBudget` and a
timeout is the *normal* path, not the error path — each use site degrades to
pre-qga behavior:

- **Verified shutdown**: `shutdownVM` tries `guest-shutdown` first; its success
  confirms the guest heard us, and it falls back to the universal ACPI powerdown
  when qga doesn't answer.
- **fs-freeze snapshots**: the volume-snapshot handler freezes the attached
  guest's filesystems (named by the control plane's `attachedVMId`) around
  overlay creation and always thaws afterward, under a hard time cap — a frozen
  guest is worse than a crash-consistent snapshot. A detached volume or qga-less
  guest just gets the crash-consistent snapshot.
- **Guest info**: a throttled slow poll (folded into the heartbeat cadence)
  probes running QEMU VMs for hostname and configured addresses off the report's
  hot path, caching the result the observed-state report reads. This is the only
  way DHCP/SLAAC addresses the control plane never allocated become visible.

## Balloon memory stats (virtio-balloon)

Every QEMU VM gets a `virtio-balloon-pci` device with `free-page-hint=on`
(issue #567): inert until the guest's virtio_balloon driver binds it, after
which free-page hinting lets KVM drop guest-freed pages (shrinking host RSS
with no policy work) and the device's `guest-stats` expose real guest memory
usage.

Stats travel over QMP (`qom-set` to enable guest-stats polling, `qom-get` to
read), which SwiftQEMU's closed command enum doesn't speak — and each QMP
server socket admits one client at a time, with the spawning `QEMUManager`
holding its private monitor and re-adoption owning `qmp.sock`. So every VM
gets a *third* monitor at `<vmStoragePath>/<vmId>/qmp-stats.sock`, and
`StratoAgentCore/QMP/QMPProbeClient` — a minimal QMP client reusing the QGA
byte-channel/framer seam, so it unit-tests against the same in-memory fake —
connects per probe, negotiates the greeting/`qmp_capabilities` handshake,
and collects the stats. The same guest-info slow poll caches the result as
`VMMemoryStats`, attached to each `ObservedVMState` (wire v16). Guests
without the driver, or not yet reporting (`last-update == 0`, `-1`
sentinels), yield nil — never a fabricated zero. The same probe also reads
`query-balloon`'s `actual` on that open channel (issue #567 phase 2) — QEMU's
own view of how much memory the balloon currently leaves the guest, reported
even when the guest driver never binds.

### Operator balloon targets

An operator can ask a running guest to give memory back: `VMSpec.balloonTargetBytes`
(wire v19) names the memory the guest may keep, and the agent inflates the
balloon to the difference with QMP `balloon <target>`. The grant itself does
not move — the quota charge and the scheduler's reservation stay at what was
committed — so this is reclaim, not resize; growing a guest is still
`memoryBytes` and virtio-mem.

Like a resize this is declarative, and it rides the same `.resize` step:
`VMSizing` carries the applied target alongside cpus/memory, so a spec whose
target differs plans convergence. Two things it does *not* share with a
resize:

- A fresh QEMU process starts with a fully deflated balloon, so `bootVM`
  re-applies a spec's target after start. The reconciler cannot see that
  difference on its own — its notion of applied sizing is the spec the VM was
  created with.
- The request is not the outcome. A guest hands pages back asynchronously and
  a guest under pressure may hand back fewer than asked, so the agent logs a
  failed request rather than failing convergence, and `balloonActualBytes` on
  the next stats poll is what says whether the memory actually came back.

## CPU/memory hot-add (resize without a reboot)

A VM created with headroom — `maxCpus > cpus` or `maxMemoryBytes >
memoryBytes` in its spec (issue #568) — spawns with the extra QEMU
arguments that make it resizable: `-smp cpus=<n>,maxcpus=<max>` for the
vCPU hotplug slots, and `-m <base>M,slots=1,maxmem=<max>M` plus a
`memory-backend-ram` + `virtio-mem-pci` pair for memory. Without headroom
none of that is emitted, so the overwhelming majority of VMs spawn with
exactly the argument vector they did before the feature existed.

Resizing is **declarative, not an RPC**: the control plane writes the new
sizing into the VM's desired state and bumps its generation, and the
reconciler's planner — comparing each running VM's manifest sizing against
the sync's spec — emits a `.resize` step. That survives dropped syncs by
construction, since the next level-triggered sync re-derives the same diff.
The step reaches `QEMUService.resizeVM`, which drives the same
`qmp-stats.sock` monitor the balloon probe uses:

- **vCPUs**: `query-hotpluggable-cpus` enumerates the machine's slots
  (realized ones carry a `qom-path`), and free slots are realized with
  `device_add` in ascending topology order until the target is met.
- **Memory**: `qom-set requested-size` on the virtio-mem device, aligned
  down to the device's block size, asks the guest to plug (or unplug) the
  region above boot memory.

Hot-*remove* of vCPUs is deliberately not attempted — guest support for CPU
unplug is unreliable — and memory never shrinks below the boot size; both
smaller figures apply at the next reboot, which re-spawns from the whole
spec anyway. Growing past the ceilings the process spawned with is a
permanent failure on the agent and a `422` at the API: `maxcpus`/`maxmem`
are fixed for the life of a QEMU process. Hot-plugged resources arrive
offline, so the cloud-init provisioning installs udev rules that online
them (modern distros already ship equivalents).

The manifest entry is rewritten only after the driver reports success, so a
failed resize is re-planned by the next sync rather than looking applied.

## The reconciler

`StratoAgentCore/Reconciliation.swift` — two layers, generalized over
`WorkloadKind` so VMs and sandboxes share one engine:

- **A pure diff** (`Reconciler.plan`): desired list vs observed presence
  (`.managed(status)` or `.orphaned`) → `[ReconcileWorkItem]` of steps
  (`create`, `adopt`, `boot`, `pause`, `resume`, `resize`, `shutdown`,
  `delete`).
  Entries older than the last applied generation are dropped (replays can't
  roll state back); equal generations still re-plan (drift correction);
  present-but-undesired workloads get deleted (full-list semantics).
- **The `Reconciler` actor** executes items on **per-workload serial
  lanes** (`SerialTaskQueue` in `MessageOrdering.swift`: FIFO per key,
  concurrent across keys). A VM's lane key is its bare ID — the same lane
  the imperative message handlers use — so reconcile and imperative
  operations can never interleave on one VM. Failures are tracked per
  generation with a 3-attempt budget (permanent failures exhaust it
  immediately; a new generation re-arms it). `.adopt` executes first and
  then re-plans from the adopted workload's actual status.

After every item the agent sends a full `ObservedStateReport` — live status
plus `observedGeneration`, `convergencePhase`, and error/failed-generation
per workload; absence from the report is what confirms a deletion.

## Sandboxes on the agent

The driver seam is `StratoAgentCore/SandboxRuntimeProtocol.swift`
(create/boot/shutdown/delete/adopt, exit codes, plus the exec and log
streaming surface). Two implementations: `FirecrackerSandboxRuntime`
(Linux) and `MockSandboxRuntime` (simulation); with neither, the agent
reports itself not sandbox-capable.

A sandbox is a Firecracker microVM booted from a maintained guest
kernel/initramfs with the flattened OCI image as its root disk and a small
config drive; host↔guest control runs over vsock. Differences from the VM
path: a reduced step vocabulary (no pause/resume), no cold stop yet (a
stopped sandbox keeps its Firecracker process and its memory reservation),
and images come from the OCI pipeline instead of the VM image cache.

That pipeline lives in `StratoAgentCore/OCI/`: `OCIRegistryClient`
(distribution auth + digest-verified pulls using the short-lived registry
credential from the sync), `OCIImageFlattener` (layers → one tree with
whiteout handling), `Ext4ImageBuilder` (`mkfs.ext4 -d`), and
`OCIRootfsCache` (content-addressed by manifest digest), orchestrated by
`SandboxImageService`. See [sandboxes](./sandboxes.md) for the system
design.

## Storage

`StratoAgentCore/StorageBackend.swift` defines the storage seam — the
compute counterpart of `HypervisorService`: volume create/delete/resize,
snapshots, clones, info, and `materializeDisk`. The backend owns all paths;
callers pass IDs and get paths back (the control plane stores whatever the
agent reports, verbatim).

`FileSystemStorageBackend` is the shipping implementation (qemu-img over a
directory; subprocess runner injectable for tests). `materializeDisk` is
the single image→disk path used by all drivers: idempotent, detects the
source format with `qemu-img info`, converts when the requested format
differs (qcow2 cloud image → raw Firecracker rootfs), preflights free
space, writes to a `.partial` staging path, and publishes with an atomic
rename. See [storage](./storage.md).

`ImageCacheService` feeds `materializeDisk` through the `ImageSource` seam:
downloaded image artifacts are checksum-verified and kept under
`image_cache_dir` so repeat launches of the same image skip the download.
Concurrent requests for one entry are deduplicated by `SingleFlight` (the
counterpart to `SerialTaskQueue`: it collapses work that need only happen
once, rather than ordering work that must all happen). The cache is LRU-evicted to the `image_cache_max_size_gb` budget
(unset = unbounded) using the shared `DiskCacheLRU` helper in
`StratoAgentCore`; the sandbox rootfs cache enforces
`sandbox_image_cache_max_size_gb` the same way, on top of its idle TTL.

`VMManifestStore` is the durable JSON record of which backend owns each
workload and its resource-reserving spec. It survives restarts: previously
managed workloads load as **orphans**, keep reserving capacity, and are
re-adopted by the reconciler where the backend supports it (QEMU via QMP
socket, Firecracker via API socket).

## Networking

`NetworkOrchestrator` (executable target) resolves a VM's `[NetworkSpec]`
into typed `ResolvedNetworkAttachment`s **before** the hypervisor driver
runs, and tears them down after — drivers consume attachments
(`.tap(interface:)` or `.userMode`) and never talk to the network service
themselves. QEMU turns them into netdev arguments; Firecracker into
`NetworkInterface.tap` calls (rejecting anything else).

Behind `NetworkServiceProtocol` sit the platform drivers:
`NetworkServiceLinux` (OVN/OVS via SwiftOVN — chassis config, NB TLS,
site-topology authority, per-network generation guards) and
`NetworkServiceMacOS` (user-mode SLIRP only, dev/test). Level-triggered
network reconciliation (`reconcileNetworks`) defaults to a no-op on
non-SDN platforms. See [networking](./networking.md).

## Self-update

`StratoAgentCore/AgentUpdater.swift`: stages next to the binary (same
filesystem → atomic rename), verifies streaming SHA-256, probes the staged
binary (`--version` must exit 0, so a wrong-arch artifact can't
crash-loop), keeps the previous binary as `<binary>.prev`, and exits with
code 75 (EX_TEMPFAIL) so the supervisor restarts into the new binary.
`AutoUpdateGate` is the pure policy check (running VMs are deliberately not
a blocker — they survive restart via re-adoption); `AgentInstallMode`
refuses to self-update inside a container. The rollout design is in
[agent-updates](./agent-updates.md).

## SwiftFirecracker (vendored)

`SwiftFirecracker/` at the repo root is a standalone package wrapping the
Firecracker API: `FirecrackerClient` (actor — process spawning/tracking,
deterministic per-VM API socket layout, jailer support, re-adoption of
surviving processes) and `FirecrackerManager` (per-VM API wrapper over a
Unix-socket HTTP client), plus typed models (`MachineConfig`, `BootSource`,
`Drive`, `NetworkInterface`, `Vsock`, jailer options) and the vsock
host↔guest handshake.

## Tests

`agent/Tests/StratoAgentTests/` (~41 files) mirrors the Core units:
reconciliation (VM + sandbox), config/state/URL handling, message ordering,
the storage backends, the manifest store, the updater and its gate, the
full OCI suite, the sandbox suite (config drive, control protocol, jail,
log assembly), and networking (attachments, reconciler, OVN bootstrap,
DHCP, gateway planning).
