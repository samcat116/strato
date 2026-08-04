# Wire Protocol (StratoShared)

The `shared/` package (library product **StratoShared**) defines everything the
control plane and agent agree on: the WebSocket message catalog, the
reconciliation contract, and the DTOs both sides serialize. It is the only
code shared between the two services — if a type crosses the socket, it lives
here.

The package deliberately has almost no dependencies (swift-nio is declared for
consumers; the sources themselves import only Foundation) and no I/O of its
own. It is a vocabulary, not a client.

## Envelope and encoding

Every WebSocket frame carries a `MessageEnvelope`
(`shared/Sources/StratoShared/WebSocketProtocol.swift`):

```swift
struct MessageEnvelope {
    let type: MessageType   // discriminator for dispatch
    let version: Int?       // sender's WireProtocol version
    let payload: Data       // inner message, JSON-encoded
}
```

- Encoding is **JSON end to end** — the envelope and the payload both go
  through the single pinned coder pair `WireProtocol.makeEncoder()` /
  `makeDecoder()`. Never use an ad-hoc `JSONEncoder` for wire types; date
  strategy compatibility depends on the pinned pair.
- Binary data (console output, exec stdin/stdout) travels as **base64
  strings** inside JSON messages, with `rawData` conveniences on the message
  structs.
- Every concrete message conforms to `WebSocketMessage`: a `type`
  discriminator, a `requestId` for request/response correlation, and a
  `timestamp`. Streaming messages (console, sandbox exec) correlate by
  `sessionId` instead and are never answered with success/error — ordering
  comes from the WebSocket itself (see the header comment in
  `SandboxExecMessages.swift`).
- Responses are the generic `SuccessMessage` (optional dynamic `data` via
  `AnyCodableValue`) and `ErrorMessage` (with machine-readable codes such as
  `unsupported_protocol_version`).

## Versioning

`WireProtocol.swift` holds the protocol version (currently 17), stamped on
every envelope and exchanged at registration
(`AgentRegisterMessage.protocolVersion` ↔
`AgentRegisterResponseMessage.protocolVersion`). A peer that omits the version
is treated as version 0.

Feature availability is expressed as pure per-version gates rather than
ad-hoc checks scattered through the code:

| Gate | Minimum version | Feature |
|---|---|---|
| `supportsStateSync` | 2 | Desired/observed state sync |
| `supportsNetworkSync` | 3 | Networks in the desired-state sync |
| `supportsSiteAuthority` | 4 | `networksAuthoritative` site-topology flag |
| `supportsSandboxSync` | 5 | Sandboxes in the desired-state sync |
| `supportsAgentUpdate` | 6 | Imperative agent self-update |
| `supportsDesiredAgentUpdate` | 7 | Declarative agent update in the sync |
| `supportsSandboxExec` | 8 | Interactive sandbox exec streams |
| `supportsSandboxSnapshots` | 9 | Sandbox snapshot/restore messages |
| `supportsSandboxFork` | 12 | Restore-into-new-identity sandbox forks |
| `supportsFloatingIPs` | 12 | Floating IPs in the network desired state |
| `supportsSandboxSnapshotMobility` | 14 | Off-node snapshot export + cross-agent restore/fork |
| `supportsVMResize` | 17 | Online vCPU/memory resize of a running VM |
| `supportsMachineProfile` | 18 | `VMSpec.machine` — Secure Boot and vTPM |
| `supportsGraphicsConsole` | 23 | `ConsoleSpec.graphics` + `ConsoleConnectMessage.stream` — the VNC console |

