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
  services need (NIOCore/`_NIOFileSystem`, NIOSSL, AsyncHTTPClient), plus
  swift-libvirt for the pure layer of the libvirt driver (it is pure Swift
  with no system dependency) — deliberately **no SwiftFirecracker or
  SwiftOVN** — so the reconcile engine, config parsing, storage backend, OCI
  pipeline, manifest store, domain XML builder, and updater are all unit tests
  away from any daemon.
- **`StratoAgentSPIFFE`** (library) — SPIFFE/SPIRE support (SVID types, TLS
  config, Workload API client), split out so tests can import it.
- **`StratoAgent`** (executable) — the binary and everything that talks to a
  live daemon: the `Agent` actor, `LibvirtService`, `FirecrackerService`,
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
  16 MiB max frame, inbound frames decoded and yielded into an `AsyncStream`
  to preserve arrival order, and a connection-scoped 20s heartbeat.
  Connection loss triggers `Agent.runReconnectLoop`: exponential backoff
  (1s → 30s cap, with jitter), re-registering on success; a
  registration-rejected error is terminal (the node's SPIRE identity is no
  longer accepted — re-enroll it).
- **Desired state arrives by long-poll** (`DesiredStatePoller` in
  `StratoAgentCore`, STR-146) — the only sync transport since wire v38. The
  agent starts a loop over
  `GET /agent/desired-state` after registration — over
  `MTLSArtifactDownloader` with the `.longPoll` timeout profile, so the same
  SVID mTLS transport as image downloads, resolved fresh per request so a
  rotated SVID needs no re-wiring. A received payload goes straight into
  `routeInboundMessage`, landing on the `.desiredState` serialization lane with
  the ordering guarantees the reconciler relies on.

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

- **Guest identity minting has an agent-facing HTTP endpoint** on the same
  SVID-mTLS listener: `POST /agent/vms/{vmID}/jwt-svid`. The control plane
  verifies that VM is currently placed on the authenticated agent before
  issuing a bearer token. The production agent's guest-facing request path and
  token cache land separately; until then the desired-state sync does not
  advertise audiences or a TTL to guests.

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

The two driver host-inventory queries — `listVMs()` and
`reservedResources()` — return **optionals** (STR-196). Nil means the backend
could not answer and must not be coerced to an empty list or zero reservation.
The agent substitutes its durable manifest for unknown reservations;
`listVMs()` has no live reporting consumer since the v38 heartbeat stopped
carrying that inventory, but preserves the same contract for future callers.
The distinction is load-bearing because a synthesized zero reads exactly like
an idle host to the scheduler, which is how STR-190 stayed invisible in the
field.

The registry is a dictionary on the `Agent` actor keyed by
`HypervisorType`, populated once at `start()`. That dictionary and
`getHypervisorService(for:)` are the **only** places message handling
touches concrete drivers — adding a backend is one registration line plus
the enum case, not new switch sites. An unregistered type returns nil, so a
host cleanly rejects placements it can't serve.

- **`LibvirtService`** (`.qemu`, Linux only): QEMU driven through **libvirtd**
  at `qemu:///system` (see below). Materializes boot disks through the storage
  backend, writes a domain document binding the serial/console/guest-agent
  sockets, and optionally gives the guest a **graphics console**.
- **`FirecrackerService`** (`.firecracker`, Linux only): translates the
  neutral spec into Firecracker API calls; requires direct-kernel boot and
  `.tap` network attachments. Shares one `FirecrackerClient` with the
  sandbox runtime, so VMs and sandboxes go through a single process
  registry and socket layout.
- **`MockHypervisorService`**: the no-op backend used in simulation mode (one
  mock per hypervisor type) and as the `.qemu` registration on a platform that
  has no libvirt. It tracks specs and status so reservations and reconciliation
  behave realistically.

**There is no QEMU driver off Linux.** libvirt is Linux-only, so a macOS agent
registers the mock and reports `.qemu` as *unavailable* — the scheduler places
nothing on it, and the startup log says so in as many words. This is a
deliberate, temporary regression (STR-136): the macOS agent is a dev/test host,
and a native Virtualization.framework driver is separate work.

### The libvirt QEMU driver

`LibvirtService` (STR-133) drives domains over `qemu:///system` through
swift-libvirt, which speaks libvirt's RPC wire protocol over NIO rather than
linking libvirt's C library. It builds on the pieces that landed ahead of it:
`DomainXMLBuilder`/`DomainXMLNode` (spec → domain XML), `ResolvedDisk` and
`VMDirectoryLayout` (STR-131), and the libvirtd provisioning and preflight in
`deploy/agent/install.sh` (STR-132) — including the `qemu.conf` ownership
settings the agent's own-every-path invariant needs.

**libvirt's reachability is what `.qemu` availability means.** There is no
binary probe left — libvirtd picks the emulator from its own capabilities — so
one `virsh version --daemon` call answers both reachability and version, and its
result is threaded into `HypervisorProbe.probeAll` rather than looked up twice.
The split between the two is deliberate: the probe reports *unavailable* for a
daemon it cannot reach, so a caller that never reaches the gate cannot come away
believing a host with no libvirt can run VMs, while the **version floor** stays
in `HostPreflight`, which owns the check and its remediation. The preflight's
libvirt checks are gating, so a daemon below the 11.5 floor is demoted there.
Either way the node stops attracting placements it cannot serve. The rationale
for driving libvirt rather than QEMU — and what it cost — is
[ADR 0005](../adr/0005-agent-drives-libvirt-not-qemu.md).

It is much smaller than the process driver it replaced, and the reason is that
libvirtd is a durable store rather than a process the agent has to remember:

- **Create is `domainDefineXML`**, which leaves the domain `SHUTOFF` — the
  `ReconcileStep.create` contract ("exists, not running") with none of the `-S`
  plus `prelaunch`-versus-`paused` disambiguation `awaitingFirstStart` exists
  for. Idempotency comes free: define is keyed by name and UUID, so a replayed
  create updates rather than spawning a second machine.
- **Re-adoption is a query**, not a mechanism: `connectListAllDomains` plus a
  state read. libvirtd owns the QEMU monitor and outlives the agent, so there is
  nothing to reattach to — where a process driver needs a second, deterministic
  monitor socket precisely because it cannot attach to a process it did not
  spawn.
- **A guest that powers itself off** leaves the domain `SHUTOFF` and restarts
  with `domainCreate`; there is no respawn-from-stored-configuration path.
- **libvirt owns swtpm**, so the agent supervises none of it. The UEFI varstore
  is the exception: libvirt will seed one from a template but will not convert
  it, and Strato's has to be qcow2 for checkpoints, so `createVM` writes it with
  `UEFIVarstore` before defining the domain and the document names a file with
  no `template` (STR-188). The undefine on delete
  carries the `TPM` flag, because swtpm's per-domain state lives under
  `/var/lib/libvirt/swtpm/` rather than in the VM's own directory. Whether a
  vTPM is possible at all is libvirt's answer to give: the agent reads
  `virsh domcapabilities` for a `<tpm>` `emulator` backend (`DomainCapabilities`)
  rather than looking for an `swtpm` binary it might not even share a filesystem
  with. That second `virsh` call is only made of a daemon that answered the
  first: on a host whose libvirt is unusable the preflight reports the vTPM
  answer as *not checked* rather than printing an "install swtpm" remedy
  underneath the gating "libvirt is not usable" one. libvirtd also caches host
  capabilities, so installing swtpm under a running daemon changes nothing until
  it restarts — the preflight's remediation, and the scheduler's placement
  error, both say so.
