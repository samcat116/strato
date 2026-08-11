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
  discriminator, a `requestId`, and a `timestamp`. **Nothing correlates on
  `requestId` any more** — the generic pending-request apparatus went with the
  last imperative exchange (STR-152), so the field survives as a log-correlation
  handle. Streaming messages (console, guest exec) correlate by `sessionId`
  and take their ordering from the WebSocket itself (see the header comment in
  `GuestExecMessages.swift`).
- `SuccessMessage` and `ErrorMessage` survive as **unsolicited** frames, sent
  control plane → agent only: an acknowledgement the agent logs (register,
  heartbeat, unregister), and a registration rejection whose machine-readable
  `code` (`invalid_token`, `unsupported_protocol_version`) the agent's reconnect
  loop reads. `SuccessMessage.data` went with the correlation (STR-152) —
  every typed reply that rode it is a field on `ObservedStateReport` now.

## Versioning

`WireProtocol.swift` holds the one accepted protocol version (`currentVersion`,
currently 49). The required registration fields
`AgentRegisterMessage.protocolVersion` and
`AgentRegisterResponseMessage.protocolVersion` are the sole version handshake.
Envelopes intentionally carry no duplicate version.

**Strato deploys the control plane and its agents as one coordinated wire-
contract change.** Both sides require exact equality with `currentVersion` and
refuse missing, older, and future versions before desired or observed state is
exchanged. There is no rolling mixed-version window and no per-feature protocol
gate.

Wire v44 generalized the interactive exec stream across VMs and sandboxes with
`guest_exec_*` messages and a resource-kind discriminator on start.

Wire v45 adds QEMU guest-agent intent, fixed host-global vsock CIDs, and the
per-hypervisor host capability used to keep those VMs off nodes without
`/dev/vhost-vsock`.

Wire v46 adds authoritative native-OVN load-balancer desired state, programming,
and backend-health observations.

Wire v47 adds typed dependency observations to agent registration and heartbeats.
The control plane uses the latest received snapshot for feature-scoped placement
gates without terminating workloads that are already running.

Wire v48 adds `VMSpec.metadataSource`, the create-time choice between the full
NoCloud seed ISO and an IMDS `seedfrom` stub. IMDS-backed metadata also carries
the optional per-VM NoCloud seed capability; old snapshots decode it as nil.
Older persisted agent manifests decode a missing source as `iso`; a live
control plane and agent still require the same v48 handshake.

Wire v49 adds `AgentRegisterMessage.metadataServiceCapable`. The agent reports
true only after it initializes the guest-facing listener supervisor; the
control plane requires the explicit signal for IMDS-backed VM placement.

Two consequences worth knowing:

- **A rejected agent cannot self-update.** Declarative self-update rides the
  desired-state sync, which starts only after registration. Update a rejected
  agent manually by re-running `install.sh` or replacing its image with the
  matching release, then restart it so it can register again.
- **Capabilities still exist, and they are not versions.** A capability
  (`sandboxCapable`, `sandboxNetworkingCapable`, `tpmCapable`,
  `resolverCapable`, `metadataServiceCapable`, or QEMU `supportsVsock`) is
  evidence that a *host* can realize a feature — a runtime, a binary, a guest
  image — all installed independently of the agent binary. Version says "the
  peer understands the payload"; capability says "the host can act on it". The
  exact handshake answers the first question; capabilities keep answering the
  second per host, re-probed at every registration.

The current contract includes the per-instance metadata kill switch (STR-185):
`InstanceMetadata.serviceEnabled` is EC2's `MetadataOptions.HttpEndpoint`,
the per-workload lever for denying one VM the link-local service. The listener
refuses an identified caller and a drop ACL on `pg_strato_no_metadata` keeps
the packet off the chassis; the two layers cover unmanaged NICs, authority
skew, and probe resistance.

`serviceEnabled` is required. Missing policy fails decoding rather than
silently enabling metadata for a VM whose operator disabled it.

Nil-tolerance conventions remain for semantic absence within one version: a
nil `volumes` or `snapshots` list
still means "the sender said nothing about that family" and is never planned
against (STR-148/150), `dnsZones: nil` still means "not the topology
authority", and a nil per-NIC `resolverEnabled` is still the control plane
withholding an opinion about a host it cannot describe.

Adding an enum case to a strictly decoded wire type (see `DesiredVMStatus`
below), or changing a field's representation or semantics, requires a version
bump and a coordinated deployment of both sides.

## Message catalog

`MessageType` in `WebSocketProtocol.swift` is the master list. By direction:

**Control plane → agent**