Version 13 has no gate: it switched image downloads from signed URLs to
relative paths fetched over SVID mTLS (issue #493), which older agents cannot
degrade around — they must upgrade.

Version 15 has no gate either: it added the QEMU guest agent (issue #563).
Both fields it introduces are optional and nil-tolerant in each direction —
`ObservedVMState.guestInfo` (the guest's observed hostname and per-MAC
addresses, agent → control plane) and `VolumeSnapshotMessage.attachedVMId`
(control plane → agent). A nil from an older peer reads identically to "not
known" and can never mean a destructive action, so no send-side gate is needed.
`attachedVMId` originally told the agent which guest to fs-freeze around a
snapshot; since issue #747 the agent uses it to *refuse* the snapshot, so the
field's meaning tightened without its shape changing.

Version 16 follows the same pattern: `ObservedVMState.memoryStats` (issue
#567) carries the guest's virtio-balloon memory statistics on the
observed-state report — optional, nil-tolerant both ways, informational only,
so no gate.

Version 17 adds CPU/memory hot-add (issue #568). The new spec field —
`VMSpec.maxMemoryBytes`, defaulting to `memoryBytes` — is additive and
nil-tolerant, but the *behavior* is not: a pre-v17 agent plans no work for a
generation that changed only sizing and reports it converged, so the resize
would silently succeed having changed nothing. Hence `supportsVMResize`: the
control plane refuses an online resize below it and tells the caller to
restart the VM. Resizing a stopped VM needs no gate, since the next boot
uses the whole spec.

Version 18 adds `VMSpec.machine` (a `MachineProfile` of `secureBoot` and
`tpm`, issue #565) plus `AgentRegisterMessage.tpmCapable`. The field itself is
additive and tolerant — a pre-v18 agent decodes the sync fine — but that is
precisely the problem: it would then boot the guest *without* Secure Boot or a
TPM and report success, and Windows setup would refuse to install with nothing
in the API explaining why. So this feature is gated on two signals rather than
one, exactly as `sandboxCapable` is at v5: `supportsMachineProfile` proves the
agent understands the field, and `tpmCapable` proves the host can actually
realize a TPM (swtpm installed). A v18 build on a host without swtpm answers
yes to the first and no to the second, which is why the version number alone
cannot stand in for the capability flag. The scheduler treats both as hard
constraints.

Version 19 adds operator balloon targets (issue #567 phase 2):
`VMSpec.balloonTargetBytes` outbound and `VMMemoryStats.balloonActualBytes`
back. The observed field follows v16's contract and needs no gate; the spec
field repeats v17's hazard, since a pre-v19 agent reports the bumped
generation converged without touching the balloon. Hence
`supportsBalloonTarget`, which the control plane refuses below — and unlike
v17 there is no "restart to apply" remedy to offer, because a balloon target
only exists on a running guest in the first place.

Version 23 adds the graphics console (issue #566): `ConsoleSpec.graphics`
outbound, which makes the QEMU driver give the guest a display device and a
`vnc.sock` in its VM directory, and `ConsoleConnectMessage.stream`, which picks
that socket over the serial one for a console session. Both are optional and
encode to nothing when unset, so a pre-v23 agent receives byte-identical JSON —
which is exactly the hazard, in v18's *silent* form rather than v22's
undecodable-envelope form. Ignoring `graphics`, the agent boots the guest
headless while the API reports a display; ignoring `stream`, it answers a
graphics connect with the serial socket, and noVNC hangs reading kernel log
text where it expects `RFB 003.008`. Hence `supportsGraphicsConsole`, enforced
both at placement and again when a console session is minted (an agent can be
downgraded after its VMs were placed). Unlike v18 it needs no registration
capability beside the version: placement already restricts to QEMU-capable
agents, and a QEMU built `--disable-vnc` fails the create loudly.

The byte-identity above is a property of the *production* path, not just the
type: `VMSpecBuilder` sends `nil` rather than an explicit `"None"` for a
headless VM, so the key is genuinely absent from every spec a headless VM
produces. `GraphicsMode` itself decodes strictly, following `DesiredVMStatus` —
but note the blast radius, since a `DesiredStateMessage` is decoded in one
shot: a future unknown mode fails the *whole* sync for that agent and stops it
converging on everything, not just the VM that carried it. The version gate is
what keeps that unreachable.

The doc comment on `currentVersion` is a narrative changelog of every bump —
read it before adding a version. Adding an enum case to a strictly-decoded
wire type (see `DesiredVMStatus` below) also requires a version bump and a
dual-mode rollout.

## Message catalog

`MessageType` in `WebSocketProtocol.swift` is the master list. By direction:

**Control plane → agent**

| Message | Purpose |
|---|---|
| `agent_register_response` | Registration reply: assigns the agent's DB UUID and name, echoes the protocol version |
| `desired_state` | The authoritative `DesiredStateMessage` sync (see below) |
| `vm_reboot` | Reboot — still imperative because a reboot is an action, not a state |
| `vm_checkpoint`, `vm_restore`, `vm_snapshot_delete` | Full-VM checkpoints (v22+, issue #564): RAM + device state + disks as a qcow2 internal snapshot. Imperative for the same reason — a checkpoint is an action, not a state. Gated on the `vm_checkpoint` capability, since only a QEMU-capable agent can realize them |
| `vm_create`, `vm_boot`, `vm_shutdown`, `vm_pause`, `vm_resume`, `vm_delete`, `vm_info`, `vm_status` | **Deprecated** imperative VM lifecycle (issue #261), superseded by desired-state sync; kept for older control planes |
| `network_*` (create/delete/list/info/attach/detach) | Network operations |
| `volume_*` (create/delete/attach/detach/resize/snapshot/snapshot_delete/clone/info) | Volume operations (QEMU-backed VMs only) |
| `console_connect`, `console_disconnect`, `console_data` | Console session control and input. `console_connect.stream` picks the serial console (default) or the VNC framebuffer (v23+) |
| `sandbox_exec_start`, `sandbox_exec_input`, `sandbox_exec_resize`, `sandbox_exec_close` | Interactive exec into a sandbox (v8+) |
| `agent_update` | Imperative agent self-update (v6+) |

**Agent → control plane**

| Message | Purpose |
|---|---|
| `agent_register` | Handshake: hostname, version, capabilities, resources, hypervisor support, architecture/OS, `sandboxCapable`, protocol version |
| `agent_heartbeat` | Periodic resource usage and running VM IDs |
| `agent_unregister` | Graceful disconnect with a reason |
| `observed_state` | Level-triggered `ObservedStateReport`: VM/sandbox observed state, resources, agent-update status, optional per-VM `guestInfo` from qga (issue #563), and optional per-VM balloon `memoryStats` (issue #567, incl. `balloonActualBytes` at v19) |
| `status_update` | Push notification of a VM status change |
| `vm_log`, `sandbox_log` | Log lines destined for Loki |
| `console_connected`, `console_disconnected`, `console_data` | Console session lifecycle and output |
| `sandbox_exec_started`, `sandbox_exec_output`, `sandbox_exec_exit`, `sandbox_exec_closed` | Exec stream responses |

**Either direction**: `success` / `error`, correlated by `requestId`.

## The reconciliation contract

`shared/Sources/StratoShared/ReconciliationProtocol.swift` defines the
desired/observed state sync — the core of the control loop described in
[overview](./overview.md). Its doc comments are the authoritative prose on the
design; the short version:

### Desired state

- `DesiredVMStatus`: `running` / `shutdown` / `paused` / `absent`. It is a
  goal, never a report — there are no transitional or diagnostic cases.
  Decoding is **strict** (unlike the tolerant `VMStatus`): misreading a
  desired status could stop or delete a live VM, so an unknown value fails
  the decode rather than degrading. `isSatisfied(by:)` encodes convergence
  rules — e.g. `.shutdown` is satisfied by an observed `.shutdown` *or*
  `.created`, and `.absent` is only ever confirmed by the VM's omission from
  the observed set.
- `DesiredVMState`: the VM's ID, pinned `hypervisorType`, full `VMSpec`,
  desired status, a **generation** counter, and optional `imageInfo` whose
  download URLs are control-plane-relative paths the agent fetches over
  SVID mTLS (issue #493) — nothing in them expires.
- `DesiredSandboxState` mirrors it for sandboxes (with an optional registry
  credential); `DesiredNetworkState` reconciles OVN logical networks
  (switch/subnets/gateways, per-project `routerKey`, SNAT, DHCP, and an
  optional `floatingIPs` list — external→fixed address mappings plus
  `vmId`/`nicIndex` for the NIC's port, realized as `dnat_and_snat` rules,
  issue #344); `DesiredAgentUpdate` is the declarative agent-update target.

### Generations

Each desired record carries a monotonic per-resource `generation`, bumped by
the control plane on any spec or status change. The agent records the last
generation it applied and ignores older ones, so dropped, replayed, or
reordered syncs can never roll a resource backward. The observed side reports
`observedGeneration` (what it last converged toward), a `convergencePhase`
progress string, and on failure a `lastError` paired with `failedGeneration` —
the control plane only fails a pending operation when `failedGeneration`
matches the current generation, which prevents attributing a stale error to a
newer change.

### Level-triggered, full-list sync

`DesiredStateMessage` carries the **complete** desired lists (`vms`,
`sandboxes`, `networks`) for the agent, plus `networksAuthoritative` and
`syncId` for tracing. Semantics:

- Anything omitted from the list should not exist on the agent — but omission
  is not the *instruction* to remove it. See "Omission is not teardown" below.
- Identical syncs diff to nothing; the message is safe to drop, replay, or
  reorder (generations guard the reorder case).
- Backward compatibility is asymmetric by design: when decoding from an older
  peer, missing `sandboxes`/`networks` decode to empty lists, but the agent
  must **not** interpret that as "tear everything down" — reconciliation of
  each list is gated on the corresponding version gate
  (`supportsSandboxSync`, `supportsNetworkSync`).

`ObservedStateReport` is the mirror image: the full observed VM/sandbox sets
plus current resources, sent level-triggered from the agent.

### Omission is not teardown (STR-98, wire v25)

Until v25, a workload the sync omitted was force-stopped and de-registered.
That put every workload on a host behind one control-plane `WHERE` clause: a
database restored from backup, an agent re-enrolled under a new record, or a
project-delete cascade racing a create all return a *short list* — not an
error — and the host tore down everything missing from it.

Teardown now needs to be said out loud, in a round trip:

1. The agent **holds** anything it has that a sync doesn't list — running,
   untouched, adopted into no generation — and reports it in
   `ObservedStateReport.unrecognized` (kind, id, the generation it last
   applied, and its observed status).
2. The control plane decides once per workload and remembers the verdict
   (`agent_workload_claims`). A record that still exists means the *sync* is
   wrong, so teardown is refused and logged loudly — permanently, however many
   times it is reported. Only "no record at all" authorizes one.
3. Authorized teardowns come back as `DesiredStateMessage.tombstones`
   (`DesiredWorkloadTombstone`: kind, id, generation). The agent honors a
   tombstone exactly as it honors an `.absent` desired entry, under the same
   staleness guard — the generation is minted above whatever the agent
   reported applying.

Nothing here is gated on a version, in either direction, and for once that is
the safe choice: the thing an older peer fails to do is *destroy something*. A
pre-v25 control plane never authorizes a teardown, so a v25 agent leaks a
stray rather than killing a live workload. A pre-v25 **agent** still destroys
on omission whatever the control plane does, which is what
`supportsWorkloadTombstones(_:)` exists to surface — registration logs such
agents at `notice` so a half-upgraded fleet's remaining exposure is legible.

`ObservedStateReport.teardownRefusal` carries the agent-side blast-radius
guard's refusal (see `docs/architecture/agent.md`); the control plane records
it on the agent row and surfaces it in the UI.

## Shared DTOs

The rest of the package is vocabulary used on both sides:

- **`VMSpec`** (`VMSpec.swift`) — the hypervisor-neutral machine description:
  CPU/memory/disk sizing, `BootSource` (`.disk(firmware:)` vs
  `.directKernel(kernel:initramfs:cmdline:)`), the `MachineProfile`
  (`secureBoot`/`tpm`; nil decodes to `.default`, both off), `VolumeSpec`, dual-stack
  `NetworkSpec`, `ConsoleSpec`, SSH keys, and verbatim caller-supplied
  cloud-init `userData` (tolerantly decoded to nil from older control
  planes). `CloudInitUserDataFormat` (`CloudInitUserData.swift`) is the
  shared header-detection table: the control plane validates user data
  starts with a header cloud-init dispatches on, and the agent labels the
  payload's MIME part with the matching content type.
- **`HypervisorType`** (`HypervisorTypes.swift`) — `qemu` / `firecracker`,
  the driver-registry key. `HypervisorSupport` and `HypervisorCapabilities`
  describe what each agent probed at registration (acceleration, pause,
  snapshots, direct kernel boot, limits).
- **`VMStatus`** (`VMModels.swift`) — observed status with tolerant decoding
  to `.unknown` (contrast with the strict `DesiredVMStatus`), plus
  `isTransitional`.
- **Sandbox types** (`SandboxModels.swift`) — `SandboxSpec`, `SandboxStatus`
  (adds `.exited`/`.stopped`), `RegistryCredential`.
- **Images** — `ArtifactKind` (`disk-image`/`kernel`/`initramfs`/`rootfs`),
  `ImageInfo`/`ArtifactInfo`, and `OCIImageReference` (parse/normalize OCI
  references, Docker Hub normalization).
- **Operations** (`OperationModels.swift`) — `VMOperationKind` and
  `VMOperationStatus` (`pending`/`succeeded`/`failed`), the vocabulary the
  frontend polls against.
- **Networking/addressing** (`NetworkModels.swift`, `IPAddressing.swift`) —
  network config/status DTOs and the project's own IPv4/IPv6 value types with
  CIDR math (containment, overlap, RFC 5952 canonicalization, EUI-64/ULA
  derivation), since Foundation has no portable IP types.
- **Host/platform** — `CPUArchitecture`, `OperatingSystem` (raw values match
  release-asset naming), `HostInfo`.

## Tests

`shared/Tests/StratoSharedTests/` (swift-testing) doubles as usage
documentation — `MessageEnvelopeTests.swift`, `ReconciliationProtocolTests.swift`,
`WireProtocolTests.swift`, and `SandboxExecMessageTests.swift` show the
expected encode/decode flows and compatibility behavior.