- **Consoles are unchanged.** The domain document binds the serial,
  virtio-console, guest-agent and VNC sockets at the same paths under the VM's
  directory, so `ConsoleSocketManager` and the noVNC relay need no libvirt
  knowledge.
- **Guest observation is a libvirt call.** `domainGetGuestInfo` and
  `domainInterfaceAddresses(source: AGENT)` reach the same
  `org.qemu.guest_agent.0` channel a direct qga client would open, and
  `domainMemoryStats` replaces the third QMP monitor that only existed because
  a QMP server socket admits one client. What the control plane is told does not
  change with the driver, which is why `guestInfo`/`memoryStats` are
  `HypervisorService` requirements rather than one driver's methods.

- **Transitions are announced, not discovered.** The driver holds a
  `withDomainEvents` lifecycle subscription (STR-135) for as long as the agent
  wants one, so a guest that powers itself off is reported in about a second
  rather than at the next 20-second sweep. Events are an **accelerant, not a
  source of truth**: what they carry is a request to re-read the host, and the
  observed-state report they schedule is the same full re-reading the periodic
  one performs. That is what makes the subscription buffer safe to bound and
  drop from (`.dropOldest` — the newest transitions are the ones describing the
  present, and a full re-reading answers every request that preceded it), and it
  is why `getVMStatus` polling is untouched. The agent coalesces bursts into at
  most two reports per 500 ms window, because a host-wide power cycle emits
  stopped/started/resumed *per VM* and a report costs a round trip per VM.
  Reconnection is the loop's own job: the subscription dies with its connection,
  and the re-established one yields a resynchronize signal from *inside* the
  subscription scope, so the window it was disconnected for cannot fall in a gap.
  What this changes is **visibility latency, not repair latency**: a guest that
  powers itself off is *reported* in about a second, but nothing here rings the
  desired-state doorbell, so the reconciler still restarts it on its own cadence.

#### The domain document is the configuration, and a boot reads it

`createVM` defines a domain, and the next boot starts *that definition* rather
than re-reading the spec. That single fact shapes every in-place mutation
(STR-134), and the rule it produces is worth stating on its own: **hot-plug and
resize are sent with `AFFECT_LIVE|AFFECT_CONFIG`**, so they land on the running
guest *and* in the persistent definition. A process driver can leave the
definition alone because it respawns from a stored configuration the agent keeps
in step and re-reads the spec at every boot; here a live-only change silently
un-happens at the guest's next power cycle. The same correction applies to a
memory change on a VM with no virtio-mem device: it is written to `CONFIG` alone
rather than left for a boot that would not pick it up. A running vCPU shrink is
different: because it cannot change the live domain, it is rejected rather than
reported as a completed online resize.

Three consequences follow:

- **Three ceilings are set when a VM is created, and a boot is what moves them.**
  The document reserves `DomainXMLBuilder.spareHotplugPorts` empty
  `pcie-root-port`s (libvirt adds one port per PCI device present at define
  time, so a domain that reserves none has nowhere to plug a disk), whatever
  virtio-mem region the spec asked for, and the `<vcpu>` maximum. All three bind
  a *running* VM: a fifth volume fails with "No more available PCI slots", a
  memory target above the region cannot be reached (virtio-mem's `<requested>`
  clamps to what the device has), and `virDomainSetVcpusFlags` refuses a count
  above the declared maximum.

  The spares carry **explicit indexes**, derived from the count of PCI devices
  the document declares, and that is the whole mechanism rather than a detail
  (STR-192). An un-indexed `pcie-root-port` is numbered by libvirt out of the
  range it was going to allocate for the domain's own devices and then filled
  with one of them, so it reserves nothing: before the indexes went in, every
  golden defined with zero free ports and every disk hot-plug on a running VM
  failed with "No more available PCI slots". libvirt materializes every index
  below the highest one declared, so the top index is the port count and the
  spares are what is left over the top.

  None of them is permanent. An attach to a *stopped* VM was never bound by the
  first — it goes to the persistent definition with `AFFECT_CONFIG` alone and
  libvirt grows the bus itself — and since STR-187 a **boot widens all three**:
  see "Redefining a stopped domain" below. So the remedy those errors name is
  "stop and start the VM", not "recreate it". It also makes two things the
  control plane already did honest under this driver rather than only under the
  process one: its `422` ("restart it to grow beyond that"), and its raising of
  a stopped VM's recorded `maxCpu`/`maxMemory` on the assumption that the next
  boot re-reads them.
- **A volume names itself in the document.** Each volume-backed `<disk>` carries
  `<serial>vol-<uuid></serial>`, minted by `QEMUDiskIdentity`, so a detach
  resolves exactly that disk on a domain the agent keeps no model of (STR-129).
  `hasLiveSession` returns true for *any* domain here for a related reason: its
  false branch means "recording the attachment realizes it", which is true of a
  respawn-from-configuration path and false of this one.
- **A redefine is the only second write, and it is deliberately narrow.** See
  below.

#### Redefining a stopped domain

`LibvirtService.redefineVM` runs before every boot the reconciler plans for a VM
it did not just create, and it is the only thing besides `createVM` that ever
writes a domain document (STR-187). It reads the domain's **persistent**
definition (`VIR_DOMAIN_XML_INACTIVE`), hands it to `DomainRedefinition`, and
defines the result only if it differs — so an ordinary boot costs one `dumpxml`
and nothing else.

What it changes is only the three ceilings above: it tops the spare
`pcie-root-port`s back up to `spareHotplugPorts` *free* ones, raises
`<maxMemory>`, `<memory>`, `<currentMemory>`, the NUMA cell and the virtio-mem
region to what the current spec asks for, and raises `<vcpu>` with the cell's
`cpus` range. Never downward — a lowered ceiling is the resize path's business.
A domain created with no headroom at all grows the `<maxMemory>`, the NUMA cell
and the memory device that libvirt requires together; a spec that asks for **no**
region takes `<maxMemory>` away with the device, because that element is what
enables memory hot-plug and leaving it behind alone gives QEMU a `maxmem` equal
to the initial size next to a slot count, which it refuses to start.

The boot *size* moves with the ceiling — `<currentMemory>` and `<vcpu
current=…>` are both written from the spec — because `addResizes` plans nothing
for a stopped VM, so a size left behind is converged a whole reconcile later,
and arrives as a *hot-add*: memory the guest may take, vCPUs most guests will
not online without a udev rule. An operator told to "stop and start the VM"
would otherwise restart and still see the old size. This is not a resize path
for all that: a domain whose ceilings already fit its spec is left completely
alone.

Two steps in the same work item skip the widening. A `.create` built the
configuration from that spec moments earlier. A `.restore` runs *after* the boot
and converges through `virDomainRevertToSnapshot`, which replaces the definition
with the one recorded in the checkpoint — so the widening would be defined,
immediately overwritten, and paid for again on every boot forever. A VM being
restored keeps the ceilings its checkpoint was captured with, and widens on its
next boot instead.

