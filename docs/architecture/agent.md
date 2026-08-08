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

- **`StratoAgentCore`** (library) — the testable core. Depends on
  `StratoShared`, Logging, Toml, Crypto, and the transport/file plumbing its
  services need (NIOCore/NIOPosix/`_NIOFileSystem`, NIOSSL, AsyncHTTPClient)
  — deliberately **no SwiftQEMU, SwiftFirecracker, or SwiftOVN** — so the
  reconcile engine, config parsing, storage backend, OCI pipeline, manifest
  store, and updater are all unit tests away from any hypervisor.
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
  platform default**. Default path is `/etc/strato/config.toml` on Linux and
  `~/Library/Application Support/strato/config.toml` on macOS, falling back
  to `./config.toml`. Enum-valued fields (network mode, hypervisor type,
  jailer mode) are validated at load.
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
  SPIRE, so there is nothing on disk to rotate, corrupt, or leak. That is the
  agent's *own* SVID; a separate proposal
  ([guest-identity](./guest-identity.md), #496) has the agent additionally act as
  a SPIRE **delegate**, brokering SVIDs for the VMs and sandboxes it hosts.
  `strato-agent spiffe-delegated-probe` is the node-side diagnostic for it.
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
  16 MiB max frame (a pushed desired-state sync is one frame; must match the
  control plane), inbound frames decoded and yielded into an `AsyncStream`
  to preserve arrival order, and a connection-scoped 20s heartbeat.
  Connection loss triggers `Agent.runReconnectLoop`: exponential backoff
  (1s → 30s cap, with jitter), re-registering on success; a
  registration-rejected error is terminal (the node's SPIRE identity is no
  longer accepted — re-enroll it).
- **Desired state arrives by long-poll** (`DesiredStatePoller` in
  `StratoAgentCore`, STR-146). Against a control plane at wire v29+, and unless
  `desired_state_pull = false` pins it back, the agent starts a loop over
  `GET /agent/desired-state` after registration — over
  `MTLSArtifactDownloader` with the `.longPoll` timeout profile, so the same
  SVID mTLS transport as image downloads, resolved fresh per request so a
  rotated SVID needs no re-wiring. A received payload goes straight into
  `routeInboundMessage`, the same path a pushed frame takes, so it lands on the
  `.desiredState` serialization lane with the ordering guarantees the
  reconciler already relies on.

  Most fetches carry `If-None-Match` so the control plane can park them and
  answer `304`; that is a bandwidth optimization. Every
  `desired_state_full_refetch_seconds` (default 300) the loop omits the
  validator entirely and the control plane must answer with a full payload —
  the correctness invariant, and deliberately a rule rather than a tuning knob.
  Making *every* request conditional is the natural way to write an HTTP client
  and is exactly the bug: a wrong server-side "unchanged" would then strand the
  agent on stale desired state forever, with no error anywhere.

  The WebSocket is still dialed and still carries consoles, exec, log
  forwarding, heartbeats, and observed state. Only desired state moves.

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
console endpoints, disk hot-(de)attach, `reservedResources()`, an
opt-in `adoptVM` for orphan re-adoption, and `reclaimVMDirectory` for the
delete path that has no session to tear down (below).

The registry is a dictionary on the `Agent` actor keyed by
`HypervisorType`, populated once at `start()`. That dictionary and
`getHypervisorService(for:)` are the **only** places message handling
touches concrete drivers — adding a backend is one registration line plus
the enum case, not new switch sites. An unregistered type returns nil, so a
host cleanly rejects placements it can't serve.

- **`QEMUService`** (`.qemu`): Linux KVM / macOS HVF via SwiftQEMU.
  Materializes boot disks through the storage backend, wires serial/console
  sockets, and re-adopts orphaned VMs over a deterministic QMP socket path.
  Optionally gives the guest a **graphics console** (see below).
- **`LibvirtService`** (`.qemu`, Linux only): the same backend driven through
  **libvirtd** instead (see below).
- **`FirecrackerService`** (`.firecracker`, Linux only): translates the
  neutral spec into Firecracker API calls; requires direct-kernel boot and
  `.tap` network attachments. Shares one `FirecrackerClient` with the
  sandbox runtime, so VMs and sandboxes go through a single process
  registry and socket layout.
- **`MockHypervisorService`**: the no-op backend used as a build fallback
  and in simulation mode (one mock per hypervisor type). It tracks specs
  and status so reservations and reconciliation behave realistically.

### The libvirt QEMU driver

Both QEMU drivers ship, and each node picks one with the agent-local
`qemu_driver` key (`"process"`, the default, or `"libvirt"`). **Nothing about
that choice reaches the control plane**: `.qemu` on the wire keeps meaning
"QEMU node", capability gating, the scheduler and the wire protocol are
untouched, and the agent alone decides how a QEMU placement is realized — which
is what lets a fleet roll over one node at a time. The key is ignored on macOS,
which has no libvirt.

`LibvirtService` (STR-133) drives domains over `qemu:///system` through
swift-libvirt, which speaks libvirt's RPC wire protocol over NIO rather than
linking libvirt's C library. It builds on the pieces that landed ahead of it:
`DomainXMLBuilder`/`DomainXMLNode` (spec → domain XML), `ResolvedDisk` and
`VMDirectoryLayout` (STR-131), and the libvirtd provisioning and preflight in
`deploy/agent/install.sh` (STR-132) — including the `qemu.conf` ownership
settings the agent's own-every-path invariant needs. On a node that selects the
driver those preflight checks become **gating**: an unreachable libvirtd, or one
below the 11.5 floor, demotes `.qemu` to unavailable so the node stops
attracting placements it cannot serve.

It is much smaller than `QEMUService`, and the reason is that libvirtd is a
durable store rather than a process the agent has to remember:

- **Create is `domainDefineXML`**, which leaves the domain `SHUTOFF` — the
  `ReconcileStep.create` contract ("exists, not running") with none of the `-S`
  plus `prelaunch`-versus-`paused` disambiguation `awaitingFirstStart` exists
  for. Idempotency comes free: define is keyed by name and UUID, so a replayed
  create updates rather than spawning a second machine.
- **Re-adoption is a query**, not a mechanism: `connectListAllDomains` plus a
  state read. The deterministic second QMP socket and `AdoptedQEMUVM` exist only
  because `QEMUManager` cannot attach to a process it did not spawn.
- **A guest that powers itself off** leaves the domain `SHUTOFF` and restarts
  with `domainCreate`; there is no respawn-from-stored-configuration path.
- **libvirt owns swtpm and the UEFI varstore**, so `SwtpmSupervisor` and the
  copy-if-absent NVRAM templating have no counterpart. The undefine on delete
  carries the `TPM` flag, because swtpm's per-domain state lives under
  `/var/lib/libvirt/swtpm/` rather than in the VM's own directory.
- **Consoles are unchanged.** The domain document binds the serial,
  virtio-console, guest-agent and VNC sockets at the same paths under the VM's
  directory, so `ConsoleSocketManager` and the noVNC relay need no libvirt
  knowledge. So does guest observation: the guest-agent channel is a QEMU device
  either way, which is why `guestInfo`/`memoryStats` are `HypervisorService`
  requirements rather than one driver's methods.

Not yet implemented, and gated behind `notSupported` rather than silently
skipped: disk hot-plug, online resize and VM checkpoints (STR-134), and
lifecycle events in place of status polling (STR-135). The visible consequence
is that a volume attached to a **stopped** libvirt VM is recorded but not
realized — the domain document is written at create and nothing rewrites it —
while attaching to a running one fails loudly.

### Diagnosing a failed QEMU spawn

QEMU reports a rejected argument or an unreadable disk image on stderr and
exits during setup — but only *after* opening its first `-qmp` socket, so a
misconfigured spawn used to look like a socket that appeared and then refused
the connection: a bare QMP timeout naming nothing, which is how issue #740
hid an invalid `virtio-balloon` line that was killing every VM on the host.

SwiftQEMU drains QEMU's stderr into a bounded (16KB) tail buffer and gives up
on the socket wait as soon as the process exits, throwing
`QMPError.processExited(exitCode:killedBySignal:stderr:)`. QEMU's own message
therefore reaches the operator on three paths, with no environment variable to
set first:

- the error's description carries the stderr tail, so it lands in the
  reconciler's `lastError` and the failed operation the UI shows;
- SwiftQEMU logs `qemuStderr` metadata on the logger the agent injected;
- `QEMUService` logs `QEMU VM creation failed` with the binary and the
  arguments it asked for — the case where QEMU exited too early to say
  anything at all.

`ENABLE_QEMU_PROCESS_LOG_FILES=true` still tees QEMU's *stdout* to
`/tmp/qemu-*.log`; stderr no longer depends on it.

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

## Graphics console (VNC)

A VM whose spec carries `ConsoleSpec.graphics == .vnc` (issue #566) is spawned
with a display device and a VNC server on a Unix socket, so its framebuffer can
be relayed to noVNC in the web UI. Headless is the default and its command line
is unchanged.

`StratoAgentCore/QEMUGraphicsDevice.swift` builds the arguments — in the core
library, not beside the rest of the command line in `QEMUService`, for the same
reason as `QEMUBalloonDevice`: that file links SwiftQEMU and so has no unit
tests, and a device line QEMU rejects surfaces only as a QMP connect timeout.

- `-display none` plus `-vnc unix:<vmDir>/vnc.sock`. In current QEMU `-vnc` *is*
  a display backend, so the VNC server is what exports the framebuffer and no
  local window is ever opened. `-nographic` is correspondingly **not** passed
  for these VMs — its whole job is to force `-display none` and redirect the
  *default* serial and monitor to stdio. The VM's serial console is unaffected,
  because it is an explicit `-serial unix:…`, which is what `-nographic` defers
  to anyway. (A side effect worth knowing: dropping `-nographic` also moves
  QEMU's HMP monitor off the agent process's stdio.)
- **Standard VGA on x86** (`-vga std`), not virtio. The point of this console is
  pre-driver output — UEFI, GRUB, Windows Setup, a panic screen — and
  `virtio-vga` needs a guest driver for anything past its VGA-compat mode.
  virtio-gpu is also a separate QEMU module that some distribution builds omit
  entirely, while `std` is always present. Passing `-vga std` *selects* the
  default adapter rather than adding a second one, which is what keeps QEMU from
  refusing to start with two VGA devices.
- **`virtio-gpu-pci` on arm64**, where the `virt` machine creates no display
  device at all and there is no `-vga` to select one. EDK2 drives it at firmware
  time through `VirtioGpuDxe`.
- `qemu-xhci` + `usb-tablet`, for **absolute** pointer positioning. Without it
  the guest sees relative motion and its cursor drifts away from the browser's,
  which makes a graphical installer unclickable. `q35` starts with USB off and
  `virt` has no controller at all, so both the controller and the tablet's
  `bus=` are explicit.
- `usb-kbd`, on every architecture. It looks redundant on x86 — `q35` keeps the
  default i8042 PS/2 controller, so a guest there types without it and this just
  becomes a second keyboard — but arm64's `virt` has no PS/2 and creates no
  input devices at all. Without it an aarch64 guest renders and accepts clicks
  while dropping every keystroke, which breaks precisely the installer this
  console exists to drive.

**There is no RFB password.** The socket's file mode inside the VM directory,
plus the control plane's `view_console` authorization in front of the relay, are
the security boundary — the same trust model as the QMP and serial sockets
beside it. It must never become a TCP listener.

The socket path is deterministic, so a VM re-adopted after an agent restart
resolves its console from `vmStoragePath + vmId` alone; the listener belongs to
the surviving QEMU process, not to the agent. Conversely, a VM created headless
can never gain a display without being recreated — the device is fixed in the
QEMU process's arguments, and a stop/start respawns from those same arguments.

`ConsoleSocketManager` relays whichever socket a session asked for as opaque
bytes, so nothing agent-side understands RFB. Reads are handed to the control
plane through an `OrderedByteRelay` (a synchronous `yield` on the channel's
event loop, drained by one consumer task): a task-per-read forwards reads that
can transpose, which is survivable for a text console and fatal for RFB, where
the client reads a length-prefixed header and then exactly that many bytes.
Sessions are keyed by stream as well as VM, so opening the Display tab does not
tear down a serial console on the same VM. Graphics sessions are never evicted
at all — QEMU multiplexes RFB clients on one socket, so two viewers is a
supported case rather than a stale one.

## Guest provisioning (cloud-init)

`StratoAgentCore/CloudInitProvisioner.swift` generates the NoCloud seed ISO
QEMU disk-boot VMs consume (`meta-data`, `user-data`, and — when the control
plane allocated static addressing — a v2 `network-config`). Guest bootstrap
is deliberately per-backend: Firecracker VMs inject configuration through
kernel args instead and do not use this path.

The seed's `local-hostname` is the VM's **desired hostname**, taken from
`DesiredVMState.metadata.hostname` (STR-48) and passed to `createVM` alongside
the spec. It must be the name the control plane publishes, because a VM's DNS
zone is assembled from that same `VM.hostname` (see [dns](./dns.md)) — a seed
that invented its own name would leave forward and reverse DNS naming a host
that does not answer to it. The historical `vm-<id-prefix>` derivation survives
only as the fallback for VMs that have no hostname at all (those predating the
column, and control planes predating the metadata field); the agent also
re-checks the label against the RFC 1123 rule before rendering it, since the
value lands unquoted in a YAML document. An unusable label falls back too and
logs a warning rather than failing the create — a guest with a wrong name beats
a guest that will not boot — but a control plane that validated on write cannot
produce one.

The ISO is written once at create, so a later hostname change reaches the guest
through the metadata service rather than this seed. That also bounds what
fixing this repaired: **VMs created before it keep booting under their
`vm-<prefix>` name until something re-runs `createVM` for them** — a recreate,
or a migration, whose destination agent renders a fresh seed from current
metadata. Existing DNS drift is not repaired in place.

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
(issue #563) so stock cloud images gain verified shutdown and guest IP
reporting without image changes. The no-caller path uses cloud-init's
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
- **fs-freeze snapshots** (withdrawn in issue #747): the volume-snapshot
  handler used to freeze the attached guest's filesystems around overlay
  creation. Nothing made that overlay the guest's active layer, so the freeze
  only lent an inconsistent snapshot a consistency signal. The capture now
  refuses any artifact whose entry names an attached VM
  (`DesiredSnapshotCapture.attachedVMId`); `QGAClient` keeps the freeze/thaw
  verbs for the eventual QMP-based live snapshot. See
  [storage](./storage.md#snapshots).
- **Guest info**: a throttled slow poll (folded into the heartbeat cadence)
  probes running QEMU VMs for hostname and configured addresses off the report's
  hot path, caching the result the observed-state report reads. This is the only
  way DHCP/SLAAC addresses the control plane never allocated become visible.

### Running commands in a guest (`guest-exec`)

`QGAClient.runCommand` executes a `GuestCommand` in the guest and returns its
exit status with captured stdout/stderr. qga models exec as **spawn-and-poll**:
`guest-exec` returns a PID, and `guest-exec-status` reports completion, handing
over each captured stream base64-encoded and *whole* in the reply that first
says `exited: true`. There is no completion notification, no PTY, no way to
write further stdin, and no way to signal a running process — which is why this
is a run-a-command primitive and can never back an interactive session.

Three consequences shape the implementation:

- **Polling is bounded by a caller-supplied deadline** (`StageBudget.guestExecSeconds`
  by default) and is an ordinary backoff loop over cancellable awaits, not a
  background task, so a timed-out or cancelled call leaves nothing running
  agent-side. It does *not* stop the guest process — qga cannot signal it — so
  the thrown `executionTimedOut` carries the PID. For the same reason the spawn
  is never retried; only the polls are, and only on transport-level failures —
  a reply the agent gave us (an error object, an undecodable shape) will not
  read differently next time. `spawnCommand`/`commandStatus` are public
  alongside `runCommand` so a caller can drive the waiting itself: that is what
  modelling a long guest command as an async operation needs, and it is the
  only way to collect a command `runCommand` abandoned at its deadline —
  collecting the status is also what frees qga's in-guest entry and the output
  it pins.
- **Captured output is capped per stream** (1 MiB by default, clamped to qga's
  own 16 MiB in-guest cap). Since the whole stream arrives in one JSON object,
  the cap is enforced by sizing that read's framer budget: an oversized reply is
  refused mid-stream as `responseTooLarge` rather than buffered and then
  rejected. qga's own truncation surfaces separately as the result's
  `stdoutTruncated`/`stderrTruncated`. Replies at this size are also why
  `QGAObjectFramer` carries its scan cursor across appends — re-scanning the
  buffer per socket chunk was free for a few-hundred-byte reply and quadratic
  for a megabyte one.
- **Each round trip opens its own channel**, so a long-running command doesn't
  hold the one-client-at-a-time chardev away from shutdown and guest-info
  probes. A poll that loses that race is retried until the deadline.

Exec is not universally available: distros filter the RPC set, and the RHEL
family ships an `--allow-rpcs` allowlist that omits `guest-exec` (Ubuntu,
Debian, and Fedora do not filter — see issue #803). `queryCapabilities`
(`guest-info`) reports which commands the agent will answer, so a caller can
say "this guest can't run commands" up front; attempting it anyway comes back
as `commandUnavailable` rather than a generic failure.

## Balloon memory stats (virtio-balloon)

Every QEMU VM gets a `virtio-balloon-pci` device with `free-page-hint=on`
(issue #567): inert until the guest's virtio_balloon driver binds it, after
which free-page hinting lets KVM drop guest-freed pages (shrinking host RSS
with no policy work) and the device's `guest-stats` expose real guest memory
usage.

`free-page-hint=on` also requires a per-VM `iothread` — QEMU processes the
hints off the main loop and refuses to start the device without one. The
`-object iothread,…` / `-device virtio-balloon-pci,…,iothread=…` pair is
assembled by `StratoAgentCore/QEMUBalloonDevice` so it stays under test:
because the device is attached to *every* VM, an invalid line there stops all
VM boots on the host (issue #740).

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
`WorkloadKind` so VMs, sandboxes and volumes share one engine:

- **A pure diff** (`Reconciler.plan`): desired list vs observed presence
  (`.managed(status)`, `.orphaned`, or `.quarantined`) → a `ReconcilePlan` of
  `[ReconcileWorkItem]` steps (`create`, `adopt`, `boot`, `pause`, `resume`,
  `resize`, `shutdown`, `delete`, `attach`, `detach`) plus the workloads this
  host holds that the sync didn't account for.
  Entries older than the last applied generation are dropped (replays can't
  roll state back); equal generations still re-plan (drift correction);
  present-but-unlisted workloads are **held**, not deleted (below).
- **The `Reconciler` actor** executes items on **per-workload serial
  lanes** (`SerialTaskQueue` in `MessageOrdering.swift`: FIFO per key,
  concurrent across keys). A VM's lane key is its bare ID — the same lane
  the imperative message handlers use — so reconcile and imperative
  operations can never interleave on one VM. Failures are tracked per
  generation with a 3-attempt budget (permanent failures exhaust it
  immediately; a new generation re-arms it). `.adopt` executes first and
  then re-plans from the adopted workload's actual status.

### Volume lanes and the enqueue order (STR-148)

Volumes joined the engine as a third `WorkloadKind` rather than a forked
planner: the staleness guard, the attempt cap, the failure classification and
the hold-and-report logic are all shared. A volume's presence comes from the
storage backend's own inventory, not the manifest — a volume is a file, so
there is nothing to adopt and no session to lose.

Two things are volume-specific. First, a work item can hold **more than one
lane**: an attach or detach drives the target VM's hypervisor session, so it
takes the VM's lane alongside `volume/<id>`, reproducing exactly what the
imperative `volume_attach` frame's routing gave it. Second, enqueue *order*
matters even though multi-lane items already give mutual exclusion, because
holding two lanes guarantees isolation and not sequence. One sync enqueues in
four passes: volume data-plane work (create/resize/delete) first, so a volume
exists before a VM referencing it is built; then VM items; then volume
*attachment* work, so an attach queues behind that VM's create/boot on the VM's
own lane rather than racing it into a dependency wait; then sandboxes.

The convergence steps for a volume are planned one at a time, on purpose: a
grow lands before an attachment moves, and an attachment that is merely *wrong*
is unplugged before it is re-plugged elsewhere. Two things are deliberately not
steps at all — a shrink and a format change — because neither is something the
agent can converge, so they surface as permanent failures rather than as work
that silently never completes.

After every item the agent sends a full `ObservedStateReport` — live status
plus `observedGeneration`, `convergencePhase`, and error/failed-generation
per workload; absence from the report is what confirms a deletion. The one
exception is a report carrying `manifestStatus.inventoryComplete == false`,
which is an agent saying it cannot enumerate its own workloads at all (see
[Storage](#when-the-manifest-cant-be-read-str-138)); the control plane applies
nothing from its lists.

### Holding what the control plane didn't mention (STR-98)

A workload present here that a sync doesn't list is not destroyed. The agent
keeps running it and reports it in `ObservedStateReport.unrecognized`; the
control plane checks whether a record exists and, only if none does, answers
with a `DesiredWorkloadTombstone` on a later sync, which the agent converges
exactly like an `.absent` desired entry. Tombstoned deletes stay exempt from
the 3-attempt cap — nothing can mint a new generation for a workload with no
record, so a capped failure would leak the stray forever.

This matters because the alternative was catastrophic and quiet: omission used
to mean "destroy", so any control-plane condition that produced a short list —
a restored database, this node re-enrolled under a new agent record, a
scoping regression — force-stopped every workload it failed to mention. The
disks survived; the records and the running guests did not.

A second layer bounds the authorized path itself. `TeardownGuard` refuses a
sync whose tombstones would remove more than `reconcile_teardown_minimum`
workloads **and** more than `reconcile_teardown_percent` of what the host is
running (defaults 3 and 25%). The refusal is logged at `error`, reported in
`ObservedStateReport.teardownRefusal` so it reaches operators through the
control plane, and everything else in the sync still converges. A deliberate
drain sets `allow_bulk_teardown` in the agent config. Ordinary `.absent`
deletes — the ones someone asked for through the API, with an operation row
and an audit trail — are deliberately not counted, so normal bulk deletes are
unaffected.

### Deleting a VM with no live session

A delete normally converges through the driver's `deleteVM`, which tears the
hypervisor process down and then removes `<vm_storage_dir>/<vmId>` whole —
boot disk, cloud-init ISO, UEFI varstore, TPM state, sockets (#969). Two
deletes never reach that removal, and both used to leave the directory on the
host permanently (STR-179):

- **An orphan that cannot be re-adopted.** `reconcileDelete` re-adopts first,
  so a surviving process is really destroyed rather than abandoned. The failure
  is then classified by `OrphanDeleteAdoption.classify` (in `StratoAgentCore`,
  so the table is unit-tested): only `adoptionTargetGone` — no live process
  behind the VM's control socket — reaches the driver's `reclaimVMDirectory`,
  and it runs *before* the manifest entry is released, since that entry is the
  host's last record the VM existed. Every other failure is ambiguous (the VM
  may be alive and merely unreachable) and keeps the older contract: release
  the entry, log, leave the files for manual cleanup.
- **A VM the driver holds no session for.** `QEMUService.deleteVM` used to
  throw `vmNotFound` and leave the directory behind on every retry; the
  Firecracker driver had the same shape, one layer down, where
  `FirecrackerClient.destroyVM` throws for a VM it does not track. Both now ask
  the VM's deterministic control socket whether anything is still running from
  that directory: a socket that answers is torn down for real (so the delete
  converges), one that refuses outlived its process, and only a connect that
  hangs is ambiguous enough to fail the delete and be retried by the next sync.

The evidence is the socket, not the process, so an *absent* socket is the weak
case — it is the ordinary trace of a hypervisor that exited and unlinked it,
but also what a still-running VM created before deterministic sockets (#260 /
#433) looks like. Both drivers treat it as gone and log it at `warning`,
matching what `Agent.adoptVM` already does with the same error (it re-creates
from the manifest spec, over the very same disks). Where a live process *is*
found, `AdoptedQEMUVM.destroy` now waits for the QMP socket to stop accepting
connections before returning: `quit` cannot report an exit — it legitimately
errors when QEMU exits before replying — so without that wait a wedged guest
could keep running from unlinked inodes.

Directories leaked before this are not reclaimed by either path. A startup
sweep would have to distinguish a leaked directory from one belonging to a
running VM whose manifest entry is missing, which needs its own design.

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

### When the manifest can't be read (STR-138)

The manifest is the agent's only memory of what it is running — nothing scans
running hypervisor processes or the storage tree — so `load()` returning
"nothing" on a read error used to be an assertion that the host was idle.
Three subsystems act on that immediately: capacity accounting frees the whole
machine (and `least_loaded` then preferentially fills it), the reconciler plans
`.create` for guests that are still running, and the observed report's
full-list semantics confirm deletions that never happened.

So `load()` returns a `ManifestLoad` — `.fresh`, `.loaded`, or `.unreadable` —
and the caller has to decide:

- **`.unreadable`** (unreadable bytes, truncated or non-object JSON)
  **quarantines the host.** It advertises zero available CPU/memory/disk so the
  scheduler places nothing on it, `Reconciler.apply` converges nothing —
  `presenceIsComplete()` is false, and creating a workload it cannot rule out
  already running would point a second hypervisor process at a live disk image
  — and `persistManifest()` refuses to write, because the first write after a
  failed read is what turns a recoverable file into a permanent loss. The store
  also copies the file aside as `<path>.corrupt-<timestamp>` (a copy, not a
  move: a *later* build needs to find the original, and moving it would make
  the next start read the host as fresh). The condition travels on
  `ObservedStateReport.manifestStatus`, which also tells the control plane to
  read no absence from that report, and lands on the agent row for the UI.
  A quarantine clears when a later read succeeds — retried on each heartbeat, so
  a storage volume that mounted late recovers by itself. A manifest that has
  since *vanished* does not clear it: deciding the host is empty stays a
  deliberate act (restart the agent).
- **One bad entry costs one entry.** Entries decode individually, so an
  unrecognized `hypervisorType` — what an agent rolled back past a new backend
  meets — or a spec this build cannot read **quarantines that entry** while the
  rest of the host reconciles normally. A quarantined entry keeps reserving its
  salvaged capacity, is reported as present (absence would confirm a deletion),
  and can be neither created, deleted, nor adopted — including under a
  tombstone, since there is no backend to ask. It is re-persisted **verbatim**,
  so rolling forward again restores the routing field intact.

### vsock context IDs (STR-72)

A vsock CID is not a per-VM number. QEMU's `vhost-vsock-pci` programs it into
the host kernel's `vhost_vsock` driver, which keeps **one flat 32-bit namespace
per machine** (0–2 reserved), so a CID derived from a VM id is a collision
waiting to happen — at best a failed VM start, at worst a host process reaching
the wrong guest's control agent. `VsockCIDAllocator` (`StratoAgentCore`) hands
them out instead, and every assignment is written to the VM manifest as
`VMManifestEntry.vsockCID` so a restarted agent cannot re-issue a live VM's CID.
The manifest read reserves every recorded CID, **including the quarantined
entries'** — that workload may still be running on it. Allocation is idempotent
per VM (the re-create-an-orphan path runs the same code twice), released when
the VM's manifest entry goes, and rolled back when a create fails — via a
`VsockCIDLease`, so the "don't free a CID this create didn't take" rule lives in
the allocator rather than at each call site. Exhaustion **throws**, classified
`.permanent` so the reconciler reports it instead of burning a retry budget on a
create that only another VM's deletion can unblock.

Allocation walks forward from a cursor rather than reusing the lowest free CID,
so a host-side connection that outlives its guest cannot land on the next VM.
Reserving advances that cursor too, which is what carries the property across a
restart: the connections being guarded against belong to other host processes
and outlive the agent, so resuming at the bottom of the range would hand the
next VM exactly the CID most likely to still be targeted.

Two boundaries worth knowing:

- **The manifest is written after the driver succeeds**, so a crash in that
  window leaves a guest whose CID nothing on disk records. That window is
  pre-existing (the same crash loses the whole entry), and claiming the workload
  before it exists would have the manifest reserve capacity and block re-creates
  for a VM that may never have been created. It fails safe rather than silently:
  the kernel refuses a duplicate CID (`EADDRINUSE`), so a later VM handed the
  orphaned CID fails to start rather than joining the surviving guest's channel.
- **The allocator is authoritative only over VMs this agent created.** A CID
  held by a non-Strato process, or by a VM started outside the agent, is
  invisible to it. Same fail-safe, and the consumer should surface it as "CID
  already in use on this host".

Only backends that occupy that namespace draw from it —
`HypervisorType.usesHostVsockNamespace`, currently QEMU alone. Firecracker
emulates virtio-vsock inside its own process and exposes a Unix-domain socket to
the host (`VsockConfig.udsPath`), so a Firecracker guest's CID never reaches the
host kernel. That is why every sandbox can use CID 3 and why sandboxes are
deliberately *not* routed through this allocator: it would spend a host-global
resource on devices that occupy none of it.

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

### Instance metadata chassis (IMDS)

The chassis-local half of the metadata dataplane (wire v27, STR-49) is
planned by `StratoAgentCore/MetadataChassisPlan.swift`: the OVS internal
port and per-network namespace (`strato-md-<network-uuid>`) that terminate
the metadata addresses on this host, kept a pure plan (like
`SandboxNetnsAttachmentPlan`) so the command sequence stays unit-testable,
and executed by `NetworkServiceLinux`. Its input is the agent's own workload
specs (`NetworkSpec.metadataEnabled`), not the `networks` list — it must
exist on every chassis running a NIC on the network, including sited
non-controller agents, which receive an empty `networks` list by design. The
`NetworkReconciler` converges the OVN `localport` itself from
`DesiredNetworkState.metadataEnabled` on authoritative agents, and
`metadataProtection(for:)` shields existing ports from teardown when the
field is nil (a pre-v27 control plane's silence must not delete live ports).
Nothing serves HTTP inside the namespace yet — the guest-facing IMDS
listener is future work. See
[ADR 0003](../adr/0003-imds-chassis-namespace.md) and
[networking](./networking.md).

### Instance metadata store (IMDS payload)

`StratoAgentCore/MetadataStore.swift` holds what that service will serve:
one `InstanceMetadata` per VM (wire v26, STR-52), written by the reconciler
from each sync's `DesiredVMState.metadata` before it plans anything.
Reads are answered entirely from here, with no control-plane round trip —
the same fail-static posture as the rest of the reconciler, and deliberate,
because a guest that cannot read its metadata may fail to boot.

**That guarantee holds across a control-plane outage, for the life of the
agent process — not across an agent restart.** The store is in memory while
the VM manifest is durable, so a restarted agent re-adopts running VMs it can
serve nothing for until the first sync lands, and indefinitely if the control
plane is unreachable then. Harmless only because nothing serves reads yet:
the listener (STR-56) has to close it, either by persisting the store beside
the manifest or by refusing to answer until the first sync has been applied.
Serving a guest a confidently empty document is worse than making it wait.

Three rules keep it honest, and each is a place the obvious implementation
would be wrong:

- **The store's own generation guard**, not `lastApplied`. A strictly older
  sync is refused so a replay cannot roll metadata backward; an *equal*
  generation still applies, because editing only what metadata carries (a
  hostname, an SSH key) changes no realization and so bumps no VM generation
  — a strict `>` would freeze out exactly the edits the IMDS exists to
  deliver. `lastApplied` cannot serve as that guard: it tracks convergence,
  so a VM whose create keeps failing holds it still while generations
  advance.
- **Metadata is recorded outside the presence guard** that stops all
  convergence on a host whose manifest is unreadable (STR-138). The store
  projects what the control plane said, not what the host holds, so a blind
  agent's guests keep getting current metadata.
- **Withdrawal follows the VM off the host, and never further.** A desired
  entry that wants the VM `.absent` drops the payload whatever the sender's
  wire version, since an address outlives the VM it was allocated to and the
  IMDS identifies its caller by source address; a tombstoned teardown drops
  it only once the delete has actually converged, so a teardown the
  blast-radius guard refused keeps serving. The two therefore sit on opposite
  sides of the delete, and deliberately: the `.absent` withdrawal *leads* the
  VM off the host because it must also cover the VM that was already gone
  when the sync arrived — which plans no work item to hook — so a VM whose
  delete keeps failing is still running with its metadata already withdrawn.
  That is the safe end of the trade; the other end serves a released VM's SSH
  keys and user data to whoever next holds its address. The teardown
  withdrawal is also *not* generation guarded, because a teardown is
  authorized from the observed generation the agent reported, which lags the
  sync generations the store records whenever convergence is failing. Both
  withdrawals seal their generation, so only a strictly newer sync can serve
  the VM again, and withdrawn records are kept rather than deleted for
  exactly that guard. A VM the sync merely *omits* keeps its metadata
  (STR-98: omission is not an instruction).

The payload half is gated on `supportsInstanceMetadata(senderVersion)` for
the `networks`/`sandboxes` reason: from a v26+ control plane a nil `metadata`
is authoritative and withdraws what we serve, while from an older one it is
silence, and reading it as an instruction would empty every VM's metadata the
moment a control plane is rolled back.

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

`agent/Tests/StratoAgentTests/` (~68 files) mirrors the Core units:
reconciliation (VM + sandbox), config/state/URL handling, message ordering,
the storage backends, the manifest store, the updater and its gate, the
full OCI suite, the sandbox suite (config drive, control protocol, jail,
log assembly), and networking (attachments, reconciler, OVN bootstrap,
DHCP, gateway planning).