| Message | Purpose |
|---|---|
| `agent_register_response` | Registration reply: assigns the agent's DB UUID and name, echoes the protocol version |
| `desired_state` | The authoritative `DesiredStateMessage` sync (see below) |
| `console_connect`, `console_disconnect`, `console_data` | Console session control and input. `console_connect.stream` picks the serial console (default) or the VNC framebuffer (v23+) |
| `guest_exec_start`, `guest_exec_input`, `guest_exec_resize`, `guest_exec_close` | Interactive exec into a VM or sandbox; start carries `resourceKind` and `resourceId` (v44+) |

Everything the control plane sends is now either the sync or a live byte
stream — the disposition ADR 0001 set out to reach. There are deliberately no
`network_*` messages (topology is level-triggered from
`DesiredStateMessage.networks` alone; the imperative frames went in issue #781,
as did the pre-sync `vm_*` lifecycle messages and `status_update` in issue
#512), no `volume_*` messages (v31/v32/v33), no snapshot verbs (v33), and since
v34 no `vm_reboot`, `vm_restore` or `sandbox_restore` either.

**Agent → control plane**

| Message | Purpose |
|---|---|
| `agent_register` | Handshake: hostname, version, capabilities, resources, hypervisor support, architecture/OS, `sandboxCapable`, `sandboxNetworkingCapable`, `metadataServiceCapable`, protocol version |
| `agent_heartbeat` | Periodic resource usage and running VM IDs |
| `agent_unregister` | Graceful disconnect with a reason |
| `observed_state` | Level-triggered `ObservedStateReport`: VM/sandbox observed state, resources, agent-update status, optional per-VM `guestInfo` from qga (issue #563), and optional per-VM balloon `memoryStats` (issue #567, incl. `balloonActualBytes` at v19) |
| `vm_log`, `sandbox_log` | Log lines destined for Loki |
| `console_connected`, `console_disconnected`, `console_data` | Console session lifecycle and output |
| `guest_exec_started`, `guest_exec_output`, `guest_exec_exit`, `guest_exec_closed` | Guest exec stream responses |

Nothing in the agent → control plane direction is a *reply*. `success` and
`error` travel control plane → agent only, unsolicited and uncorrelated
(STR-152); the agent stopped sending them entirely at the same change.

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
  SVID mTLS (issue #493) — nothing in them expires — optional `metadata`
  (`InstanceMetadata`, v26+), the content the agent's link-local metadata
  service serves to the guest, and the two **edge nonces** (v34+):
  `rebootGeneration` and `restore` (a `DesiredRestore` of a nonce plus the
  checkpoint it names). Both are counts of requests, so absence is inert; the
  agent acts only when one outranks what it recorded in `VMManifestStore`, and
  a missing record is adopted rather than read as zero.
- `DesiredSandboxState` mirrors it for sandboxes (with an optional registry
  credential, and its own `restore` nonce — not to be confused with
  `restoreFrom`, which is a fork's *create strategy* and is read only while the
  sandbox is absent); `DesiredNetworkState` reconciles OVN logical networks
  (switch/subnets/gateways, per-project `routerKey`, SNAT, DHCP, and an
  optional `floatingIPs` list — external→fixed address mappings plus
  `vmId`/`nicIndex` for the NIC's port, realized as `dnat_and_snat` rules,
  issue #344); `DesiredAgentUpdate` is the declarative agent-update target.
- `DesiredDNSZone` (v36+) is the DNS half of the network carrier: a zone's id,
  name, attached network ids, its effective records as
  `DesiredDNSRecord(name, type, values, ttl)` — `ttl` since v37 — and a
  `recordsHash` the agent stamps on the realized row so an unchanged zone costs
  no OVSDB transaction. Its records are assembled fleet-wide, which is the one
  list in the sync that is not scoped to the receiving agent's own workloads: a
  zone's names span every agent's VMs. Sent to the topology authority (which
  writes the OVN `DNS` rows) and, since v37, to any agent running a local NIC on
  an attached network (which renders the zone into that network's resolver).

### Desired volumes (wire v31)

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
attachment, the volume's actual `sizeBytes` (v38+), and the usual convergence
quartet. A nil `volumes` on the *report* has two causes and the control plane
treats them identically, because the right response to both is to do nothing:
an agent below v31 does not speak the field, and a v31 agent that cannot
enumerate its volume store says so this way rather than claiming an empty
inventory — the volume counterpart of
`manifestStatus.inventoryComplete == false`.

### Desired snapshot artifacts (wire v33)

`DesiredSnapshotState` carries one artifact's id, its **kind** — a volume
snapshot, a VM checkpoint, or a sandbox snapshot — the parent it was captured
from, a desired status (`present`/`absent`, since an artifact is frozen bytes
with no run state), a generation, an optional **capture strategy**, and an
optional **export**.

One kind-tagged list rather than three, because the diff, the generation guard
and the absent-then-confirm dance are identical across the families; only the
backend that writes the bytes differs, and the entry's own `kind` says which.
The families stay three *tables* on the control plane — three quota paths,
three IAM node types, three very different completion budgets.

Like a volume's entry it carries no path and no size: the agent owns artifact
layout and is the only party that can measure what it wrote, so both travel the
other way.

`DesiredSnapshotCapture` is the create strategy — a sandbox's resume/stop mode,
a volume's attached-VM hint — and the agent consults it **only** while the
artifact is absent from the host. That is the safety property the whole
conversion rests on: without it a level-triggered entry carrying "pause this
guest and copy its RAM" would re-checkpoint a running VM on every replayed
sync, over the point in time the user is holding. Checkpoint-and-stop writes
both halves in one transaction — the capture mode here, the lasting intent on
the *sandbox's* own desired status — because the first alone would last exactly
until the next level-triggered pass.

`DesiredSnapshotExport` is the placement fact: "this artifact should also exist
in the control plane's object store". The agent converges it by streaming each
artifact to an upload slot; the byte transfer beneath stays a transport concern
(`SnapshotArtifactTransfer`), exactly as console and exec streams do. Dropping
the field plans nothing — withdrawing an exported copy is the control plane's
own object-store bookkeeping, not a teardown the agent can perform.

`ObservedSnapshotState` reports presence, whether this host has finished
exporting, the usual convergence quartet, and `ObservedSnapshotFacts` — the
footprint, hypervisor version, device nodes, fork layout and CPU template that
used to ride the RPC replies. Moving them here is not relocation: a reply is
delivered once, so both old paths had to treat a dropped socket as a protocol
error and mark a checkpoint that in fact existed `.error`. A report is re-sent
on every heartbeat, so the same facts simply arrive again. Every field is
optional and every consumer treats nil as *unknown*, never zero — a footprint
the agent could not measure must not silently become a free one in quota
accounting.

`ObservedSnapshotFacts` carries **two** sizes (STR-181, wire v39), and which one
answers depends on whether the artifact is finished when it is captured.
`sizeBytes` is measured once, at capture — the final answer for a VM checkpoint's
machine state and a sandbox snapshot's archive. `currentSizeBytes` is re-measured
on every report, for the one family whose bytes keep growing afterwards: a volume
snapshot is an overlay that starts as an empty qcow2 and fills toward its
parent's size as the volume is written, so its capture-time figure is a header
and nothing else. The control plane exposes the live figure for observability
and billing, while the storage quota keeps the parent-sized admission bound
reserved because the overlay can grow without another admission point.
Splitting the fields rather than redefining `sizeBytes` also makes a pre-v39
agent safe: it sends only the frozen header size under a name whose meaning did
not change, and the nil in the new field means "does not re-measure".

A nil `snapshots` on the report has v31's two causes and the same response:
an agent below v33 does not speak the field, and a v33 agent that cannot read
its snapshot record file says so this way rather than claiming an empty
inventory.

### Generations

Each desired record carries a monotonic per-resource `generation`, bumped by
the control plane on any spec or status change. The agent records the last
generation it applied and ignores older ones, so dropped, replayed, or
reordered syncs can never roll a resource backward. The observed side reports
`observedGeneration` (what it last converged toward), a `convergencePhase`
progress string, and on failure a `lastError` paired with `failedGeneration` —
the control plane marks a resource degraded only when `failedGeneration` matches
the current generation, which prevents attributing a stale error to a newer
change.

### One transport: the long-poll (STR-146)

The agent **fetches** its desired state: a long-poll
`GET /agent/desired-state` on the same Envoy SVID-mTLS listener that carries
image downloads, scoped by the forwarded SVID identity exactly as the
image-download route is (ADR 0001 stage 10). It has been the only desired-state
transport since wire v38 — the pushed `desired_state` WebSocket frame and the
per-agent transport negotiation (`pullsDesiredState`, the
`AGENT_DESIRED_STATE_PULL_ENABLED` kill switch) went with the skew window.

The response body is a full `MessageEnvelope` wrapping a `DesiredStateMessage`,
so a fetched payload takes the agent's ordinary inbound dispatch path and lands
on the `.desiredState` serialization lane.

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
- Absence still has grammar even without version skew: a nil `volumes` or
  `snapshots` field means "the sender said nothing about that family" and is
  never planned against, and `dnsZones: nil` means "not the topology
  authority" — silence is never an instruction to tear down.

`ObservedStateReport` is the mirror image: the full observed VM/sandbox sets
plus current resources, sent level-triggered from the agent.

### When a report is not an inventory (STR-138, wire v30)

`ObservedStateReport.manifestStatus` is the one thing that suspends those
full-list semantics. An agent's durable manifest is its only memory of what it
is running, so an agent that cannot read it sends empty lists because the
host's contents are *unknown*, not because it is idle — and absence means
deletion here (`agent.absent` finalizer) or loss (`.error`). A report carrying
`inventoryComplete: false` says so explicitly: the control plane records the
condition and the resource snapshot and applies none of the workload half.

Non-nil with `inventoryComplete: true` is the milder partial case — some
entries in the manifest cannot be routed by the build running on the host (an
unrecognized `hypervisorType` after an agent rollback). Those workloads are
still reported as present, so the lists remain an inventory. See
`docs/architecture/agent.md`.

Not gated, and it needs no gate: like v25, the field only ever *withholds*
action, and the agent half of the fix — zero advertised capacity, no
convergence against a host it can't see — works against any control plane
because refusing needs no permission.

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

The three-step handshake is what makes teardown deliberate: nothing is
destroyed on omission alone, only on an explicit tombstone minted above the
generation the agent reported applying.

`ObservedStateReport.teardownRefusal` carries the agent-side blast-radius
guard's refusal (see `docs/architecture/agent.md`); the control plane records
it on the agent row and surfaces it in the UI.

## Shared DTOs

The rest of the package is vocabulary used on both sides:

- **`VMSpec`** (`VMSpec.swift`) — the hypervisor-neutral machine description:
  CPU/memory/disk sizing, `BootSource` (`.disk(firmware:)` vs
  `.directKernel(kernel:initramfs:cmdline:)`), the `MachineProfile`
  (`secureBoot`/`tpm`; nil decodes to `.default`, both off), `VolumeSpec`, dual-stack
  `NetworkSpec`, `ConsoleSpec`, SSH keys, create-time `metadataSource`
  (`iso`/`imds`, with missing durable manifests decoded as `iso`), and verbatim
  caller-supplied cloud-init `userData` (tolerantly decoded to nil from older
  control planes). `CloudInitUserDataFormat` (`CloudInitUserData.swift`) is the
  shared header-detection table: the control plane validates user data
  starts with a header cloud-init dispatches on, and the agent labels the
  payload's MIME part with the matching content type.
- **`InstanceMetadata`** (`InstanceMetadata.swift`) — what a VM's link-local
  metadata service tells the guest about itself (STR-48): instance/project
  ids, hostname, environment, `region`/`availabilityZone` placement keys,
  `MetadataNIC` entries (device name, MAC, network, address + prefix per
  family, gateway, MTU, DNS), SSH keys, `userData`/`vendorData`, tags, and an
  optional `IdentityPolicy`. STR-64 adds an optional `noCloudSeedToken`, a
  credential used by the agent to authenticate only an IMDS-backed VM's
  NoCloud bootstrap URL; it is not rendered as a document and must not be
  logged. Since STR-55 the identity policy carries the VM's SPIFFE
  instance identity — `spiffe://<trust-domain>/vm/<vm-id>` — and no identity
  key, token, audiences, or TTL crosses the sync. STR-57 adds the
  placement-checked `POST /agent/vms/{vmID}/jwt-svid` control-plane endpoint,
  but the optional policy fields remain empty until the agent implements the
  guest-facing request path and token cache. It rides
  `DesiredVMState` rather than a boot-time seed ISO so metadata is mutable and
  converges like everything else. Treat it as a **publication boundary**: any
  process in the guest that can reach the link-local address reads every field,
  so adding one hands it to unprivileged guest code. Placement detail is
  carried unconditionally and the renderer — not the model or the assembler —
  decides whether a given project's guests are told where they run. Only
  `instanceId`/`projectId` are required keys: `DesiredVMState` decodes
  synthesized, so a missing required key inside `metadata` throws out of the
  whole `DesiredStateMessage` and stops that agent converging on everything.

  `serviceEnabled` (v39) is the one field that is not published — it decides
  whether the rest is served. It lives on the document so policy and payload
  cannot drift and so `MetadataStore`'s durable restore brings both back after
  a restart. Nil means enabled for the rolling-upgrade reason above.

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
- **Mutations** (`OperationModels.swift`) — `VMOperationKind` and
  `VMOperationStatus` (`pending`/`succeeded`/`failed`). Named for the retired
  `resource_operations` table, but they outlived it: the kind is the
  `resource_events` mutation column and the per-kind convergence budget, and
  the status is the vocabulary the operations façade answers in.
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
