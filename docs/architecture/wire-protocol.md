# Wire Protocol (StratoShared)

The `shared/` package (library product **StratoShared**) defines everything the
control plane and agent agree on: the WebSocket message catalog, the
reconciliation contract, and the DTOs both sides serialize. It is the only
code shared between the two services — if a type crosses the socket, it lives
here.

The package deliberately has almost no dependencies (swift-nio is declared for
consumers; the StratoShared sources themselves import only Foundation) and no
I/O of its own. It is a vocabulary, not a client. The package also ships a
second product, **SPIFFEVerification** — the SPIFFE peer-identity verifier
both services pin certificates with — kept as a separate target precisely so
StratoShared consumers don't inherit its NIOSSL and swift-certificates
dependencies.

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

`WireProtocol.swift` holds the protocol version (currently 29), stamped on
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
| `supportsDesiredAgentUpdate` | 7 | Agent self-update carried by the sync (the only update path since v28) |
| `supportsSandboxExec` | 8 | Interactive sandbox exec streams |
| `supportsSandboxSnapshots` | 9 | Sandbox snapshot/restore messages |
| `supportsSandboxFork` | 12 | Restore-into-new-identity sandbox forks |
| `supportsFloatingIPs` | 12 | Floating IPs in the network desired state |
| `supportsSandboxSnapshotMobility` | 14 | Off-node snapshot export + cross-agent restore/fork |
| `supportsVMResize` | 17 | Online vCPU/memory resize of a running VM |
| `supportsMachineProfile` | 18 | `VMSpec.machine` — Secure Boot and vTPM |
| `supportsBalloonTarget` | 19 | `VMSpec.balloonTargetBytes` — operator balloon targets on a running guest |
| `supportsSecurityGroups` | 20 | Security groups: OVN port groups/ACLs from the sync, membership per NIC |
| `supportsProjectNetworkIsolation` | 21 | Id-keyed OVN naming, so two same-named networks can coexist |
| `supportsVMCheckpoint` | 22 | The `vm_checkpoint` / `vm_restore` / `vm_snapshot_delete` message trio |
| `supportsGraphicsConsole` | 23 | `ConsoleSpec.graphics` + `ConsoleConnectMessage.stream` — the VNC console |
| `supportsWorkloadTombstones` | 25 | Omission is hold-and-report, not teardown (a legibility gate, not a send gate — see STR-98 below) |
| `supportsInstanceMetadata` | 26 | `DesiredVMState.metadata` — the instance metadata the agent serves at the link-local address |
| `supportsMetadataPort` | 27 | `metadataEnabled` on `DesiredNetworkState` **and** `NetworkSpec` — the OVN localport publishing the metadata addresses |
| `supportsDesiredStatePull` | 29 | The control plane serves `GET /agent/desired-state`, so the agent may fetch its sync instead of waiting for a push |
| `supportsVolumeSync` | 30 | Volumes in the desired-state sync — and a **placement** gate, not just a field gate: with the imperative volume frames gone there is no fallback path |

