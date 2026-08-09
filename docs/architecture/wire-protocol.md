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
  discriminator, a `requestId`, and a `timestamp`. **Nothing correlates on
  `requestId` any more** — the generic pending-request apparatus went with the
  last imperative exchange (STR-152), so the field survives as a log-correlation
  handle. Streaming messages (console, sandbox exec) correlate by `sessionId`
  and take their ordering from the WebSocket itself (see the header comment in
  `SandboxExecMessages.swift`).
- `SuccessMessage` and `ErrorMessage` survive as **unsolicited** frames, sent
  control plane → agent only: an acknowledgement the agent logs (register,
  heartbeat, unregister), and a registration rejection whose machine-readable
  `code` (`invalid_token`, `unsupported_protocol_version`) the agent's reconnect
  loop reads. `SuccessMessage.data` went with the correlation (STR-152) —
  every typed reply that rode it is a field on `ObservedStateReport` now.

## Versioning

`WireProtocol.swift` holds the protocol version (currently 39), stamped on
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
| `supportsSandboxFork` | 12 | Restore-into-new-identity sandbox forks |
| `supportsFloatingIPs` | 12 | Floating IPs in the network desired state |
| `supportsSandboxSnapshotMobility` | 14 | Off-node snapshot export + cross-agent restore/fork |
| `supportsVMResize` | 17 | Online vCPU/memory resize of a running VM |
| `supportsMachineProfile` | 18 | `VMSpec.machine` — Secure Boot and vTPM |
| `supportsBalloonTarget` | 19 | `VMSpec.balloonTargetBytes` — operator balloon targets on a running guest |
| `supportsSecurityGroups` | 20 | Security groups: OVN port groups/ACLs from the sync, membership per NIC |
| `supportsProjectNetworkIsolation` | 21 | Id-keyed OVN naming, so two same-named networks can coexist |
| `supportsGraphicsConsole` | 23 | `ConsoleSpec.graphics` + `ConsoleConnectMessage.stream` — the VNC console |
| `supportsWorkloadTombstones` | 25 | Omission is hold-and-report, not teardown (a legibility gate, not a send gate — see STR-98 below) |
| `supportsInstanceMetadata` | 26 | `DesiredVMState.metadata` — the instance metadata the agent serves at the link-local address |
| `supportsMetadataPort` | 27 | `metadataEnabled` on `DesiredNetworkState` **and** `NetworkSpec` — the OVN localport publishing the metadata addresses |
| `supportsDesiredStatePull` | 29 | The control plane serves `GET /agent/desired-state`, so the agent may fetch its sync instead of waiting for a push |
| `supportsVolumeSync` | 31 | Volumes in the desired-state sync — and a **placement** gate, not just a field gate: with the imperative volume frames gone there is no fallback path |
| `supportsSnapshotSync` | 33 | Snapshot artifacts in the desired-state sync — and a **capture-admission** gate: an artifact has no placement decision to gate, so a capture requested against a pre-v33 agent is refused instead |
| `supportsEdgeNonces` | 34 | Reboot and restore as monotonic nonces on the desired entry — and an **admission** gate: with the imperative frames gone, a pre-v34 agent would ignore the field and report the bumped generation as converged, so the API would claim a restart that never happened |
| `supportsDNSZones` | 36 | `DesiredStateMessage.dnsZones` — the zones an agent realizes, into the OVN `DNS` table (topology authority) and into its networks' resolvers (any agent with a local NIC). A *field* gate only: a pre-v36 agent leaves names unresolved, which is visible and self-healing, so there is nothing to refuse at the API |
| `supportsNetworkResolver` | 37 | `DesiredNetworkState.resolverEnabled`/`.resolverAddresses`, the same pair on `NetworkSpec`, and `DesiredDNSRecord.ttl` — the per-network link-local resolver. A *field* gate; whether the host can actually serve one is the separate `AgentRegisterMessage.resolverCapable`, folded site-wide before the field is sent |

The v9 `supportsSandboxSnapshots` and v22 `supportsVMCheckpoint` gates were
removed with the last frames they guarded (v33 and v34): every question either
answered is now answered, at a higher floor, by `supportsSnapshotSync` and
`supportsEdgeNonces`.

