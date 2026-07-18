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
  `invalid_token` and `unsupported_protocol_version`).

## Versioning

`WireProtocol.swift` holds the protocol version (currently 8), stamped on
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

The doc comment on `currentVersion` is a narrative changelog of every bump —
read it before adding a version. Adding an enum case to a strictly-decoded
wire type (see `DesiredVMStatus` below) also requires a version bump and a
dual-mode rollout.

## Message catalog

`MessageType` in `WebSocketProtocol.swift` is the master list. By direction:

**Control plane → agent**

| Message | Purpose |
|---|---|
| `agent_register_response` | Registration reply: assigns the agent's DB UUID and name, rotates the reconnect token, echoes the protocol version |
| `desired_state` | The authoritative `DesiredStateMessage` sync (see below) |
| `vm_reboot` | Reboot — still imperative because a reboot is an action, not a state |
| `vm_create`, `vm_boot`, `vm_shutdown`, `vm_pause`, `vm_resume`, `vm_delete`, `vm_info`, `vm_status` | **Deprecated** imperative VM lifecycle (issue #261), superseded by desired-state sync; kept for older control planes |
| `network_*` (create/delete/list/info/attach/detach) | Network operations |
| `volume_*` (create/delete/attach/detach/resize/snapshot/snapshot_delete/clone/info) | Volume operations (QEMU-backed VMs only) |
| `console_connect`, `console_disconnect`, `console_data` | Console session control and input |
| `sandbox_exec_start`, `sandbox_exec_input`, `sandbox_exec_resize`, `sandbox_exec_close` | Interactive exec into a sandbox (v8+) |
| `agent_update` | Imperative agent self-update (v6+) |

**Agent → control plane**

| Message | Purpose |
|---|---|
| `agent_register` | Handshake: hostname, version, capabilities, resources, hypervisor support, architecture/OS, `sandboxCapable`, protocol version |
| `agent_heartbeat` | Periodic resource usage and running VM IDs |
| `agent_unregister` | Graceful disconnect with a reason |
| `observed_state` | Level-triggered `ObservedStateReport`: VM/sandbox observed state, resources, agent-update status |
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
  signed URLs are re-issued at every sync assembly.
- `DesiredSandboxState` mirrors it for sandboxes (with an optional registry
  credential); `DesiredNetworkState` reconciles OVN logical networks
  (switch/subnets/gateways, per-project `routerKey`, SNAT, DHCP);
  `DesiredAgentUpdate` is the declarative agent-update target.

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

- Anything omitted from the list should not exist on the agent.
- Identical syncs diff to nothing; the message is safe to drop, replay, or
  reorder (generations guard the reorder case).
- Backward compatibility is asymmetric by design: when decoding from an older
  peer, missing `sandboxes`/`networks` decode to empty lists, but the agent
  must **not** interpret that as "tear everything down" — reconciliation of
  each list is gated on the corresponding version gate
  (`supportsSandboxSync`, `supportsNetworkSync`).

`ObservedStateReport` is the mirror image: the full observed VM/sandbox sets
plus current resources, sent level-triggered from the agent.

## Shared DTOs

The rest of the package is vocabulary used on both sides:

- **`VMSpec`** (`VMSpec.swift`) — the hypervisor-neutral machine description:
  CPU/memory/disk sizing, `BootSource` (`.disk(firmware:)` vs
  `.directKernel(kernel:initramfs:cmdline:)`), `VolumeSpec`, dual-stack
  `NetworkSpec`, `ConsoleSpec`, SSH keys.
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