Version 13 has no gate: it switched image downloads from signed URLs to
relative paths fetched over SVID mTLS (issue #493), which older agents cannot
degrade around — they must upgrade.

Versions 15 and 16 have no gates either: both add optional, nil-tolerant
fields — `ObservedVMState.guestInfo` and `VolumeSnapshotMessage.attachedVMId`
at v15 (the QEMU guest agent, issue #563), `ObservedVMState.memoryStats` at
v16 (virtio-balloon statistics, issue #567). A nil from an older peer reads
identically to "not known" and can never mean a destructive action, so no
send-side gate is needed. One meaning did tighten without its shape changing:
`attachedVMId` originally told the agent which guest to fs-freeze around a
snapshot; since issue #747 the agent uses it to *refuse* the snapshot.

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

Version 26 adds instance metadata (STR-48): an optional
`DesiredVMState.metadata` carrying `InstanceMetadata` — hostname, placement,
NICs, SSH keys, user and vendor data, tags, and a phase-3 `IdentityPolicy` —
which the agent serves to the guest from the link-local metadata address
(169.254.169.254) instead of baking it into a boot-time seed ISO. Putting it on
the sync is the whole point of the design: the metadata store inherits
level-triggering, generation guards, and replay safety from the machinery that
already exists, so an operator's edit propagates on the next sync with no
second control loop, no second transport, and nothing in the payload that can
expire. Carrying the metadata on the sync is shipped; serving it is not — no
agent yet answers HTTP on `169.254.169.254`, so the guest-facing IMDS listener
is future work (only the v27 chassis/localport half exists agent-side, see
[agent](./agent.md)).

Absence is asymmetric in the v3/v5 sense rather than the harmless v7 sense,
which is why `supportsInstanceMetadata` gates both directions. Agent-side it
decides whether a missing key *means* anything: from a v26+ control plane nil
is authoritative ("nothing to serve" — drop stale metadata), from an older one
it is silence, and reading silence as authoritative would empty every VM's
store the moment a control plane is rolled back. Control-plane-side the same
gate lets sync assembly omit the field for pre-v26 agents, the v20
`securityGroups` pattern. What it deliberately does *not* do is refuse
placement, unlike v18/v23: a pre-v26 agent still provisions guests from the
seed ISO exactly as before, so a VM landing there loses mutable metadata, not
its ability to boot. Retiring the seed ISO is what will make a placement gate
load-bearing.

Version 27 adds the metadata dataplane (STR-49): `metadataEnabled` on
`DesiredNetworkState`, and the same flag per NIC on `NetworkSpec`. The two are
not redundant — they feed the two halves of a feature with two different
owners. The OVN `localport` that publishes `InstanceMetadataEndpoint`'s
addresses (`169.254.169.254` and `fd00:ec2::254`) on a logical switch is one
row in the shared northbound database, authored only by the site's network
controller from `networks`. The chassis-local namespace that terminates those
addresses must exist on *every* host running a NIC on that network, and a
sited non-controller agent receives an empty `networks` list by design — it may
not author topology — so its only input is its own workloads' specs. Hence the
flag on both, and hence the network reconcile converging the chassis half
*before* its authority guard.

It rides `DesiredNetworkState` rather than only the NIC spec for `dhcpEnabled`'s
reason: metadata edits don't bump VM generations, so a converged VM never
re-realizes its NICs, and the level-triggered network reconcile is the only path
that reaches a live network whose setting changed — including deleting the port
when it is turned off.

Absence is asymmetric in the v3/v5 sense on both fields, and on
`DesiredNetworkState` the asymmetry is enforced in code rather than by
convention. Network teardown is `observed − desired`, so a nil that merely
planned no port would read as "remove it":
`NetworkReconciler.metadataProtection(for:)` explicitly protects the ports of
networks whose `metadataEnabled` is nil, which is what keeps a rollback to v26
from deleting every live metadata port on the next sync. `false` remains an
opinion and is honored — that is what makes turning the feature off work.
Control-plane-side the gate lets sync assembly omit both fields for pre-v27
agents. Like v26 and unlike v18/v23 it does not refuse placement: a pre-v27
agent simply doesn't publish the address, and its guests fall back to the seed
ISO exactly as today.

Version 28 removes the imperative `agent_update` message (ADR 0001 stage 6). An
agent's build is a durable fact about the host rather than an action, so it
belongs in the sync — where `desiredAgentUpdate` has carried it since v7 — and
the operator's "update now" endpoint now assigns that field instead of
dispatching a command, leaving the message with no sender. Removing a
`MessageType` case breaks in exactly one direction, and only across a skew that
upgrades backwards: a pre-v28 *control plane* driving a v28 agent would send
`agent_update` into an envelope the agent can no longer decode and burn its
timeout against silence. Upgrade the control plane first, as everywhere else
here.

Version 29 makes the sync *pullable*: the control plane serves it over a
long-poll `GET /agent/desired-state`, and the agent may fetch it there instead
of waiting for a push (ADR 0001 stage 10). Nothing about the payload changes,
so this gates the transport rather than the schema, and both directions of skew
simply keep pushing.

Version 30 makes volumes desired state (ADR 0001 stage 5, STR-148).
`DesiredStateMessage` gains `volumes` and `ObservedStateReport` gains its
counterpart; the six imperative frames `volume_create`, `volume_delete`,
`volume_attach`, `volume_detach`, `volume_resize` and `volume_clone` are
removed. This bump carries two hazard shapes at once.

The *removal* half is the v28 shape and breaks only across a skew that upgrades
backwards. The *addition* half is the v3/v5/v26/v27 asymmetric-absence shape in
its most expensive form: read wrong, silence deletes the only copy of a user's
data. Both new fields are therefore `Optional` rather than `[]`-defaulted, so
the payload describes itself and the reading does not depend on a version
lookup being right. A sync whose `volumes` is nil makes the agent skip its
volume half entirely — it does *not* plan against an empty desired list, which
would put every volume on the host into the unrecognized set. A report whose
`volumes` is nil makes the control plane skip its own volume half, rather than
reading the absence as "every volume on this agent is gone" and reaping the
rows.

Unlike v26/v27 and like v18/v23, this gate **does** refuse placement: with no
imperative fallback left, a volume placed on a pre-v30 agent could never be
created. Volumes already sitting on such an agent when the control plane
upgrades simply freeze — their rows are never reaped, because that agent's
reports say nothing about volumes — until the agent is upgraded. Deleting one
still works: the delete path force-clears the agent-absence finalizer for an
agent that cannot confirm.

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
| `volume_snapshot`, `volume_snapshot_delete`, `volume_info` | What is left of the imperative volume verbs (QEMU-backed VMs only). Create, delete, attach, detach, resize and clone became desired state in v30 (STR-148); these two artifact verbs and the read convert in ADR 0001 stages 8 and 7 |
| `sandbox_snapshot_create`, `sandbox_snapshot_delete`, `sandbox_restore` | Sandbox checkpoint/restore (v9+, issue #426) — imperative request/response pairs like the volume operations |
| `sandbox_snapshot_export` | Export a checkpoint's artifacts off-node to control-plane object storage (v14+, issue #428) |
| `console_connect`, `console_disconnect`, `console_data` | Console session control and input. `console_connect.stream` picks the serial console (default) or the VNC framebuffer (v23+) |
| `sandbox_exec_start`, `sandbox_exec_input`, `sandbox_exec_resize`, `sandbox_exec_close` | Interactive exec into a sandbox (v8+) |

There are deliberately no `network_*` messages: network topology is
level-triggered from `DesiredStateMessage.networks` alone (the imperative
frames were removed in issue #781, as were the pre-sync `vm_*` lifecycle
messages and `status_update` in issue #512).

**Agent → control plane**

| Message | Purpose |
|---|---|
| `agent_register` | Handshake: hostname, version, capabilities, resources, hypervisor support, architecture/OS, `sandboxCapable`, protocol version |
| `agent_heartbeat` | Periodic resource usage and running VM IDs |
| `agent_unregister` | Graceful disconnect with a reason |
| `observed_state` | Level-triggered `ObservedStateReport`: VM/sandbox observed state, resources, agent-update status, optional per-VM `guestInfo` from qga (issue #563), and optional per-VM balloon `memoryStats` (issue #567, incl. `balloonActualBytes` at v19) |
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
  desired status, a **generation** counter, optional `imageInfo` whose
  download URLs are control-plane-relative paths the agent fetches over
  SVID mTLS (issue #493) — nothing in them expires — and optional `metadata`
  (`InstanceMetadata`, v26+), the content the agent's link-local metadata
  service serves to the guest.
- `DesiredSandboxState` mirrors it for sandboxes (with an optional registry
  credential); `DesiredNetworkState` reconciles OVN logical networks
  (switch/subnets/gateways, per-project `routerKey`, SNAT, DHCP, and an
  optional `floatingIPs` list — external→fixed address mappings plus
  `vmId`/`nicIndex` for the NIC's port, realized as `dnat_and_snat` rules,
  issue #344); `DesiredAgentUpdate` is the declarative agent-update target.

### Desired volumes (wire v30)

`DesiredVolumeState` carries a volume's id, desired status
(`present`/`absent` — two cases, because a volume has no run state), a
generation, its desired size and format, an optional **create strategy**, and
an optional attachment.

Two fields it deliberately does *not* carry. There is no pool: placement is
expressed by *which agent's sync the entry appears in*, and a second encoding
of the same fact is a thing that can drift. There is no storage path: the agent
owns path layout, so the path travels the other way, on the observed report.

`DesiredVolumeSource` is the create strategy — `blank`, `image`, or `clone` —
and it is what used to be `volume_clone`. It follows the
`DesiredSandboxState.restoreFrom` pattern (issue #427): the agent consults it
*only* when it does not already hold the volume, which is what makes a replayed
or re-driven sync unable to re-clone over live data. Its `kind` is a `String`
rather than a Swift enum with associated values, so an unrecognized strategy
fails that one volume — surfacing as its `lastError` — instead of the whole
message.

`DesiredVolumeAttachment` names the VM and the slot. Attachment is a *field*
of the entry rather than a status: modelling attach as a status would make
"present, but the attach failed" unrepresentable, and would collide with size,
which moves independently of where the volume is plugged in. The same columns
are projected twice — here, and into `VMSpec.volumes` — so the two projections
of one fact cannot disagree; the volume lane is authoritative for realizing an
attachment, and `VMSpec.volumes` is the boot-time convenience that rebuilds the
same disk set.

`ObservedVolumeState` reports presence, the agent-chosen path and format, the
attachment, and the usual convergence quartet. It deliberately carries no size:
reading a volume's virtual size means a `qemu-img info` subprocess per volume,
and the report is assembled on every convergence action plus the heartbeat
cadence. A resize is confirmed the way a VM resize is, by `observedGeneration`
catching up.

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

### Two transports, one payload (wire v29)

Since v29 the agent normally **fetches** its desired state rather than waiting
for a pushed frame: a long-poll `GET /agent/desired-state` on the same Envoy
SVID-mTLS listener that carries image downloads, scoped by the forwarded SVID
identity exactly as the image-download route is (ADR 0001 stage 10, STR-146).

Nothing about the payload changes. The response body is the same
`MessageEnvelope` wrapping the same `DesiredStateMessage`, so the agent's decode
and dispatch path — including reading `senderVersion` off the envelope to tell
authoritative silence from an old control plane — is identical either way. This
version gates the *transport*, not the schema.

Which transport an agent gets is per agent, not per fleet:
`AgentRegisterMessage.pullsDesiredState` says whether it is polling, and the
control plane stops pushing only when that, the version gate, and its own
`AGENT_DESIRED_STATE_PULL_ENABLED` kill switch all agree. Speaking v29 is
deliberately not sufficient on its own, for the same reason `sandboxCapable`
exists: a v29 build understands the endpoint but may be pinned to push mode.

**Conditional requests are an optimization and never a gate.** The response
carries an `ETag` (a SHA-256 digest of the assembled payload, with per-assembly
noise — correlation ids, timestamps, freshly minted registry tokens, re-resolved
artifact URLs — normalized out). A poll that presents a matching
`If-None-Match` parks server-side until a doorbell fires or the hold window
expires, then answers `304`. But the agent re-fetches **unconditionally** on a
slow timer regardless, sending no validator at all, and the control plane must
answer that with a full payload. That is the correctness invariant: a wrong
ETag anywhere can then cost only latency, never convergence.

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
- **`InstanceMetadata`** (`InstanceMetadata.swift`) — what a VM's link-local
  metadata service tells the guest about itself (STR-48): instance/project
  ids, hostname, environment, `region`/`availabilityZone` placement keys,
  `MetadataNIC` entries (device name, MAC, network, address + prefix per
  family, gateway, MTU, DNS), SSH keys, `userData`/`vendorData`, tags, and an
  optional `IdentityPolicy` for phase-3 SPIFFE instance identity. It rides
  `DesiredVMState` rather than a boot-time seed ISO so metadata is mutable and
  converges like everything else. Treat it as a **publication boundary**: any
  process in the guest that can reach the link-local address reads every field,
  so adding one hands it to unprivileged guest code. Placement detail is
  carried unconditionally and the renderer — not the model or the assembler —
  decides whether a given project's guests are told where they run. Only
  `instanceId`/`projectId` are required keys: `DesiredVMState` decodes
  synthesized, so a missing required key inside `metadata` throws out of the
  whole `DesiredStateMessage` and stops that agent converging on everything.

  `userData`/`vendorData` are carried **inline**, unlike `imageInfo`'s fetched
  paths. That is deliberate — the agent must serve exactly what the last sync
  said, with no fetch that can fail after a sync was applied — and the bound is
  the 16 MiB frame, since a sync must fit in one whole. The sync already
  carries a 64 KiB-capped `VMSpec.userData` per VM for the seed ISO, so this
  duplicates it for the length of the migration (~128 KiB/VM worst case, ~64
  KiB once the seed path is retired), putting the ceiling at roughly 130 VMs
  per host all at the user-data cap. If it ever needs moving, the lever is an
  IMDS-specific limit below `CloudInitUserDataFormat.maxBytes`, not a second
  transport.
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