Version 13 has no gate: it switched image downloads from signed URLs to
relative paths fetched over SVID mTLS (issue #493), which older agents cannot
degrade around — they must upgrade.

Versions 15 and 16 have no gates either: both add optional, nil-tolerant
fields — `ObservedVMState.guestInfo` and the volume snapshot's attached-VM hint
at v15 (the QEMU guest agent, issue #563; the hint lives on
`DesiredSnapshotCapture` since v33), `ObservedVMState.memoryStats` at
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
NICs, SSH keys, user and vendor data, tags, and an `IdentityPolicy` naming the
VM's SPIFFE instance identity —
which the agent serves to the guest from the link-local metadata address
(169.254.169.254) instead of baking it into a boot-time seed ISO. Putting it on
the sync is the whole point of the design: the metadata store inherits
level-triggering, generation guards, and replay safety from the machinery that
already exists, so an operator's edit propagates on the next sync with no
second control loop, no second transport, and nothing in the payload that can
expire. Carrying the metadata on the sync is shipped, and so is holding it: the
agent's `MetadataStore` records each VM's copy as syncs arrive (STR-52). Serving
it is not — no agent yet answers HTTP on `169.254.169.254`, so the guest-facing
IMDS listener is future work (the v27 chassis/localport half and the store are
what exist agent-side, see [agent](./agent.md)).

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
`NetworkReconciler.serviceLocalPortProtection(for:)` explicitly protects the ports of
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

Version 30 lets an agent say "I don't know what is on this host" (STR-138),
via `ObservedStateReport.manifestStatus`. It carries no gate and refuses no
placement, for the same reason v25 doesn't: the field only ever *withholds*
action.

Version 31 makes volumes desired state (ADR 0001 stage 5, STR-148).
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
imperative fallback left, a volume placed on a pre-v31 agent could never be
created. Volumes already sitting on such an agent when the control plane
upgrades simply freeze — their rows are never reaped, because that agent's
reports say nothing about volumes — until the agent is upgraded. Deleting one
still works: the delete path force-clears the agent-absence finalizer for an
agent that cannot confirm.

Version 32 removes `volume_info` (ADR 0001 stage 7, STR-149) — the v28 shape
without even v28's skew hazard, because the message had no sender on either
side of any version. Nothing was added to the observed report to replace it: a
read is not desired state, and for every field the message carried, one side
already knew the answer. Format, storage path and attachment have been on
`ObservedVolumeState` since v31; the requested size is a control-plane column
whose realization `observedGeneration` confirms. (The *virtual* size did come
back in v38, on the narrower ground below: a refused grow made the desired size
a misleading answer, and the planner's cache had made the subprocess free.) The
remainder — allocated
bytes, the qcow2 dirty flag, the encryption flag — has no reader, and
allocation moves with every guest write, so it cannot be cached the way virtual
size is and would cost a `qemu-img info` per volume on a report assembled on
every convergence action. `StorageBackend.volumeInfo` survives as the agent's
own probe behind the resize planner's size cache.

Version 33 makes snapshots and checkpoints desired artifacts (ADR 0001 stage
8, STR-150). `DesiredStateMessage` gains `snapshots` and `ObservedStateReport`
gains its counterpart; seven imperative frames go — `volume_snapshot`,
`volume_snapshot_delete`, `vm_checkpoint`, `vm_snapshot_delete`,
`sandbox_snapshot_create`, `sandbox_snapshot_delete` and
`sandbox_snapshot_export`. `vm_restore` and `sandbox_restore` survive; they are
edges rather than states, and convert to nonces at v34.

Both hazard shapes are v31's, and the `Optional`-not-`[]` treatment is the
same, one step more expensive to get wrong: an empty `snapshots` the control
plane believed would reap every checkpoint row it holds for the agent, and a
checkpoint is a point in time nothing can recreate.

Where the gate sits is what differs from v31. A volume is *placed* by the
control plane, so v31 could simply refuse to schedule one onto an agent that
could not converge it; an artifact inherits its parent's host, so there is no
placement decision to gate. `supportsSnapshotSync` gates **capture admission**
instead — `POST .../snapshots` against a pre-v33 agent is refused with `409`,
which is exactly what the pre-v22/v9 capability preflights already did, one
floor higher. Artifacts already on such an agent freeze until it is upgraded;
deleting one still works, by force-clearing the agent-absence finalizer.

Version 34 makes reboot and restore edge-nonces (ADR 0001 stage 9, STR-151),
and takes the last three durable-resource RPCs with them: `vm_reboot`,
`vm_restore`, `sandbox_restore`. `DesiredVMState` gains `rebootGeneration` and
`restore`; `DesiredSandboxState` gains `restore`. Nothing imperative is left on
the wire but live byte streams.

These three resisted every earlier stage because they really are edges: a
reboot starts and ends `running`, and "be at checkpoint C" stops being true the
moment the guest resumes. Counting them is what makes them states — the
`kubectl rollout restart` shape, where the edge becomes a state once *how many
times it was asked* is part of the state. The agent applies one only when the
desired count outranks the one it recorded, so a dropped, replayed or re-driven
sync converges instead of restarting a guest twice.

Two things are worth knowing about this bump specifically. First, it is
**strictly better than what it replaces**: a fire-and-forget RPC whose socket
dropped mid-flight lost the reboot silently, where a nonce survives and
converges. Second, the correctness invariant moved to the agent and became a
*durability* question rather than a delivery one — the applied nonces live in
`VMManifestStore`, and an entry with **no record** (written by an older build,
or never converged here) is *adopted* rather than read as zero. Reading it as
zero would have a re-registered agent replay a VM's whole restore history.

The gate is unusual too. Both fields are `Optional` like v31's and v33's, but
absence here is inert in every direction — a count of requests can only mean
"nothing was asked for" — so `supportsEdgeNonces` is not defending the payload.
It defends the *request*: with no fallback frame left, a reboot aimed at a
pre-v34 agent would be accepted into a field that agent ignores and then
reported as converged, so it is refused with `409` at admission.

Version 35 adds online volume grow and per-volume I/O ceilings (STR-19):
`ioLimits` on `DesiredVolumeState`, `VolumeSpec` and `ObservedVolumeState`. No
frame changes and no gate — the first bump since v23 without one. The observed
echo is what carries the skew instead: nil means "this agent does not report
applied limits", while a present-but-empty `VolumeIOLimits` means "applied, and
the answer is uncapped", so a fleet mid-upgrade shows caps requested rather
than done.

Version 36 realizes internal names in the datapath (STR-39, roadmap #769).
`DesiredStateMessage` gains `dnsZones`: for each zone attached to a network the
receiving agent authors, its id, name, attached network ids, effective record
set and a `recordsHash`. The agent writes them to the OVN Northbound `DNS`
table and references them from `Logical_Switch.dns_records`, so `ovn-controller`
answers `dns_lookup()` in the datapath — no daemon, no HA story, no failure
domain.

Two structural decisions are worth reading before extending it. The field rides
the **network carrier, not `NetworkSpec`**, for `dhcpEnabled`'s reason: DNS
edits don't bump VM generations, so a converged VM never re-realizes its NICs
and a per-NIC field would reach nobody. And records travel **typed**
(`name`/`type`/`values`) rather than pre-flattened into OVN's `name → addresses`
map, so realization stays a swappable driver and the *receiver* decides what its
backend can express — the OVN driver joins a name's A and AAAA values and skips
CNAME/TXT/SRV with a diagnostic.

Absence is v31's asymmetric shape, and the reading matters more than usual
because these rows are switch-scoped topology written by *one* agent while
their contents come from every agent in the site: nil is "no opinion" and a
**non-authoritative agent is sent nil, not `[]`**, so a controller handover can
never have two writers reading each other's rows as garbage. `[]` is an opinion
and does remove managed rows, which is what makes detaching the last zone from
a network take effect. `supportsDNSZones` gates only the field (and lets
assembly skip the fleet-wide record queries for an agent that would discard
them); unlike v33 and v34 there is no admission gate, because nothing reports a
zone as converged, so there is no false success to refuse.

Version 37 gives every network a resolver (STR-40, roadmap #769 phase 4).
`DesiredNetworkState` and `NetworkSpec` gain `resolverEnabled`, and
`DesiredDNSRecord` gains `ttl`.

The two `resolverEnabled` fields are the v27 metadata-port pair repeated
exactly, and for the same reason: the network carrier authors the OVN
`localport` and the DHCP row, while the per-NIC copy reaches the *chassis* half
on agents that receive an empty `networks` list because they may not author
topology.

Each carrier also gains `resolverAddresses`, non-nil exactly when the flag is
true: **one distinct v4/v6 pair per network**, allocated from `169.254.0.0/16`
and `fd00:ec2:1::/48`. That distinctness is the whole feature. A resolver in the
network's own chassis namespace has only link-local addresses and no egress the
OVN router will SNAT, so it answers for its zones and forwards nothing — the bug
the phase was filed to fix. A pair per network puts every resolver in the *host*
namespace, where forwarding is the hypervisor's own, while the destination
address still identifies the network and a per-address routing rule returns the
reply to the right switch. See ADR 0008.

`ttl` is the field v36 deliberately left off — an OVN `DNS` row has nowhere to
put one, so it would have been dead weight on every sync. A zone file writes one
TTL per RRset, so the CoreDNS driver cannot render without it. It is folded into
`recordsHash`, which moves every stamp once on upgrade and heals with one
rewrite per zone.

Two consequences reach past the new fields. **`dnsZones` widens past the
topology authority**: OVN `DNS` rows are switch-scoped and still written only by
the site's controller, but a resolver runs wherever the guests are, so a zone
now goes to any agent that authors an attached network *or* runs a local NIC on
one — and the agent picks which half to realize from `networksAuthoritative`,
which it already has. And **`dnsServers` is redefined rather than replaced**: on
a resolver-enabled network the DHCP `dns_server` option becomes the resolver's
link-local address and the configured list becomes its upstream forwarders. The
field, its validation and its wire shape are unchanged; only the consumer moves.

`supportsNetworkResolver` gates only the fields, and deliberately not admission
— the asymmetry with v34 is the point. A pre-v37 agent that ignores
`resolverEnabled` keeps handing guests the configured `dnsServers` verbatim,
which is exactly what it did before the field existed, so the failure mode is
"this network has not got its resolver yet" rather than a mutation reported as
converged when nothing happened. What *is* refused is enabling the feature at
all where it cannot work: `AgentRegisterMessage.resolverCapable` reports whether
a host has a usable CoreDNS, and the control plane withholds `resolverEnabled`
unless **every** agent in the site says yes — because the DHCP option is
authored once per network by the topology authority while the listener is per
chassis, so one incapable host would give that network DNS that works until a VM
lands somewhere else.

Version 38 lets a volume report the size it actually has (STR-199):
`ObservedVolumeState` gains `sizeBytes`. Agent→control-plane only, no frame
changes, and no gate — like v35 there is nothing to gate, since the control
plane does not change what it *sends* based on the answer and a desired size has
always converged without it. It closes a gap v32 argued was not worth a
subprocess: with only the desired `size` to report, a volume whose grow the
agent had refused answered with the size it had *failed* to reach. The
subprocess objection expired on its own — the resize planner needs the same
number and already caches one per volume. Absence is v35's echo shape: nil is
"this agent said nothing", never zero, so a pre-v38 agent's silence leaves
`observed_size_bytes` as the last report that spoke left it.

**A capability is sometimes the whole answer, with no bump at all.** STR-103
put sandbox NICs on the wire without touching the version, because
`SandboxSpec.network` has been in the shape since v5 — what was missing was
never a field an old agent could not decode, but evidence that a given host can
realize one. That evidence cannot come from a version: the three things a
sandbox NIC needs (OVN, the jailer barrier, and a guest image whose init
configures the interface) are all installed independently of the agent binary,
so an agent at `currentVersion` paired with a two-releases-old guest image
would refuse the config drive. Hence
`AgentRegisterMessage.sandboxNetworkingCapable`, re-probed at every
registration, gating both placement and whether assembly puts the NIC on the
wire — the `sandboxCapable` shape, applied to a sharper question. Reach for a
version bump when a peer would *misread* a payload; reach for a capability when
it would understand the payload perfectly and still be unable to act on it.

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
| `console_connect`, `console_disconnect`, `console_data` | Console session control and input. `console_connect.stream` picks the serial console (default) or the VNC framebuffer (v23+) |
| `sandbox_exec_start`, `sandbox_exec_input`, `sandbox_exec_resize`, `sandbox_exec_close` | Interactive exec into a sandbox (v8+) |

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
| `agent_register` | Handshake: hostname, version, capabilities, resources, hypervisor support, architecture/OS, `sandboxCapable`, `sandboxNetworkingCapable`, protocol version |
| `agent_heartbeat` | Periodic resource usage and running VM IDs |
| `agent_unregister` | Graceful disconnect with a reason |
| `observed_state` | Level-triggered `ObservedStateReport`: VM/sandbox observed state, resources, agent-update status, optional per-VM `guestInfo` from qga (issue #563), and optional per-VM balloon `memoryStats` (issue #567, incl. `balloonActualBytes` at v19) |
| `vm_log`, `sandbox_log` | Log lines destined for Loki |
| `console_connected`, `console_disconnected`, `console_data` | Console session lifecycle and output |
| `sandbox_exec_started`, `sandbox_exec_output`, `sandbox_exec_exit`, `sandbox_exec_closed` | Exec stream responses |

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
  optional `IdentityPolicy`. Since STR-55 that policy carries the VM's SPIFFE
  instance identity — `spiffe://<trust-domain>/vm/<vm-id>` and nothing else:
  no key, no token, no audiences, no TTL. It clears the publication boundary
  below precisely because it is a *name*; the audiences and lifetime an issuer
  would need arrive with the minting endpoint (STR-57). It rides
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
