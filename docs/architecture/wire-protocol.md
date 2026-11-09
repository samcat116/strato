# Wire Protocol (StratoShared)

The agent/control-plane workload contract is defined by Protobuf schemas in
`shared/proto/strato/agent/v1`. SwiftProtobuf generates checked-in Swift messages
for `StratoShared`. Generated messages are used by handlers and reconciliation;
handwritten extensions hold validation and domain behavior. The module depends
on SwiftProtobuf, while SPIFFE certificate verification remains a separate target.

## Envelope and encoding

Agent WebSockets carry binary Protobuf envelopes with a typed `oneof` body.
HTTP desired-state polling carries the same contract with `application/protobuf`.
Console and exec payloads are bytes, not base64 text. The migration is a hard
cutover: JSON/text workload frames are rejected.

The transport choice does not change reconciliation. Agents still pull complete,
generation-guarded desired state. Contentless Valkey doorbells optimize latency;
periodic unconditional fetches recover missed notifications. Replica forwarding
must retain the original binary message rather than decode/rebuild a payload,
so unfamiliar additive fields survive the relay.

JSON remains the representation at existing storage, public API, browser, guest,
and auxiliary HTTP interfaces. Explicit codecs preserve their dates, enum names,
union shapes, integers, and base64 values. ProtoJSON is not a drop-in replacement
for those formats. ETags use a canonical semantic representation with volatile
fields excluded; raw Protobuf serialization is not a canonical hash input.

## Versioning

Protocol **major 1** is the complete initial workload baseline. Compatible schema
additions do not increment it. Registration advertises immutable capability IDs;
peers negotiate their intersection and bind the result to a registration session.
Protocol support does not imply that a host has the hardware or services required
to realize a feature.

Unknown advertised capability names can be ignored. Required capabilities on a
message must be understood before any mutation or generation acknowledgement.
Reject an unsupported desired-state snapshot as a whole: never filter unsupported
resources out of an authoritative inventory. The same policy applies at admission,
assembly, and delivery, including HTTP polls served by another replica.

Collections with authority or optionality use message wrappers. A missing section
means no opinion where allowed; an explicitly empty section is authoritative.
Missing mandatory sections fail validation. Binary validators reject unspecified
or unknown values in actionable enum fields. UUID strings are validated and
canonicalized throughout nested messages at binary encode/decode boundaries,
preserving the case-insensitive identity semantics of the former UUID models
without dropping unknown Protobuf fields. Stored-manifest quarantine and salvage
remain separate from wire compatibility.

### Schema development

Install task-local tools and run the same checks as CI:

```sh
bash scripts/install-agent-protocol-tools.sh
source .build/agent-protocol-tools/env.sh
bash scripts/agent-protocol.sh generate
bash scripts/check-agent-protocol.sh origin/main
```

Tools are pinned to Buf 1.73.0 and SwiftProtobuf 1.38.1; ordinary application builds
use the checked-in generated sources and do not need Buf. The checks enforce
formatting, STANDARD lint, FILE breaking rules, the frozen initial v1 descriptor,
generated-output consistency, and independent baseline/next peer fixtures. On PRs,
CI additionally compares against the target branch. The initial cutover explicitly
bootstraps this check when the target has no Protobuf schema.

Never reuse field numbers or removed names; reserve them. Regenerate after rebasing
rather than resolving generated code manually. A passing schema diff cannot prove
that a changed acknowledgement or default still means the same thing: semantic
changes require a capability and behavioral tests. Intentional incompatible changes
need a new protocol major and an explicit migration.

### Previous workload transport

