# ADR 0005: The agent drives libvirt rather than QEMU directly

- **Status**: Accepted — driver landed STR-133/134/135; the process driver and
  everything that existed to serve it deleted in STR-136
- **Date**: 2026-08-08
- **Deciders**: Sam Schmitt
- **Scope**: how a hypervisor node realizes a `HypervisorType.qemu` placement;
  the host dependencies that follow; the macOS agent
- **Affects**: STR-133 (driver), STR-134 (parity), STR-135 (lifecycle events),
  STR-136 (deletion), and issue #902 (the per-node rollover key, now retired)
- **Does not affect**: Firecracker, which the agent still launches and drives
  itself. The reasoning below is about *QEMU*, whose management surface libvirt
  is a mature implementation of; Firecracker's is a small REST API with no
  equivalent daemon and no equivalent problem.

## Summary

The agent manages QEMU VMs as **libvirt domains** over `qemu:///system`, using
swift-libvirt (libvirt's RPC wire protocol over NIO, no C library linked). It
does not spawn `qemu-system-*`, does not open QMP monitors, does not speak the
QEMU guest agent protocol, and does not supervise swtpm.

The driver it replaces did all four. Deleting it removed roughly 4,000 lines
whose entire job was to reimplement, less well, primitives libvirt already
ships. What it cost is a second daemon on every hypervisor host with a version
floor, a privilege boundary that has to be configured, domain XML as an artifact
the agent owns and tests, and — until a native Virtualization.framework driver
exists — no QEMU driver on macOS at all.

## Context

Strato's agent originally launched QEMU itself. That is a defensible starting
point: one process, no daemon, and the agent's own `Process` supervision. The
cost only shows up as the feature set grows, and it showed up as a specific,
repeating shape — **every VM management primitive beyond "start a process" turned
out to need a channel the agent had to build itself.**

By the time the process driver was complete it carried:

- **Three QMP monitor sockets per VM.** A QMP server socket admits one client at
  a time. The spawning session held a private monitor; re-adoption after an
  agent restart needed a second at a deterministic path (`qmp.sock`), because a
  process the agent did not spawn cannot be attached to any other way; and
  balloon statistics, CPU hot-plug and virtio-mem resize needed a *third*
  (`qmp-stats.sock`) because the first two were occupied. Each came with its own
  greeting and `qmp_capabilities` handshake.
- **A hand-written QEMU guest agent client** — 1,600 lines across a transport, a
  brace-counting JSON object framer with a resumable scan cursor, a
  `guest-sync-delimited` resync protocol, and typed command models — to ask a
  guest its hostname and addresses, and to request a verified shutdown.
- **An swtpm supervisor**: one `swtpm socket --tpm2` per VM, spawned with
  `--daemon` so it reparented to init and outlived the agent, with its own state
  directory, control socket, pid file and liveness check. A swtpm that died
  under a live QEMU could not be reattached; the VM needed a stop/start.
- **Bookkeeping for an ephemeral process.** `activeVMs`, `vmSpecs`, `vmConfigs`,
  spawn sizing, awaiting-first-start flags, console socket maps, a respawn path.
  All of it existed because the agent was the only thing that knew what it had
  spawned, and anything it forgot was unrecoverable.
- **A diagnosis problem.** QEMU reports a rejected argument on stderr and exits
  *after* opening its first QMP socket, so a bad device line surfaced as a bare
  QMP connect timeout naming nothing. Issue #740 is an invalid `virtio-balloon`
  argument that killed every VM boot on a host while reporting only that. The
  fix was draining QEMU's stderr into a bounded tail buffer — a thing libvirt
  already writes to `/var/log/libvirt/qemu/<domain>.log` for every domain.

Every one of those is a libvirt primitive. libvirt owns the monitor and
multiplexes access to it, so re-adoption is `connectListAllDomains` plus a state
read rather than a mechanism. It relays the guest agent over the domain's own
channel, so `domainGetGuestInfo` and `domainInterfaceAddresses(source: AGENT)`
replace the whole transport. It starts and supervises swtpm from a `<tpm>`
element. It is a durable store, so domains survive the agent and there is
nothing to remember. And it logs QEMU's own output per domain.

The trigger for revisiting this was checkpoints. A full-VM checkpoint is an
internal snapshot of a running domain, and doing it by hand over QMP means
enumerating block nodes, deciding which are capture targets, and sequencing
`snapshot-save`/`snapshot-load` around them — 1,000 lines of rules whose
correctness is difficult to establish and impossible to test without a
hypervisor. libvirt's system checkpoint is one call, and it chooses the disks.

## Decision

**The agent drives libvirtd at `qemu:///system`, and that is the only QEMU
driver.**

### 1. swift-libvirt, not the C library

The client speaks libvirt's RPC wire protocol over NIO. It is pure Swift with no
system dependency, which is what lets the driver's pure layer — the domain XML
builder, state mapping, error translation, memory-stat parsing — live in the
agent's testable core target rather than beside a linked SDK.

### 2. The domain document is the interface, and it is written once

`createVM` calls `domainDefineXML` and nothing redefines it. That single fact
propagates: every in-place mutation is sent with `AFFECT_LIVE|AFFECT_CONFIG` so
it lands on the running guest *and* in the definition the next boot reads, and a
resize the guest cannot take online is written to `CONFIG` alone rather than
deferred to a boot that would not pick it up.

`DomainXMLBuilder` is therefore an owned artifact, tested against eight golden
documents that are validated three ways: against the RELAX-NG schema of libvirt
11.5.0 and 12.6.0, by `virsh define --validate` (which runs libvirt's own parser
*and* the QEMU driver's checks), and — for three of them — by starting the domain
for real under `virtqemud`.

### 3. libvirt's reachability *is* QEMU availability

There is no binary probe left. libvirtd selects the emulator from its own
capabilities, so a `qemu_binary_path` would have no consumer and no meaning.
`HypervisorProbe` reports `.qemu` available on Linux and leaves the verdict to
the host preflight, whose libvirt checks are gating: an unreachable daemon, or
one below the version floor, demotes `.qemu` to unavailable so the node stops
attracting placements it cannot serve.

### 4. libvirt ≥ 11.5, gating

Internal snapshots of a UEFI guest were impossible before 10.9; 10.10 fixed
revert and inactive-delete not accounting for the qcow2 NVRAM varstore; 11.2–11.3
carry a regression that breaks reverting to an internal snapshot. 11.5 is the
first release clear of all of it. A node below the floor does not advertise QEMU,
rather than advertising a checkpoint it cannot take. Ubuntu 24.04 ships 10.0.0
and is consequently not a supported hypervisor host.

### 5. Host facts are asked of libvirt, not of the filesystem

Whether a node can back a guest vTPM is `virsh domcapabilities` reporting a
`<tpm>` element with an `emulator` backend, not an `swtpm` binary the agent can
`stat`. On a containerized agent those are different questions — it sees its own
image, not libvirtd's host — and the libvirt answer is the one that decides
whether a domain starts.

## Alternatives considered

- **Keep both drivers.** This is what shipped through STR-133–135, behind a
  per-node `qemu_driver` key (issue #902), and it was the right way to *migrate*:
  nothing about the choice reached the control plane, so a fleet rolled over one
  node at a time and a node could be moved back by editing one line. It is a bad
  steady state. Two drivers for one `HypervisorType` means every capability is
  implemented, tested and reasoned about twice, and the weaker implementation
  sets the ceiling on what the control plane can assume.
- **Keep the process driver for macOS.** Tempting, because it is the only thing
  the deletion actually regresses. Rejected: it means keeping the whole QMP/QGA/
  swtpm apparatus, and every future VM feature implemented twice, to serve a
  dev/test host. The honest version is a native Virtualization.framework driver,
  which is separate work and a better macOS experience than QEMU-under-HVF was.
- **`libvirt:///session` instead of `qemu:///system`.** A per-user daemon would
  avoid the privilege boundary below. Rejected: session-mode domains cannot use
  the TAP interfaces the OVN dataplane hands them, which is not negotiable.
- **A thinner abstraction than domain XML** — driving libvirt but generating its
  document from a smaller intermediate. Rejected as a layer with no second
  consumer; the golden tests give the document the same regression safety a
  Swift model would, without the translation step.

## Consequences

### What this buys

- **Deletion.** `QEMUService` (1,868 lines), `AdoptedQEMUVM` (248), the QMP
  client and checkpoint-target rules (992), the entire QGA package (1,146), the
  swtpm supervisor (207) and two argv builders — plus eight test files that
  existed only to cover them, and the `swift-qemu` dependency.
- **Re-adoption stops being a mechanism.** It is a query against a daemon that
  outlived the agent. The deterministic second monitor socket, and the
  attach-to-a-process-we-did-not-spawn machinery behind it, have no counterpart.
- **Transitions are announced.** libvirt's domain lifecycle events mean a guest
  that powers itself off is reported in about a second rather than at the next
  20-second sweep (STR-135) — with no polling loop of the agent's own.
- **Diagnosis has a home.** A failed start is libvirt's error, propagated
  untranslated, plus QEMU's own output at
  `/var/log/libvirt/qemu/<domain>.log` — a file per domain, with the command
  line libvirt used at the top of each start.
- **One implementation of every capability**, which is what lets the control
  plane assume a QEMU node is a full-capability QEMU node.

### What this costs

- **A second daemon on every hypervisor host, with a version floor.** libvirtd
  is now a hard dependency and a new failure mode: a node whose daemon is down,
  unreachable, or too old is out of service for VMs. `deploy/agent/install.sh`
  provisions it and the host preflight gates on it, but the operational surface
  is real and did not exist before.
- **A privilege boundary to configure.** libvirt's QEMU driver would run QEMU as
  `libvirt-qemu:kvm` and chown each domain's disks to it, which collides with
  the agent owning every path under `/var/lib/strato`. Switching labeling off is
  *not* the fix — `security_driver = "none"` also stops libvirt preparing its own
  runtime artifacts (the swtpm control socket under `/run/libvirt`) for the QEMU
  uid, which fails the domain start outright. The installer instead points the
  DAC driver at the agent's account, writing three keys into
  `/etc/libvirt/qemu.conf`. That file is now part of a hypervisor node's
  configuration, and a hand-edited one is a support case.
- **Domain XML is an owned artifact.** The agent generates a document another
  project parses, against a schema that varies by version. The goldens and the
  three-way validation are the mitigation, and they are ongoing work: every new
  device or attribute needs re-validating against both ends of the supported
  libvirt range.
- **Some behaviour is fixed at create time.** The document is written once, so a
  VM's hot-plug slots (four spare `pcie-root-port`s) and its memory headroom are
  decided when it is created. Exceeding either fails with libvirt's error rather
  than growing the domain.
  ([issue #1026](https://github.com/samcat116/strato/issues/1026) tracks lifting
  this.)
- **libvirtd caches host capabilities.** Installing swtpm under a running daemon
  does not make a node TPM-capable until libvirtd restarts. This is a genuinely
  surprising operational edge; the preflight's remediation names the restart.
- **No QEMU driver on macOS.** libvirt is Linux-only, so a macOS agent registers
  `MockHypervisorService` and reports `.qemu` as *unavailable* — the scheduler
  places nothing on it, and the startup log says so plainly rather than letting a
  mock look like a hypervisor. This is a deliberate, temporary regression: the
  macOS agent is a dev/test host, and a native Virtualization.framework driver is
  separate work.

### Removed or demoted

- `qemu_driver`, `qemu_binary_path` and `swtpm_binary_path` are retired config
  keys. A config still carrying one starts and logs that it is ignored, rather
  than failing — an unattended fleet upgrade must not become a fleet-wide
  outage — and `qemu_driver = "process"` in particular can no longer change
  behaviour in silence.
- `ENABLE_QEMU_PROCESS_LOG_FILES` disappears with the `swift-qemu` package that
  read it.
- The QEMU guest agent's `guest-exec` path is gone. Nothing called it, and qga's
  exec model (a PID plus polling, no completion notification, no PTY, no further
  stdin, no way to signal a running process) could never have backed an
  interactive session. Sandbox exec goes through the Firecracker guest agent.