**It edits the existing document rather than rebuilding one**, and that is the
design decision worth knowing. Rebuilding from the spec looks obvious and is
wrong: the spec is not a complete description of an existing domain — a VM
created from an image boots off a `disk.qcow2` no `VolumeSpec` names, its MAC may
be one libvirt generated, its `<os>` names the firmware resolved on the day it
was created — so each of those would have to be recovered from the domain
anyway, and a recovery this got wrong would silently change a VM's hardware at
its next power cycle. Editing inverts the failure mode: everything not named
above is carried through exactly as libvirt wrote it, and an edit the pass cannot
make (two memory devices, two NUMA cells, a lone cell that is not node 0, a
declared CPU topology, a domain already at the root-port index ceiling) becomes
a **refusal** the driver logs rather than a rewrite, so the VM keeps the ceiling
it had. A widening that fails
outright is logged and the boot proceeds: a VM that comes up with its old ceiling
is the status quo, while a VM that does not come up is a regression.

Reading a document back is `DomainXMLNode.parse`, the inverse of the renderer and
nothing more general — it is for documents libvirt produced. Attribute order is
not preserved (there is none to preserve in `XMLParser`'s dictionary) and
comments are dropped, while **mixed content and CDATA are refused rather than
dropped**, because a document that cannot be re-emitted faithfully is one that
must not reach `virDomainDefineXML`. `DomainXMLNode`'s text/children exclusivity
is only an `assert`, which is compiled out of the build hypervisor nodes run, so
the widening independently refuses a document whose `<devices>` or `<cpu>` is a
leaf rather than trusting it.

Checkpoints are libvirt **system checkpoints** — `domainSnapshotCreateXML` /
`domainRevertToSnapshot` / `domainSnapshotDelete`, with libvirt choosing the
disks in place of a hand-computed block-node list. Two host preconditions make
them work,
and both are established elsewhere: the NVRAM varstore is qcow2 rather than raw
(`DomainXMLBuilder` declares it, `UEFIVarstore` writes it — libvirt cannot,
since it refuses to convert a raw VARS template on the way, which is what
STR-188 was), and the host runs libvirt ≥ 11.5 — below which
`snapshot-create-as` refuses a pflash guest outright, since internal snapshots
only moved onto the modern job API in 10.9. `LibvirtProbe.minimumVersion` gates
`.qemu` on that floor, so a node too old to checkpoint stops advertising QEMU at
all rather than advertising a capture it cannot take. A checkpoint delete works
on a stopped VM.

A libvirt node is a full-capability QEMU node (STR-134, STR-135), and nothing in
its lifecycle path needs a raw monitor, so no domain it manages is ever tainted
by `qemuDomainMonitorCommand`.

### Diagnosing a failed domain start

A domain libvirt rejects fails at `domainDefineXML` or `domainCreate`, and
libvirt's own error is what the driver propagates — untranslated, so the message
naming the element or the file at fault is what lands in the reconciler's
`lastError` and the degraded condition the UI shows. There is no stderr tail to
drain and no environment variable to set first: the agent does not launch QEMU.

Where libvirt's message is too terse to act on — "internal error: process exited
while connecting to monitor" is the usual shape — QEMU's own output is on the
host at **`/var/log/libvirt/qemu/<domain>.log`**, one file per domain, named by
VM id. libvirtd writes the full command line it used at the top of each start,
followed by whatever QEMU printed before exiting. `journalctl -u virtqemud` (or
`libvirtd` on a monolithic install) carries the daemon's side of the same
failure.

## Firmware and the machine profile

`VMSpec.machine` (`MachineProfile`, wire v17) carries the two guest features
that are not resource sizing: Secure Boot and a TPM 2.0. Both default off, so
a spec that omits the field describes exactly the machine the agent built
before issue #565.

`StratoAgentCore/FirmwareResolver.swift` decides which EDK2 files a QEMU VM
boots with. It prefers the **split CODE/VARS pair** every distribution
actually ships, converting the VARS template into a qcow2 `nvram.fd` in the
VM's own directory and attaching both as pflash drives. The pre-#565 agent passed a
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

**The domain names the pair; it does not ask libvirt to choose one.**
`FirmwareResolver.domainFirmware` is the entry point `LibvirtService.createVM`
uses, and it names an explicit `<loader>`/`<nvram>` pair whenever this host
resolves one — which is every stock hypervisor node. `<os firmware='efi'>` is
only the fallback for a host whose EDK2 build sits somewhere the candidate list
has never heard of, because autoselection cannot be reconciled with a qcow2
varstore: libvirt matches the requested format against its descriptors at
*define* time, and every descriptor Debian and Ubuntu ship declares its nvram
template `raw`. Asking for both failed every VM create on those hosts with
"Unable to find 'efi' firmware that is compatible with the current
configuration" — a message that reads like a missing OVMF package rather than
the format collision it is (STR-188). Where the fallback is taken, the agent
logs why, and the Secure Boot guarantee survives it: the autoselect document
still carries `<feature name='secure-boot' enabled='yes'/>`, so libvirt refuses
the define rather than handing back an unsigned firmware.

**libvirt runs the vTPM.** The domain document carries
`<tpm model='tpm-tis'><backend type='emulator' version='2.0'/></tpm>` and
libvirtd starts, supervises and restarts one `swtpm` per domain, keeping its
state under `/var/lib/libvirt/swtpm/<domain-uuid>/` — outside the VM's own
directory, which is why the undefine on delete carries the `TPM` flag. The agent
neither spawns swtpm nor names a socket for it, and a swtpm that dies under a
running guest is libvirt's to notice. The state persists across a stop/start, so
anything the guest sealed to the TPM (BitLocker keys) is not lost.

What the agent advertises as `tpmCapable` at registration (plus a `vtpm`
capability string) is **libvirt's own answer**: `virsh domcapabilities` reporting
a `<tpm>` element with an `emulator` backend, parsed by
`StratoAgentCore/DomainCapabilities.swift`. A `passthrough`-only host has a
physical TPM to hand through and cannot serve the emulated one Strato asks for,
so it does not count. Asking libvirt rather than looking for an `swtpm` binary
matters on a containerized agent, which sees its own image rather than the
host's filesystem — and it means libvirtd has to be **restarted** after
installing swtpm, since it caches host capabilities. The host preflight reports
the absence as an advisory (with that restart in the remediation): a host
without a vTPM is perfectly useful, it just never receives a TPM placement.

## Graphics console (VNC)

A VM whose spec carries `ConsoleSpec.graphics == .vnc` (issue #566) gets a
display device and a VNC server on a Unix socket, so its framebuffer can be
relayed to noVNC in the web UI. Headless is the default and its document is
unchanged.

`DomainXMLBuilder` writes the elements, and `DomainXMLBuilderTests` is where the
reasoning behind each is asserted — a device libvirt or QEMU rejects fails the
create with a message that routinely names neither the element at fault nor the
feature that pulled it in.

- `<graphics type='vnc'>` with a `<listen type='socket' socket='<vmDir>/vnc.sock'/>`.
- **Standard VGA on x86** (`<video><model type='vga'/>`), not virtio. The point
  of this console is pre-driver output — UEFI, GRUB, Windows Setup, a panic
  screen — and virtio needs a guest driver for anything past its VGA-compat
  mode. virtio-gpu is also a separate QEMU module that some distribution builds
  omit entirely, while standard VGA is always present.
- **`virtio` video on arm64**, where the `virt` machine creates no display
  device at all. EDK2 drives virtio-gpu at firmware time through `VirtioGpuDxe`.
- A `qemu-xhci` USB controller plus `<input type='tablet' bus='usb'/>`, for
  **absolute** pointer positioning. Without it the guest sees relative motion and
  its cursor drifts away from the browser's, which makes a graphical installer
  unclickable. `q35` starts with USB off and `virt` has no controller at all, so
  the controller is declared explicitly.
- `<input type='keyboard' bus='usb'/>`, on every architecture. It looks
  redundant on x86 — `q35` keeps the default i8042 PS/2 controller, so a guest
  there types without it and this just becomes a second keyboard — but arm64's
  `virt` has no PS/2 and creates no input devices at all. Without it an aarch64
  guest renders and accepts clicks while dropping every keystroke, which breaks
  precisely the installer this console exists to drive.
- A headless VM states `<video><model type='none'/>` rather than omitting the
  element, so no libvirt version auto-adds a framebuffer to a VM whose console
  is the serial port.

**There is no RFB password.** The socket's file mode inside the VM directory,
plus the control plane's `view_console` authorization in front of the relay, are
the security boundary — the same trust model as the serial and console sockets
beside it. It must never become a TCP listener.

The socket path is deterministic (`QEMUGraphicsDevice.socketPath`), so a VM
re-adopted after an agent restart resolves its console from
`vmStoragePath + vmId` alone; the listener belongs to libvirt's QEMU process,
not to the agent. Conversely, a VM created headless can never gain a display
without being recreated: the redefine that runs before each boot adds spare
capacity and deliberately touches no device (STR-187), so nothing ever gives a
domain a framebuffer it was not created with.

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
QEMU disk-boot VMs consume. `VMSpec.metadataSource` (wire v48) selects its
shape at creation:

- `iso` is the compatibility default and carries `meta-data`, `user-data`, and
  — when addressing requires it — a v2 `network-config`.
- `imds` keeps the required `network-config` and an empty `user-data` on the
  ISO, then replaces `meta-data` with a `seedfrom` URL under
  `http://169.254.169.254/latest/nocloud/<per-VM capability>/`. NoCloud requires
  both local `meta-data` and `user-data` to accept a filesystem seed. Once the
  seed has addressed the NIC, cloud-init follows the stub to the agent's live
  metadata listener for the real documents.

The ISO cannot disappear even in `imds` mode: a statically addressed guest
needs `network-config` before it can reach the link-local listener. Guest
bootstrap is deliberately per-backend. Firecracker currently has no cloud-init
injection path, so VM creation rejects both `imds` and caller-supplied user data
for that hypervisor instead of accepting configuration it cannot deliver.

Before an existing IMDS-backed QEMU VM boots, the agent refreshes that local
seed from current desired state and narrowly migrates its inactive libvirt
definition when the x86 NoCloud network-mode SMBIOS hint is absent. This makes
the bootstrap repair apply to VMs created by older agents without rebuilding
their domain XML or changing full-ISO guests. A failed refresh or migration
keeps the VM stopped; a running QEMU process alone is not evidence that
cloud-init selected the intended datasource.

VM creation rejects `imds` when the VM-level metadata switch is off or when
none of its selected logical networks publish metadata. Either configuration
would create a seed whose hand-off URL has no reachable listener; `iso` remains
valid on metadata-disabled networks because its bootstrap is self-contained.
IMDS-backed VMs also require a QEMU agent that advertises OVN networking, since
user-mode networking cannot realize the metadata localport. The agent also
advertises `metadataServiceCapable` only after it initializes the listener
supervisor; the scheduler requires both signals, so `metadata_service = false`
and missing host prerequisites fail closed before placement.

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

The rendered `user-data` document — embedded in an `iso` seed or served over
the metadata listener for `imds` — has two shapes:

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

Every VM's domain document binds a `virtserialport` named
`org.qemu.guest_agent.0` at `<vmStoragePath>/<vmId>/qga.sock` (issue #563).
libvirtd owns that socket: the transport, the JSON framing and the
`guest-sync-delimited` resync that reaching a guest agent needs are its problem,
and it multiplexes, so the agent never speaks qga itself. The driver reaches the
guest through `domainGetGuestInfo`, `domainInterfaceAddresses(source: AGENT)`
and `domainShutdownFlags`, mapped by `StratoAgentCore/LibvirtGuestInfo.swift`.

qga is **unresponsive whenever the guest is not running the agent**, so every
call that reaches it is bounded by a short `StageBudget.guestAgentSeconds` and a
timeout is the *normal* path, not the error path — each use site degrades to
pre-qga behavior:

- **Verified shutdown**: `shutdownVM` sends `SHUTDOWN_DEFAULT`, so libvirt tries
  the guest agent first and falls back to the ACPI power button when it does not
  answer. The 60s escalation to a destroy is what bounds the whole thing.
- **Guest info**: a throttled slow poll (folded into the heartbeat cadence)
  probes running QEMU VMs for hostname and configured addresses off the report's
  hot path, caching the result the observed-state report reads. This is the only
  way DHCP/SLAAC addresses the control plane never allocated become visible.
- **fs-freeze snapshots** (withdrawn in issue #747): the volume-snapshot handler
  used to freeze the attached guest's filesystems around overlay creation.
  Nothing made that overlay the guest's active layer, so the freeze only lent an
  inconsistent snapshot a consistency signal. The capture now refuses any
  artifact whose entry names an attached VM
  (`DesiredSnapshotCapture.attachedVMId`). See
  [storage](./storage.md#snapshots).

There is **no guest-exec path**. The agent's own qga client and its
`guest-exec` spawn-and-poll implementation went with the process driver
(STR-136): nothing called them, and qga's exec model — a PID plus polling, with
no completion notification, no PTY, no further stdin and no way to signal a
running process — could never have backed an interactive session anyway. Sandbox
exec goes through the Firecracker guest agent instead.

## Balloon memory stats (virtio-balloon)

Every QEMU VM's domain document carries
`<memballoon model='virtio' freePageReporting='on'/>` (issue #567): inert until
the guest's virtio_balloon driver binds it, after which free-page reporting lets
KVM drop guest-freed pages (shrinking host RSS with no policy work) and the
device's `guest-stats` expose real guest memory usage.

Free-page **reporting**, not the hinting a hand-built QEMU command line used.
They solve the same problem, and reporting is the newer mechanism; the practical
difference here is that hinting requires a per-VM `iothread` (QEMU processes the
hints off the main loop and refuses to start the device without one) while
reporting does not — so the device that made an extra object mandatory, and the
argv builder that assembled the pair, both disappear with the process driver.

Stats come from `domainMemoryStats`, mapped by
`StratoAgentCore/LibvirtDomain.swift` — no second monitor socket and no QMP
client, because libvirtd owns the monitor and multiplexes access to it. The
guest-info slow poll caches the result as `VMMemoryStats`, attached to each
`ObservedVMState` (wire v16). Guests without the driver, or not yet reporting,
yield nil — never a fabricated zero. The same call carries the balloon's
`actual` (issue #567 phase 2) — QEMU's own view of how much memory the balloon
currently leaves the guest, reported even when the guest driver never binds.

### Operator balloon targets

An operator can ask a running guest to give memory back: `VMSpec.balloonTargetBytes`
(wire v19) names the memory the guest may keep, and the agent inflates the
balloon to the difference with `domainSetMemoryFlags`. The grant itself does
not move — the quota charge and the scheduler's reservation stay at what was
committed — so this is reclaim, not resize; growing a guest is still
`memoryBytes` and virtio-mem.

Like a resize this is declarative, and it rides the same `.resize` step:
`VMSizing` carries the applied target alongside cpus/memory, so a spec whose
target differs plans convergence. Two things it does *not* share with a
resize:

- A freshly started domain has a fully deflated balloon, so `bootVM`
  re-applies a spec's target after start. The reconciler cannot see that
  difference on its own — its notion of applied sizing is the spec the VM was
  created with.
- The request is not the outcome. A guest hands pages back asynchronously and
  a guest under pressure may hand back fewer than asked, so the agent logs a
  failed request rather than failing convergence, and `balloonActualBytes` on
  the next stats poll is what says whether the memory actually came back.

## CPU/memory hot-add (resize without a reboot)

A VM created with headroom — `maxCpus > cpus` or `maxMemoryBytes >
memoryBytes` in its spec (issue #568) — is defined with the elements that make
it resizable: `<vcpu current='n'>max</vcpu>` for the vCPU hotplug slots, and a
`<maxMemory slots='1'>` plus a `<memory model='virtio-mem'>` device for memory.
Without headroom none of that is emitted, so the overwhelming majority of VMs
are defined exactly as they were before the feature existed.

Resizing is **declarative, not an RPC**: the control plane writes the new
sizing into the VM's desired state and bumps its generation, and the
reconciler's planner compares the manifest sizing against the sync's spec.
It emits a `.resize` step for a running VM resize and for a stopped QEMU vCPU
shrink. That survives dropped syncs by construction, since the next
level-triggered sync re-derives the same diff. The step reaches
`LibvirtService.resizeVM`:

- **vCPUs**: `domainSetVcpusFlags` with `AFFECT_LIVE|AFFECT_CONFIG`, so the
  count lands on the running guest and in the definition the next boot reads.
- **Memory**: `domainUpdateDeviceFlags` raising `<requested>` on the virtio-mem
  device, aligned down to its block size, asks the guest to plug (or unplug) the
  region above boot memory.

Hot-*remove* of vCPUs is deliberately not attempted — guest support for CPU
unplug is unreliable — so the API rejects a running vCPU shrink and tells the
caller to stop the VM, resize it, and start it again. The libvirt driver repeats
that guard so a desired entry accepted by an older control plane — or a smaller
last-writer target racing with pending growth — cannot advance
`observedGeneration` without changing the live count. While the VM is stopped,
the resize updates the persistent definition before convergence and before a
planned boot, so the next guest starts with the smaller count. Memory never
shrinks below the boot size; that smaller figure is written to `CONFIG` and
applies at the next reboot.
Growing past the ceilings the domain was defined with fails on the agent and is
a `422` at the API, both naming a restart as the remedy — and since STR-187 that
remedy works, because the boot rewrites `<vcpu>`'s maximum and `<maxMemory>` to
what the current spec asks for. Hot-plugged
resources arrive offline, so the cloud-init provisioning installs udev rules
that online them (modern distros already ship equivalents).

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
  A stopped QEMU vCPU shrink is ordered before `.boot`; if changing the
  persistent definition fails, the item does not advance `lastApplied` and the
  VM does not start from the stale definition. More generally, a failing item
  never advances `lastApplied`. The control plane treats a failure at the
  current generation as not converged (STR-191).
- **The `Reconciler` actor** executes items on **per-workload serial
  lanes** (`SerialTaskQueue` in `MessageOrdering.swift`: FIFO per key,
  concurrent across keys). A VM's lane key is its bare ID — the same lane
  the imperative message handlers use — so reconcile and imperative
  operations can never interleave on one VM. Failures are tracked per
  generation and classification. Transient failures retry indefinitely with
  `1m → 5m → 15m → 1h`, then repeat hourly; an injected clock makes every
  boundary deterministic in tests. Permanent failures suppress later retries
  at that generation, logging one warning and incrementing the actor-local
  `retryCapSuppressions` diagnostic once when suppression first happens. A new
  generation re-arms either path. `waitingOnDependency` records nothing and
  retries silently on every sync, while `blocked` records the reason and also
  retries every sync — the precondition it names clears without anyone
  minting a new generation (STR-199). `.adopt` executes first and then
  re-plans from the adopted workload's actual status.

### Volume lanes and the enqueue order (STR-148)

Volumes joined the engine as a third `WorkloadKind` rather than a forked
planner: the staleness guard, the retry policy, the failure classification and
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
grow lands before an attachment *moves*, and an attachment that is merely
*wrong* is unplugged before it is re-plugged elsewhere. A desired **removal** of
the attachment is the one inversion and outranks a pending grow, because the
detach is what makes the grow possible: the agent refuses to grow an image a
guest may still hold open and names two remedies, and with the resize planned
first only "stop the guest" could ever run — the refused resize was the only
step planned, so the detach that would lift it was never reached (STR-199). Two
things are deliberately not steps at all — a shrink and a format change —
because neither is something the agent can converge, so they surface as
permanent failures rather than as work that silently never completes.

A size the agent could not read plans a `.resize` too, last, after every other
difference is settled. It never grows anything — the actuator refuses it as
`blocked` naming the unreadable image — but planning *nothing* was worse than
it looked: the item is still emitted whenever the generation is newer, and an
item that runs no steps records its generation as applied, so a resize whose
current size was never successfully probed reported as converged.

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
permanent suppression and transient backoff — nothing can mint a new
generation for a workload with no record, so a suppressed failure would leak
the stray forever.

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
  so a surviving workload is really destroyed rather than abandoned. The failure
  is then classified by `OrphanDeleteAdoption.classify` (in `StratoAgentCore`,
  so the table is unit-tested): only `adoptionTargetGone` — nothing behind the
  VM's name on the host — reaches the driver's `reclaimVMDirectory`, and it runs
  *before* the manifest entry is released, since that entry is the host's last
  record the VM existed. Every other failure is ambiguous (the VM may be alive
  and merely unreachable) and keeps the older contract: release the entry, log,
  leave the files for manual cleanup.
- **A VM the driver holds no session for.** For QEMU this case is gone with the
  process driver: libvirtd is the durable record, so `deleteVM` looks the domain
  up by name and a `SHUTOFF` or absent one is simply undefined and reclaimed.
  The Firecracker driver still has the shape, one layer down, where
  `FirecrackerClient.destroyVM` throws for a VM it does not track; it asks the
  VM's deterministic API socket whether anything is still running from that
  directory: a socket that answers is torn down for real (so the delete
  converges), one that refuses outlived its process, and only a connect that
  hangs is ambiguous enough to fail the delete and be retried by the next sync.

For Firecracker the evidence is the socket, not the process, so an *absent*
socket is the weak case — it is the ordinary trace of a VMM that exited and
unlinked it, but also what a still-running VM created before deterministic
sockets (#260 / #433) looks like. The driver treats it as gone and logs it at
`warning`, matching what `Agent.adoptVM` already does with the same error (it
re-creates from the manifest spec, over the very same disks).

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
re-adopted by the reconciler where the backend supports it (QEMU by asking
libvirtd for the domain, Firecracker via its API socket).

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
Only QEMU VMs whose persisted `VMSpec.guestAgentEnabled` is true claim a CID;
older or disabled typed manifests ignore stale values, while quarantined entries
still reserve every salvageable CID because their full spec cannot be trusted.
Allocation is idempotent per VM (the re-create-an-orphan path runs the same code
twice), released when the VM's manifest entry goes, and rolled back when a create
fails — via a `VsockCIDLease`, so the "don't free a CID this create didn't take"
rule lives in the allocator rather than at each call site. Exhaustion **throws**,
classified `.permanent` so the reconciler reports it instead of burning a retry
budget on a create that only another VM's deletion can unblock.

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

For opted-in QEMU VMs, `DomainXMLBuilder` emits a fixed-address
`<vsock model='virtio'>` device using that leased CID. The host connects through
the kernel AF_VSOCK transport; `/dev/vhost-vsock` is the QEMU/libvirt backend,
not a per-VM Unix socket. `HostPreflight` checks that character device on Linux
and reports the `vhost_vsock` transport as unsupported, not failed, on other
platforms.

### VM guest control daemon (STR-77)

`sandbox-guest/init/Cargo.toml` produces two Linux executables from one Cargo
package. `strato-sandbox-init` remains PID 1 for Firecracker sandboxes;
`strato-guest-agent` is a normal service inside an already-booted QEMU VM. Both
use `strato_sandbox_init::protocol`, so `ping`, `get_status`, exec requests,
PTY/stdin/resize frames, output, and exit messages have one Rust definition and
one portable test suite. The VM daemon adds no crate dependency.

The VM daemon binds only AF_VSOCK port 1024 and rejects any peer CID other than
`VMADDR_CID_HOST` (2). It never opens a guest network listener. `ping` and
`get_status` use `/etc/machine-id` in the protocol's historical `sandbox_id`
field and Linux's boot id as `nonce`; that nonce survives a service restart but
changes when the VM reboots. Every response, including each exec-stream record,
echoes it so the later host bridge can pin a session to one guest generation.
The status is `running` while the daemon is serving. Sandbox-only launch,
reidentify, clock, and log-follow operations are refused.

Exec runs as the service account (root in the packaged systemd unit), defaults to
`/`, and inherits the service environment with request entries overlaid. Pipe
sessions use a dedicated process group; TTY sessions use a new session and
controlling PTY. Closing the host connection before `exec_exit` kills that
group. Unlike the sandbox init, the daemon owns and waits for each child itself
because it is not PID 1. STR-80 packages it as
`strato-guest-agent-<arch>.tar.gz` with a systemd unit and publishes
`guest-agent-manifest.json`; STR-82 owns the node-agent vsock bridge. Until that
bridge lands, the agent does not advertise
`HypervisorSupport.supportsGuestExec`; the control plane therefore returns 503
before minting a VM exec session rather than handing the browser a session the
agent will immediately reject.

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

### Chassis service foot (IMDS and the DNS resolver)

The chassis-local half of a network's link-local services is planned by
`StratoAgentCore/ChassisServicePlan.swift`: the OVS internal port and
per-network namespace (`strato-md-<network-uuid>`) that terminate them on this
host, kept a pure plan (like `SandboxNetnsAttachmentPlan`) so the command
sequence stays unit-testable, and executed by `NetworkServiceLinux`.

Two services share it — instance metadata (wire v27, STR-49) and the network's
DNS resolver (wire v37, STR-40) — and its input is the agent's own workload
specs (`NetworkSpec.metadataEnabled` / `.resolverEnabled`), not the `networks`
list: it must exist on every chassis running a NIC on the network, including
sited non-controller agents, which receive an empty `networks` list by design.
An `ip`-invoked `tc` ingress policer caps the packet rate guests may push at the
interface, because what it protects is the hypervisor rather than the service.

The resolver has the same two halves, but its second one lands in the **host**
namespace on a port of its own (§Per-network resolver) — a resolver has to
forward and a chassis namespace has no egress, which is
[ADR 0008](../adr/0008-resolver-in-host-namespace.md). Metadata stays here
because source-IP attribution is its security model and it needs no egress at
all.

The `NetworkReconciler` converges both OVN `localport`s from
`DesiredNetworkState`'s two flags on authoritative agents, and
`serviceLocalPortProtection(for:)` shields each existing port from teardown when
the sync has no opinion about *its* service (a pre-v27 control plane's silence
must not delete live metadata ports; a pre-v37 one's silence about the resolver
must not stop `metadataEnabled: false` from working, nor reap a resolver port it
has never heard of).

The metadata listener is a helper process the agent forks per namespace
(STR-56), because `setns(2)` is per-thread and does not compose with Swift
concurrency — the cost ADR 0003 deferred. The resolver needed no such helper once
it left the namespace: one CoreDNS serves every network on the host. See
[ADR 0003](../adr/0003-imds-chassis-namespace.md),
[ADR 0008](../adr/0008-resolver-in-host-namespace.md) and
[networking](./networking.md).

### Per-network resolver

`StratoAgent/ResolverSupervisor.swift` runs **one** CoreDNS for the whole host,
in the host network namespace, with one server block per resolver-enabled network
this host has a NIC on, bound to that network's own address pair (STR-40). One
process rather than one per network because the addresses are distinct — which is
what moving out of the chassis namespace forced, and what
[ADR 0008](../adr/0008-resolver-in-host-namespace.md) records. That a single
CoreDNS will serve the same zone name from different bind addresses with
different contents was verified empirically before the design relied on it.

`StratoAgentCore/ResolverHostPortPlan.swift` is the foot: pure `NetnsCommand`
plans that attach the OVS internal port, assign the addresses, and install the
per-network policy routing (`ip rule from <resolver-address> lookup 20000+index`)
that gets replies back out the right port — the one job the namespace used to do
for free. Rules are deleted before being added so a re-reconcile cannot stack
duplicates, and torn down before the OVS detach so one never outlives its port.
Forwarding is disabled on the interface for both families, `rp_filter` is loose,
`arp_ignore`/`arp_announce` keep the host from answering ARP there for addresses
on its other interfaces, `accept_ra` is off, and the same `tc` ingress policer
the metadata foot carries caps what guests may push at it. All of them are
asserted in tests rather than left to review. The loose `rp_filter` is only
effective when `net.ipv4.conf.all.rp_filter` is not `1` — the kernel takes the
max of the global and per-device values — so the preflight reports that rather
than the agent weakening a host-wide setting.

The supervisor takes its host effects through an injected `ResolverHosting`, the
shape `MetadataServerSupervisor` uses for the same reason: adoption, the
stop/reconcile race, and whether the failure counter actually escalates are
lifecycle questions that cannot be asked of an actor that forks processes
directly. `StratoAgent/ResolverProcessHost.swift` is the real one. It supervises
a single process, so a Corefile a new network makes CoreDNS refuse takes every
network's resolver with it — bounded by OVN still answering A/AAAA/PTR first, and
by the renderer refusing to emit a record it cannot render safely.

The decisions live in two pure types the tests can reach:
`StratoAgentCore/CoreDNSZoneRenderer.swift` produces the `Corefile` and zone
files (golden-tested, like `CloudInitProvisioner.networkConfigYAML`), and
`ResolverSupervisionPolicy.swift` decides what to write, when to start, and how
long to back off.

Two skips keep a steady-state sync cheap, and they are independent.
`ResolverRenderKey` — the control plane's per-zone `recordsHash` plus the
upstreams, search domain and bind addresses — decides whether to *build* the
files at all, which matters because a zone's records span every VM on every
attached network fleet-wide, so the render's cost grows with the cluster rather
than with this host. `DesiredResolver.configurationDigest` then decides whether
to *write* them, so a hash that moved without changing what this backend emits
reaches neither the disk nor CoreDNS's file watch. Both keys cover every network
at once, because there is one configuration.

**The failure counter is cleared by a run, not by a spawn.** Every failure the
backoff exists for — a Corefile CoreDNS refuses to parse, `:53` already held by
an orphan — forks cleanly and exits a moment later, so resetting on a successful
spawn would pin the delay at its first step and the crash-loop threshold would
never be reached. Exits are noticed on the next reconcile rather than from a
callback, which keeps the accounting deterministic, so the handle carries the
*moment* it exited: measuring to when it was noticed would make a child that died
instantly look like one that ran for a five-minute sync interval. Zone files live
under `<config_dir>/zones/<network-uuid>/` — namespaced by network because two
networks may hold a zone of the same name with different contents — derived from
the network id per the `VMDirectoryLayout` convention, which is what lets a
restarted agent rederive them all and reap directories for networks it no longer
serves.

A record edit costs no restart: files are written atomically, the `file` plugin
watches them, and the Corefile carries `reload`. Adding or removing a *network*
does not either, for the same reason — the server blocks live in the watched
Corefile. A restarted agent **adopts** a CoreDNS its predecessor started rather
than replacing it, verified by pid liveness plus a `/proc/<pid>/cmdline` check,
because killing it would cost every network on the host its resolver for a
process start for nothing.

The host reports whether it can run one at all as
`AgentRegisterMessage.resolverCapable`, and the control plane folds that across
the whole site before enabling any network's resolver. See [dns](./dns.md).

### Instance metadata store (IMDS payload)

`StratoAgentCore/MetadataStore.swift` holds what that service will serve:
one `InstanceMetadata` per VM (wire v26, STR-52), written by the reconciler
from each sync's `DesiredVMState.metadata` before it plans anything.
Reads are answered entirely from here, with no control-plane round trip —
the same fail-static posture as the rest of the reconciler, and deliberate,
because a guest that cannot read its metadata may fail to boot.

**That guarantee once held only for the life of the agent process.** The
store is in memory while the VM manifest is durable, so a restarted agent
re-adopted running VMs it could serve nothing for until the first sync
landed, and indefinitely if the control plane was unreachable then — the same
outage the design claims immunity to, arriving through the other door.
STR-56 closes it from both ends, because the two halves answer different
failures. `MetadataSnapshotStore` writes the records beside the VM manifest
(`instance-metadata.json`, mode `0600` — it holds SSH keys and user data), so
a restart keeps serving what the last sync said. And `origin()` reports
whether anything is known at all, so a host with neither a sync nor a
restorable file answers **503**, never a confidently empty document. Export
carries withdrawn records too: they hold no payload but they hold the
generation that refuses a replay, and dropping them at the file boundary
would resurrect a released VM's metadata once per agent restart.

**Everything restored is provisional until the first sync arbitrates it.**
The file records what the control plane said last time this agent ran, and a
VM can be deleted and reaped while the agent is down — in which case no sync
ever carries the `wantsAbsent` entry that would withdraw it and no teardown
runs, so nothing would ever reach the record. `confirmRestored(namedBy:)`
retires any restored record the first authoritative sync does not name.
Retired means **withdrawn, not deleted**: a tombstone stops the payload being
served while keeping the generation that refuses a replay, where deleting
outright would fix the disclosure and reopen the resurrection. This is the one
place the store departs from STR-98's "omission is not an instruction" — that
rule protects records a sync vouched for, and cannot be extended to records
inherited from a file that no sync has.

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

A nil `metadata` on a desired entry is authoritative and withdraws what we
serve for that VM.

### Firecracker MMDS (a refreshed snapshot)

Firecracker VMs use the same `MetadataStore` and EC2 renderer, but a different
transport (STR-67). `FirecrackerService.createVM` opts each
`metadataEnabled` NIC into MMDS by its Firecracker interface id (`eth0`,
`eth1`, ...), configures **MMDS v2**, and pushes the nested `/latest`
document from the generation-guarded store before the VM boots. MMDS terminates
inside Firecracker, so this path does not need an OVN localport, network
namespace, host listener, or any other host networking. A NIC not named in the
MMDS configuration cannot reach it.

The interface allow-list is Firecracker pre-boot configuration. Editing a
Firecracker VM's per-NIC `metadataEnabled` policy therefore replaces the VMM
process against the same managed disks and TAPs, installs the new allow-list,
and restores the desired running/paused/shutdown state. The operation interrupts
a running guest; it does not recreate its storage or network identity. This is
the enforcement path that prevents a disabled NIC from retaining MMDS access.

Unlike the OVN listener below, MMDS is **not a read-through view** of
`MetadataStore`. It is a per-VMM snapshot replaced with `PUT /mmds`. After
each desired-state sync records metadata, the agent re-renders the store's
generation-guarded value and replaces each managed Firecracker VM's MMDS
snapshot; equal-generation metadata-only edits therefore propagate, and a nil,
withdrawn, disabled, or agent-globally-disabled document replaces the old
snapshot with an empty object. The service caches the last successfully pushed
bytes only to avoid an identical PUT. Re-adoption performs the same refresh
from the durable metadata store immediately, then normal syncs remain the retry
mechanism.

That copy boundary is an intentional semantic difference: metadata mutations
become visible to a Firecracker guest **no sooner than the agent applies the
desired-state sync**, and the guest reads the last successful snapshot between
syncs. Freshness is thus bounded by desired-state sync cadence rather than
request time. This applies to Firecracker **VMs only**. Sandboxes are not
cloud-init consumers and keep their separate `SandboxConfigDrive` guest
contract; the sandbox runtime never configures MMDS.

### Instance metadata server (the guest-facing listener)

`StratoAgentCore/MetadataService/` is what guests actually talk to (STR-56):
an HTTP listener on `169.254.169.254:80` and `[fd00:ec2::254]:80`, one per
network, answering from the store above. It changes nothing on the wire.

**One child process per namespace.** ADR 0003 puts each network's metadata
interface in its own namespace and leaves this issue to decide how a listener
gets in there. The agent starts `ip netns exec strato-md-<network>
strato-agent metadata-server --network-id <uuid>` — the same binary under a
hidden subcommand, so the updater still replaces one file — and the child is
simply *in* the namespace and binds normally. The alternative, entering the
namespace in-process, needs `setns(2)`, which Swift's Glibc overlay does not
export at all (it would have meant the repo's first C target) and which is
per-thread, so a failed restore would strand a thread of the shared
concurrency pool in a tenant namespace. The child also buys fault isolation
where it matters most: this is the only code in the agent parsing bytes a
guest chose, and a crash costs one network's listener rather than the
reconciler.

**Push, not pull.** The agent pushes each network's servable slice down the
child's stdin as length-prefixed JSON (`MetadataControlProtocol`) on every
sync; the child answers entirely from its own copy, with no request-time call
back to the parent. Same fail-static reasoning as the store: a wedged or
restarting agent must not become a hung metadata service. The child exits on
stdin EOF, so a dead parent leaves no orphan answering guests unsupervised,
and a child is only handed the instances on *its* network — a listener cannot
leak what it was never given. `MetadataServerSupervisor` converges the fleet
from the same `metadataNetworks` list the chassis reconcile consumes (nil ≙ no
opinion, empty ≙ stop everything), after the reconciler has run so the
namespaces exist *and* the snapshot is current. Syncs are the retry timer:
a listener that failed to start is simply not running, and the next sync tries
again.

**Listeners come up before the first sync**, from the `strato-md-*` namespaces
already on the host. Without that the durable copy above would be pointless:
its purpose is to keep answering across a control-plane outage that spans an
agent restart, and until a sync landed there would be no listener to answer
with — guests would get connection refused, and `.restored` would be a state
nothing could observe. The namespaces are the right source because they are
host state that outlives the process (created by the chassis reconcile, cleared
only by a host reboot). A network removed while the agent was down leaves a
stale namespace and so starts an unwanted listener; the first sync stops it.

**Session auth is mandatory for ordinary reads.** `PUT /latest/api/token` with an
`X-aws-ec2-metadata-token-ttl-seconds` header (1..21600) mints an opaque
bearer token; every ordinary read requires `X-aws-ec2-metadata-token`. There is
no general unauthenticated mode — AWS shipped IMDSv1 optional and spent years
unwinding it, and there was no compatibility debt here to justify repeating that. The
barrier is the shape of the mint, not the name of the header: a request-forging
bug inside a guest can reach a link-local URL but cannot make it a `PUT`
carrying a custom header. `GET /latest/api/token` answers 405 and mints
nothing. EC2's header spellings are used rather than Strato-prefixed ones so
stock guest tooling can complete the handshake at all; see
[ADR 0006](../adr/0006-imds-session-auth.md).

The one protocol adapter is the NoCloud `seedfrom` tree at
`/latest/nocloud/<per-VM capability>/`. Stock NoCloud cannot perform the
IMDSv2 handshake, so those exact `meta-data`, `user-data`, and
`network-config` GETs use a random capability embedded in the seed ISO. The
responder still binds the request to the source VM and applies its kill switch;
ordinary `/latest/*` reads stay token-only. Request logging replaces everything
after `/latest/nocloud/` with `[redacted]`.

**The caller is its source address, and the session is bound to it.**
`MetadataCallerIndex` resolves `(this namespace's network, source address) →
vmId` from the served metadata's own `MetadataNIC` entries — the allocated v4
and v6 addresses plus the EUI-64 link-local derived from the NIC's MAC, all
three of which are inside OVN's `port_security` — so an authentication
decision never depends on a second source of truth. An address claimed by two
instances resolves to *neither*, loudly: that is ADR 0003's named silent
failure, and it is reachable whenever a deleted VM's address is reallocated
before its withdrawal lands. A token records the instance it was minted for
and is refused when anyone else presents it, so stealing a neighbour's token
buys nothing. Tokens are stored as SHA-256 digests, which is why no
constant-time comparison is needed: nothing here ever compares a secret.

**Verdicts.** 503 + `Retry-After` while the store is `.cold` (checked *before*
identification: with no knowledge, 404 would assert something the agent cannot
know); 404 for an unresolvable or ambiguous caller, and for a withdrawn
instance; 404 for an instance whose metadata kill switch is thrown; 401 for a
missing, expired, or wrong-instance token; 404 for an unserved path, but only
*after* authentication, so nothing that merely reaches the address can map the
tree.

**The kill switch is checked after identification and before the handshake**
(STR-185). After, because there is no way to know whose switch to read until
the caller has a name; before, because a switched-off instance must not be able
to mint a session it could never spend. Its 404 is `.unknown`'s answer verbatim,
so a guest cannot learn that it was singled out. Note what this is *not*: the
control plane keeps sending the document and the instance stays in
`MetadataCallerIndex`, because dropping it from the servable set would take its
addresses out of the index — and the collision that resolves `.ambiguous` today
would then resolve to the neighbour whose identity it was hardened away from.
Throwing the switch also retires the instance's live sessions on the next push
rather than leaving them to expire.

**Responses carry a hop limit of 1** (`IP_TTL` / `IPV6_UNICAST_HOPS`, set on
the listener and on each accepted child). The guest is one L2 hop away — both
advertised routes are on-link with a zero next hop — so a reply that crosses
any router dies, and a guest cannot proxy metadata off-box.
`metadata_response_hop_limit` raises it; `metadata_service = false` turns the
listener off without touching the dataplane, which is a property of the
network rather than of the agent.

**NoCloud-net reuses the full-seed document renderer byte for byte.** Below the
per-VM seed capability, the exact file names are `meta-data`, `user-data`, and
`network-config` (404 when no NIC needs a network document). The ordinary
IMDSv2 paths remain `/latest/meta-data`, `/latest/user-data`, and
`/latest/network-config`. The
no-trailing-slash metadata path matters: `/latest/meta-data/` remains the EC2
index proved by STR-56. The EC2 projection below it exposes only values the
shared `InstanceMetadata` can state truthfully: instance identity and hostname,
SSH keys, per-NIC addresses and network identity, safe instance tags, and the
instance-identity document under
`/latest/dynamic/instance-identity/document`. It does not invent AMI, instance
type, VPC, or interface identifiers. Directory listings follow EC2's nested
shape (including the `0=<name>` public-key index), so stock EC2 datasource
crawlers can discover the leaves rather than depending on a second endpoint
tree. Placement is a renderer policy and defaults to hidden; enabling it adds
region and availability zone to both the metadata tree and identity document.

Both projections, and `/latest/user-data`, render from the listener's latest
`InstanceMetadata` snapshot, so an applied metadata sync changes the next HTTP
response without rebuilding guest media. The EC2 and NoCloud surfaces are
therefore different serializations of one current value, not independently
maintained metadata stores.

**Bounds, because the peer is untrusted guest code that can retry forever:**
a raw-byte cap in front of the HTTP decoder (`ByteToMessageHandler`'s
`maximumBufferSize` does *not* cover this — NIOHTTP1's decoder consumes each
header line as it arrives, so a long header list never trips it while
`HTTPHeaders` grows behind it), a read-idle timeout, connection caps counted at
accept — a total per listener and, load-bearingly, a per-source-address one,
since a namespace is shared by every guest on the network and one VM holding
the whole budget would deny its neighbours the service — and outright refusal
of any request carrying a body.
The request log records method, target, status and source — never a token, not
even a prefix.

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

The API socket client (`UnixSocketHTTPClient`) pairs responses to requests in
pipeline order, so a round trip that times out has to take the whole channel
with it — a request abandoned mid-queue would mis-pair everything behind it.
What it must not take with it is the client: the next request **redials**
(never replaying the failed one), because without that a single unanswered
request left the agent unable to reach that microVM's API for the rest of its
life, and a still-running sandbox could only be deleted (STR-194). An explicit
`disconnect()` revokes the redial — by then the socket path may belong to a
different VM. The request deadline sits deliberately *above* Firecracker's own
30s `RECV_TIMEOUT_SEC`, so a VMM whose vCPUs are slow to acknowledge a
pause/resume answers with its real fault message instead of losing the race to
an identical host-side ceiling.

## Tests

`agent/Tests/StratoAgentTests/` (~68 files) mirrors the Core units:
reconciliation (VM + sandbox), config/state/URL handling, message ordering,
the storage backends, the manifest store, the updater and its gate, the
full OCI suite, the sandbox suite (config drive, control protocol, jail,
log assembly), and networking (attachments, reconciler, OVN bootstrap,
DHCP, gateway planning).