The former JSON workload protocol used an exact-version counter, ending at v72.
Those peers cannot join a Protobuf workload session. The separately frozen
[update-only bridge](#update-only-bridge) remains available to bridge-capable
binaries; it is not a workload compatibility adapter.

## Message catalog

`workload.proto` defines the envelope body cases. `MessageType` provides their
application-facing names. By direction:

**Control plane → agent**

| Message | Purpose |
|---|---|
| `agent_register_response` | Registration reply: assigns the agent's DB UUID and name, returns the negotiated protocol agreement and session |
| `desired_state` | The authoritative `DesiredStateMessage` sync (see below) |
| `console_connect`, `console_disconnect`, `console_data` | Console session control and input. `console_connect.stream` picks the serial console (default) or the VNC framebuffer (v23+) |
| `guest_exec_start`, `guest_exec_input`, `guest_exec_resize`, `guest_exec_close` | Exec into a VM or sandbox; start carries `resourceKind` and `resourceId` (v44+) plus required `sessionKind` (`interactive` or `recorded`, v56+) |
| `guest_exec_recorded_ack` | Retires one terminal recorded-session snapshot after the control plane durably commits or deliberately discards its outcome |

Everything the control plane sends is now the sync, live byte-stream control,
or the typed retirement acknowledgement for recorded exec state. There are
deliberately no `network_*` messages (topology is level-triggered from
`DesiredStateMessage.networks` alone; the imperative frames went in issue #781,
as did the pre-sync `vm_*` lifecycle messages and `status_update` in issue
#512), no `volume_*` messages (v31/v32/v33), no snapshot verbs (v33), and since
v34 no `vm_reboot`, `vm_restore` or `sandbox_restore` either.

**Agent → control plane**

| Message | Purpose |
|---|---|
| `agent_register` | Handshake: hostname, version, capabilities, resources, hypervisor support, architecture/OS, `sandboxCapable`, `sandboxNetworkingCapable`, `metadataServiceCapable`, protocol offer |
| `agent_heartbeat` | Periodic resource usage and running VM IDs |
| `agent_unregister` | Graceful disconnect with a reason |
| `observed_state` | Level-triggered `ObservedStateReport`: VM/sandbox observed state, resources, agent-update status, optional per-VM `guestInfo` from qga (issue #563), and optional per-VM balloon `memoryStats` (issue #567, incl. `balloonActualBytes` at v19) |
| `vm_log`, `sandbox_log` | Log lines destined for Loki |
| `console_connected`, `console_disconnected`, `console_data` | Console session lifecycle and output |
| `guest_exec_started`, `guest_exec_output`, `guest_exec_exit`, `guest_exec_closed` | Guest exec stream events |
| `guest_exec_recorded_state` | Full bounded stdout/stderr and running, exited, or closed state for a recorded session; running inventory and terminal outcomes are re-offered after registration |

Nothing in the agent → control plane direction is a generic *reply*.
`success` and `error` travel control plane → agent only, unsolicited and
uncorrelated (STR-152); the agent stopped sending them entirely at the same
change.

### Recorded exec reconnect state (STR-260, wire v56)

`GuestExecRecordedStateMessage` is a complete level-triggered snapshot, never
an output delta. Its `stdout` and `stderr` fields contain the full byte
capture retained by the agent, with a combined ceiling of 1,048,576
bytes. `truncated` is true when bytes exceeded that ceiling or when the channel
closed without an authoritative `exec_exit`, so the capture may be incomplete.
The agent advances a per-session `revision` whenever that authoritative state
changes; PostgreSQL compare-and-write rules prevent a delayed replica from
replacing a newer snapshot.
Status determines the terminal fields: `running` has neither `exitCode` nor
`reason`; `exited` has an exit code and no reason; `closed` has a normalized
reason and no exit code.

After registration, an agent offers every recorded session it still holds.
Running state lets the control plane know the command survived the socket
interruption. An exited or closed snapshot is replayed until
`guest_exec_recorded_ack` says the control plane durably committed or
deliberately discarded the terminal outcome. Only terminal snapshots are
acknowledged and retired. The acknowledgement is keyed by `sessionId`; its
fresh `requestId` remains a log handle and does not turn the exchange into a
generic request/response RPC. This recovery is intentionally in-memory and
same-agent-process only: agent or host restart survival is outside this
contract.

## The reconciliation contract

`shared/Sources/StratoShared/ReconciliationProtocol.swift` defines the
desired/observed state sync — the core of the control loop described in
[overview](./overview.md). Its doc comments are the authoritative prose on the
design; the short version:

### Desired state

- `DesiredVMStatus`: `running` / `shutdown` / `paused` / `absent`. It is a
  goal, never a report — there are no transitional or diagnostic cases.
  Boundary validation is **strict**: misreading a desired status could stop
  or delete a live VM, so an unspecified or unknown value fails validation
  before reconciliation. `isSatisfied(by:)` encodes convergence
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
of the same fact is a thing that can drift. There is no disk reference on the
volume lane: the agent owns storage layout, so the typed attachment originates
on the observed report.

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

`ObservedVolumeState` reports presence, the agent-chosen `DiskAttachment`, the
volume's actual `sizeBytes` (v38+), the VM attachment, and the usual convergence
quartet. The control plane persists that disk attachment without interpreting
it and projects it into `VMSpec.volumes` for VM realization. A nil `volumes` on
the *report* has two causes and the control plane
treats them identically, because the right response to both is to do nothing:
a peer withholding inventory or an agent that cannot enumerate its volume
store omits the section rather than claiming an empty inventory — the volume counterpart of
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
exporting, the usual convergence metadata, and `ObservedSnapshotFacts` — the
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
a peer withholding inventory or an agent that cannot read its snapshot
record file omits the section rather than claiming an empty inventory.

### Generations

Each desired record carries a monotonic per-resource `generation`, bumped by
the control plane on any spec or status change. The agent records the last
generation it applied and ignores older ones, so dropped, replayed, or
reordered syncs can never roll a resource backward. The observed side reports
`observedGeneration` (what it last converged toward), a `convergencePhase`
progress string, and on failure a `lastError` paired with `failedGeneration` —
the control plane marks a resource degraded only when `failedGeneration` matches
the current generation, which prevents attributing a stale error to a newer
change. `failureClassification` carries the agent's retry category. A
`.blocked` report retains desired state and its convergence deadline while
surfacing the remedy; a later success can therefore settle the same generation.
If the deadline expires first, the stuck-convergence sweep preserves that remedy
while terminally resolving the mutation and emitting its failure outcome. The
field is optional so reports from older agents retain the historical
terminal-failure behavior.

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

  `serviceEnabled` is the one field that is not published — it decides
  whether the rest is served. It lives on the document so policy and payload
  cannot drift and so `MetadataStore`'s durable restore brings both back after
  a restart. A live payload must explicitly carry this policy; absence must not enable it.

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
- **`HypervisorType`** (`HypervisorTypes.swift`) — `qemu` / `firecracker` / `apple_virtualization`,
  the driver-registry key. `HypervisorSupport` and `HypervisorCapabilities`
  describe what each agent probed at registration (acceleration, pause,
  snapshots, direct kernel boot, limits).
- **`VMStatus`** (`VMModels.swift`) — observed status with legacy JSON decoding
  that maps unknown strings to `.unknown`, plus `isTransitional`. Binary protocol
  validation rejects unspecified and unrecognized enum tags; the tolerant JSON
  behavior does not apply to binary workload messages.
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
`WireProtocolTests.swift`, and `GuestExecMessageTests.swift` show the
expected encode/decode flows and compatibility behavior.

## Managed VM guest configuration (STR-90 / STR-91)

STR-90 introduced the shared vocabulary without a live realization capability.
STR-91 enables the agent consumer and generation-scoped guest observations on
Protobuf major 1. Its semantics are part of the baseline; successful
registration must not let an agent acknowledge guest intent without realizing it.

`DesiredVMState.guestConfig: GuestConfig?` extends the VM's existing desired
state. It uses **the enclosing VM generation**: every accepted edit must bump
that generation, and consumers must ignore stale generations before any guest
write. There is no second generation counter, command language, or transport.

A missing or null `guestConfig` decodes as nil for older stored payloads and
means no managed guest intent. A present object requires all four arrays:

```json
{
  "packages": [{"name": "curl", "state": "present"}],
  "files": [{"path": "/etc/example.conf", "content": "hello\n", "mode": "0644"}],
  "services": [{"name": "example.service", "enabled": true}],
  "sysctls": [{"key": "net.ipv4.ip_forward", "value": "1"}]
}
```

Package states are strictly `present` or `absent`; version pinning, repository
configuration, scripts and package-manager flags are outside this contract.
Services specify boot enablement only, with no implied start, stop, or restart.
Files are regular UTF-8 text writes with explicit ordinary permission bits:
`mode` is four octal digits starting with zero (no special bits). No append,
remote source, templating, deletion, owner, or group operation is expressed.
Sysctls specify nonempty single-line values; guest support and persistence are
realization concerns, not inferred by the shared schema.

**Omission withdraws management, never reverses changes.** Removing an entry,
sending empty arrays, or setting `guestConfig` to nil does not remove packages,
delete files, disable services, or reset sysctls previously managed. Package
removal and service disablement require explicit `absent` and `enabled: false`
entries. List order does not express dependencies or an execution sequence.

`GuestConfig.validate()` is the reusable API boundary validator; encoding and
decoding also validate. Unknown object fields and enum values fail closed.
Identities must be unique within each section; sections are limited to 128
entries. Names are at most 255 ASCII bytes and begin with a letter or digit.
Package names additionally allow `.+_:-`; service names allow `._-@:`; sysctl
keys allow `._-` and require nonempty dot-separated components. Paths are
canonical absolute non-root paths up to 4096 UTF-8 bytes, without empty, dot,
or parent components or control characters. Content excludes NUL, is limited
to 65536 UTF-8 bytes per file and 262144 bytes per configuration. Sysctl values
are at most 1024 UTF-8 bytes and exclude controls except tab.

These limits are per VM; the assembler must still respect the whole-sync frame
budget. This schema does not resolve symlinks: the guest writer must refuse
unsafe traversal and nonregular destinations in the guest, never on the host.
It must use argument arrays rather than interpolated shell commands. Do not
log configurations, file content, sysctl values, or command output; observation
errors should identify a field or item index and a fixed failure category.
Shared validation errors do not echo caller values.

STR-90 owns the shared contract and its tests. STR-91 owns guest-side realization,
capability checks, generation guarding, and content-free observations. STR-92
owns persistence, API/UI/CLI integration, transactionally accepted generation
bumps, and projection into desired state. Schema availability alone does not
mean a guest agent supports realization. Older stored payloads missing the field
remain decodable; live workload peers negotiate Protobuf major 1.

The major 1 baseline includes `AgentResources.memoryAccounting`, with physical,
host-reserved, workload-effective, remaining allocatable, and QEMU allowance
bytes. Remaining bytes are already net of host reserve and backend overhead.
These accounting semantics are part of the baseline.

### Guest realization observations (STR-91, following STR-90)

`ObservedVMState.guestConfigObservation` is optional and generation-scoped. It
contains `generation`, `status` (`converged` / `failed`), nullable `error`, and
bounded arrays: packages (`name`, nullable `version`), files (`path`, nullable
`sha256` / `mode`), services (`name`, nullable `enabled` / `activeState`), and
sysctls (`key`, nullable `value`). No file contents or command output are reported.
Success requires complete identities and no error; failure may contain partial
facts but also sets the existing VM `lastError` / `failedGeneration` fields.
Stored payloads without this optional field decode as nil. Guest realization
and observations are part of Protobuf major 1.

Host/VM guest control adds `converge_guest_config` (`generation`, `guest_config`)
and `guest_config_state` (`nonce`, `observation`). These are additive to the
sandbox guest v4 surface; sandbox init does not realize VM guest intent. The VM
daemon advertises `capabilities: ["guest_config_convergence"]` in its v4 `pong`.
The host requires that capability before sending the request; v0.1.2 and other
non-advertising guests wait for an explicit upgrade without receiving intent.
First-boot installation is pinned to v0.1.3, whose capability-bearing guest
artifacts and manifest must be published before deploying guest realization. Existing VMs
are never automatically updated. The host client performs the v4 ping handshake
on the same connection, and every reply is checked against that boot nonce. Generic guest-control lines
remain bounded at 1 MiB. Only `converge_guest_config` requests and their response
line use a 4 MiB bound, including when convergence is the first control frame.
The bound derives from worst-case JSON escaping of the existing STR-90 field
limits; the guest-control protocol remains v4, independently of workload Protobuf major 1.

Item-level failures are explicit: optional `failedItem` contains `section`
(`packages`, `files`, `services`, or `sysctls`), `identity` (package/service
name, file path, or sysctl key), and fixed `reason` matching the top-level
`error`. It names the failed observation/apply/read-back row; other unmet rows
were not necessarily attempted. Journal, validation, or interrupted-pass errors
have no failed item. Failed-item identity and reason survive restart in the
metadata journal.

## Update-only bridge

`GET /agent/update/v1` is a separate frozen, SVID-authenticated contract for
bridge-capable binaries. It carries only the control plane's protocol
major and an already authorized update artifact. It does not register a workload
session. Workload desired-state polls carry the negotiated session ID in
`Strato-Agent-Session`; stale or absent sessions are rejected before assembly.
See [staging and bootstrap limits](./agent-updates.md#stable-bridge-exchange-str-340).

### Guest configuration terminal retry fence (STR-92, wire v71)

`ObservedVMState.guestConfigFailedGeneration` attributes a terminal failure to
`convergeGuestConfig`, including loss of the channel before read-back. Host
resize, networking, boot, and edge failures carry no guest failure attribution;
the control plane preserves their host diagnostic and does not invent a guest
operation outcome. Dependency waits remain retryable and do not stamp this field.

The persisted verdict returns as `DesiredVMState.guestConfigFailedGeneration`.
A restarted agent may adopt the VM and perform preceding host steps, but refuses
the guest step at that generation before invoking its transport. Only a newer VM
generation permits another attempt. This retry fence belongs to the Protobuf major 1 baseline; the independent
guest-control protocol remains v4.
