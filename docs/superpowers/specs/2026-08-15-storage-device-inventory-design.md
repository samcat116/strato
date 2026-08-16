# STR-156 Storage Device Inventory Design

**Status:** Approved for implementation planning

**Issue:** STR-156, phase 3 of ADR 0002

## Purpose

Strato cannot orchestrate a Ceph cluster until it knows which whole physical
disks exist on each agent and which disks an operator has selected for future
OSD provisioning. This phase adds that inventory and selection intent without
running Ceph, formatting disks, or changing the existing local-storage path.

The safety invariant is that a storage operation must never follow a Linux
device path onto a different physical disk. A path such as `/dev/sdb` is
display data. A normalized WWN is the preferred durable identity and a trimmed
serial number is the fallback. A path is never a durable identity or an OSD
eligibility key.

## Scope

This phase provides:

- Linux agent enumeration of whole physical disks and recursive use detection.
- A full-list storage inventory in the existing agent observed-state report.
- Durable control-plane rows keyed by agent and hardware identity.
- Preservation and display of disappeared devices.
- A site-filterable inventory API and UI.
- One operator mutation: mark or unmark a safe device as OSD eligible.

This phase does not provide:

- Ceph bootstrap, cephadm, OSD creation, disk wiping, or disk formatting.
- Assignment of an `osdId`.
- An operator control for the future `excluded` role.
- Device replacement or OSD draining workflows.
- Mapping of local storage pools or local volumes to physical-device rows.
- Local-storage capacity scheduling from raw-device inventory.
- Partition or logical-volume rows that can be selected independently.

## Domain model

### Identity

Each observed whole disk has an optional `StorageDeviceIdentity`:

```swift
public enum StorageDeviceIdentityKind: String, Codable, Sendable {
    case wwn
    case serial
}

public struct StorageDeviceIdentity: Codable, Equatable, Sendable {
    public let kind: StorageDeviceIdentityKind
    public let value: String
}
```

Identity selection is deterministic:

1. Trim the raw WWN. If it is non-empty, normalize it to lowercase and remove
   one leading `0x`, then use `.wwn`.
2. Otherwise trim the raw serial. If it is non-empty, use `.serial` without
   changing its case.
3. Otherwise identity is `nil`.

The raw WWN and serial remain separate display fields. The control plane does
not silently merge a serial-keyed row into a WWN-keyed row if an agent later
reports different identity facts. The new identity creates a new unassigned
row and the old row becomes missing. Requiring an operator to reselect a disk
is safer than transferring destructive intent across an inferred alias.

### Observed device

Wire protocol version 51 adds the following shared values:

```swift
public enum StorageDeviceUse: String, Codable, Sendable {
    case childDevice
    case partitionTable
    case filesystem
    case mounted
    case swap
    case lvmPhysicalVolume
    case readOnly
}

public enum StorageDeviceState: String, Codable, Sendable {
    case available
    case inUse
    case draining
    case faulted
}

public struct ObservedStorageDevice: Codable, Equatable, Sendable {
    public let identity: StorageDeviceIdentity?
    public let devicePath: String
    public let sizeBytes: Int64
    public let model: String?
    public let serial: String?
    public let wwn: String?
    public let rotational: Bool
    public let state: StorageDeviceState
    public let uses: [StorageDeviceUse]
}
```

The agent probe emits only `available`, `inUse`, and `faulted`. `draining` is
reserved for the later OSD lifecycle. Use values are unique and sorted by raw
value before transport so equivalent snapshots encode deterministically.

### Persisted device

The control plane adds a `storage_devices` table and Fluent model with:

```swift
enum StorageDeviceRole: String, Codable {
    case unassigned
    case osd
    case excluded
}
```

- `id: UUID`
- `agentId: UUID`
- `identityKind: StorageDeviceIdentityKind?`
- `identityValue: String?`
- `devicePath: String`
- `sizeBytes: Int64`
- `model: String?`
- `serial: String?`
- `wwn: String?`
- `rotational: Bool`
- `uses: [StorageDeviceUse]`
- `role: StorageDeviceRole`, with `unassigned`, `osd`, and `excluded`
- `state: StorageDeviceState`
- `osdId: Int?`
- `present: Bool`
- `lastSeenAt: Date`
- `createdAt: Date?`
- `updatedAt: Date?`

The schema requires identity kind and value to be both null or both non-null,
and uniquely constrains non-null `(agent_id, identity_kind, identity_value)`.
The agent foreign key cascades on agent deletion. Size must be non-negative.

The three device axes are deliberately independent:

- `role` is durable operator or future orchestrator intent.
- `state` is the most recent observation of whether the device can be used.
- `present` says whether the latest complete snapshot contained the device.

An observation updates hardware facts, state, presence, and `lastSeenAt`, but
never overwrites `role` or `osdId`.

### Anonymous devices

A disk without a WWN or serial remains visible but is permanently ineligible
for an OSD role. It is persisted as a display-only row with null identity. To
avoid creating a new row on every sweep, the reconciler may correlate it with
a currently-present anonymous row on the same agent and path. That correlation
is not hardware identity and grants no storage authority.

If an anonymous path disappears, the old row becomes missing. If an anonymous
disk later appears after that absence, or appears under a different path, it
gets a new unassigned display row. This may show more history than a stable
identity would, but it cannot carry OSD intent onto another disk.

## Agent inventory module

### Interface and seam

The agent gets one focused module whose external interface is a complete
snapshot or no opinion:

```swift
func observe() async -> [ObservedStorageDevice]?
```

The module hides executable discovery, process limits, JSON decoding,
identity normalization, tree traversal, and state derivation. JSON decoding
and observation mapping are directly testable with fixtures; no public
process-runner protocol is added for a single adapter.

### Linux enumeration

On Linux the module locates `lsblk` in explicit standard paths and invokes it
without a shell through the existing bounded `ProcessRunner`. The command is
equivalent to:

```text
lsblk --json --bytes --tree \
  --output NAME,PATH,TYPE,SIZE,MODEL,SERIAL,WWN,ROTA,RO,FSTYPE,PTTYPE,MOUNTPOINTS,STATE
```

The process has a five-second timeout and a four-MiB combined-output limit.
Only `TYPE=disk` nodes become inventory entries. Their descendants are walked
recursively to determine use; partitions, device-mapper nodes, and logical
volumes never become independently selectable rows.

The disk is `inUse` if it or any descendant provides evidence of use:

- A child block device exists.
- A partition table is present.
- A filesystem signature is present.
- A non-empty mount point is present.
- Swap is present through the filesystem or mount-point facts.
- An LVM physical-volume signature or LVM descendant is present.
- The disk is read-only.

Known offline or failed kernel device states make the disk `faulted`. A
non-negative zero size is retained for visibility but is also `faulted` and
cannot be selected. Faulted takes precedence over in-use; otherwise any use
reason produces `inUse`, and a disk with no use reason is `available`.

The decoder tolerates the null and scalar/array shapes util-linux emits for
optional fields, while rejecting a malformed document as a whole. Strings are
trimmed for display and empty strings become null.

On non-Linux platforms the module returns `nil`. It must not return an empty
list, because that would claim the platform has no disks and mark existing
inventory missing.

### Cadence and failure behavior

Registration forces one bounded refresh after the registration handshake and
before the initial observed-state report. Thereafter the agent refreshes on a
throttled cadence after sending its heartbeat. This ordering ensures `lsblk`
cannot delay liveness. Reports triggered by workload events reuse the latest
completed inventory result and never launch their own process.

The latest refresh outcome controls the report:

- Success, including a genuinely empty result, supplies the full list.
- Command absence, non-zero exit, timeout, output overflow, or decode failure
  supplies `nil` and logs a bounded diagnostic.

A failed refresh never re-labels the last successful snapshot as current. The
control plane already retains the last durable rows, and `nil` explicitly tells
it not to apply absence. The next cadence retries automatically.

## Wire contract

`ObservedStateReport` gains:

```swift
public let storageDevices: [ObservedStorageDevice]?
```

The semantics match the existing optional volume and snapshot inventories:

- Non-null is a complete, authoritative list for this agent.
- `[]` is a successful statement that this agent has no whole disks.
- `nil` is no opinion and changes no device row.

The field is independent of workload-manifest health. An agent that cannot
enumerate its VM manifest may still provide a valid storage-device inventory.
Strato requires exact wire-version equality, so this change bumps
`WireProtocol.currentVersion` from 50 to 51 with no compatibility branch.

## Control-plane reconciliation module

### Interface and ordering

After `AgentService` decodes and authenticates an observed-state report, it
passes each non-null device list to a dedicated module:

```swift
func apply(
    _ observations: [ObservedStorageDevice],
    for agent: Agent,
    receivedAt: Date
) async throws
```

The authenticated connection establishes agent ownership. The supplied
`receivedAt` is a control-plane time; agent timestamps never establish
freshness. Device reconciliation runs independently of
`ObservedStateApplier`'s workload-manifest guard.

### Validation and transaction

Before changing rows the module validates the entire snapshot:

- Stable identities are unique within the report.
- Device paths are absolute and unique within the report.
- Identity kind/value and normalized raw facts are internally consistent.
- Sizes are non-negative.
- `draining` is not accepted as an agent observation.
- Use values are unique.

Any violation rejects the complete storage snapshot and preserves every
existing row. Workload observations in the same report may still apply.

One database transaction then:

1. Locks or reloads this agent's existing device rows.
2. Matches identified observations only by stable identity.
3. Matches anonymous observations only to currently-present anonymous rows
   with the same path.
4. Inserts new observations with `role = unassigned`, `osdId = nil`, and
   `present = true`.
5. Updates matched hardware facts, state, uses, path, `present = true`, and
   `lastSeenAt = receivedAt`, preserving role and OSD ID.
6. Marks every previously-present unmatched row `present = false` without
   deleting it or changing its last-known facts, role, state, OSD ID, or
   `lastSeenAt`.

Missing and reappeared transitions get structured logs. Repeated identical
snapshots do not create new rows or change operator intent.

## Local storage and Ceph storage

The existing local storage backend remains filesystem-backed and independent
of device inventory. This phase does not attach a `StorageDevice` to a
`StoragePool`, a local volume, or the agent's aggregate disk-capacity fields.

Expected combinations are:

| Physical use | Role | State | OSD ID |
| --- | --- | --- | --- |
| OS/root disk | `unassigned` | `inUse` | null |
| Disk mounted for local Strato storage | `unassigned` | `inUse` | null |
| Blank spare disk | `unassigned` | `available` | null |
| Spare selected for future Ceph use | `osd` | `available` | null |
| Provisioned Ceph OSD in a later phase | `osd` | `inUse` | non-null |
| Pulled provisioned OSD | `osd` | last observed | non-null, `present=false` |

OSD selection and OSD provisioning are different predicates. This phase
allows an operator to record `role = osd`. STR-158 may provision only:

```text
role == osd
and osdId == nil
and present
and observation is fresh
and state == available
```

Once Ceph has provisioned a disk, `inUse` is expected rather than an error.
The non-null OSD ID distinguishes that case from a selected disk that became
occupied before provisioning.

## API

### List devices

`GET /api/storage-devices` returns a paged list and accepts optional
`organization_id`, `site_id`, and `agent_id` filters. Results are restricted
to devices whose owning agent the caller may read. Stable sorting is by site,
agent, presence, path, and row ID.

Each response contains the persisted device fields plus:

- `osdEligible: Bool`, true when `role == osd`.
- `canMarkOsdEligible: Bool`, the server's current false-to-true decision.
- `osdEligibilityBlockedReason: String?`, suitable for operator display.

The response exposes the agent and site IDs so the web client can group rows
using its existing agent and site data.

### Change OSD eligibility

`PATCH /api/storage-devices/{deviceId}` accepts only:

```json
{ "osdEligible": true }
```

The route re-reads the row and owning agent transactionally and requires
`agent:manage`. Unknown fields use the repository's validated-request-body
convention and are rejected.

An idempotent request that already matches the stored role succeeds. A
false-to-true transition returns `409 Conflict` unless all conditions hold:

- The device has a stable WWN or serial identity.
- The device is present.
- The latest state is `available`.
- The owning agent is online.
- `lastSeenAt` is no more than 60 seconds old according to control-plane time.

A true-to-false transition always succeeds, including when the disk is
missing, stale, in use, or on an offline agent. It sets the role to
`unassigned`; this phase never writes `excluded`.

If a selected device later becomes missing, stale, faulted, or in use, the
observation does not erase the role. Its effective provisioning eligibility
becomes false and the API explains the blocking condition. This preserves
operator intent without allowing a later orchestrator to consume unsafe
hardware.

The OpenAPI document is authoritative for route and schema documentation, and
the web TypeScript file is regenerated rather than hand-edited.

## Web interface

The Storage navigation gains **Devices** at `/storage/devices`. It is a fleet
inventory rather than an agent-detail-only card, so an operator can inspect
every disk in a selected site.

The page defaults to the current organization's sites, supports a site filter,
and groups devices by site and agent. Each row shows:

- Current path and model.
- Capacity and rotational/solid-state media.
- WWN or serial, or an explicit “No stable identity” warning.
- Present/missing state and last-seen time.
- Available, in-use, or faulted state.
- Typed use reasons explaining why a disk is occupied.
- OSD eligibility.

Missing devices remain visible by default. The only role control in this phase
is an **OSD eligible** switch. An unselected device that the server says cannot
be selected has a disabled switch and the server-provided reason. A selected
device can always be switched off, even if it is now unsafe or missing.

Enabling opens a confirmation that the choice is durable Ceph intent and a
future orchestration phase may erase the disk. The copy also states that this
phase does not format or provision anything. Disabling needs no destructive
confirmation.

The query hook uses the paged collection endpoint and invalidates device lists
after a mutation. Site and agent names come from the existing site and agent
queries; the storage API remains keyed by IDs.

## Migration and rollout

`CreateStorageDevices` is registered after the current-schema baseline and
the already-landed post-baseline migrations. It creates the role and state
storage, table, constraints, indexes, and foreign key. Its revert removes only
the objects it created. The current baseline SQL is not edited as an upgrade
substitute; a fresh database runs the baseline and then this migration.

The wire version requires a coordinated control-plane and agent deployment,
matching Strato's exact-version registration contract. Before upgraded agents
report, the inventory page is simply empty. No existing storage or agent row
is migrated into a guessed physical-device identity.

## Security and failure properties

- The agent launches `lsblk` directly with fixed arguments and never through a
  shell.
- Timeout and output limits keep hardware enumeration from becoming a liveness
  or memory-exhaustion path.
- Only the authenticated agent connection can report that agent's inventory.
- A partial or invalid snapshot cannot mark devices missing.
- Paths never authorize eligibility, OSD selection, or future provisioning.
- A device cannot be selected using stale or offline observations.
- Selecting a device performs no host mutation in this phase.
- Future provisioning must reapply the stricter provisionable predicate; the
  stored role alone is never sufficient authority to wipe a disk.

## Test strategy

### Shared wire tests

- Pin wire version 51.
- Round-trip identity kinds, hardware facts, state, and sorted use reasons.
- Decode a report with `storageDevices = nil`, `[]`, and populated devices.

### Agent tests

Fixture-driven tests cover:

- A blank WWN disk reported as available.
- Serial fallback when WWN is absent.
- WWN preference when both exist.
- An anonymous disk that remains visible.
- Root and local-storage disks with mounted descendants.
- Empty partitions, filesystem signatures, swap, LVM PVs, LVM descendants,
  read-only devices, and known fault states.
- Whole-disk-only output when partitions and logical volumes exist.
- Numeric and optional JSON field shapes emitted by util-linux.
- Malformed JSON, command failure, timeout, and missing executable producing
  no opinion rather than an empty list.

No test invokes a mutating block-device command.

### Control-plane tests

- The migration creates constraints, indexes, and cascading agent ownership.
- Reporting one WWN under `/dev/sdb`, selecting it, and reporting it under
  `/dev/sdc` preserves row ID, role, and OSD ID while updating the path.
- A complete report marks an unseen device missing without deleting it.
- An empty complete report marks all previously-present devices missing.
- A nil report changes nothing.
- A duplicate or invalid snapshot makes no partial device change.
- Observations never overwrite role or OSD ID.
- Anonymous path correlation never makes an anonymous row selectable.
- Workload-manifest failure does not suppress valid device reconciliation.
- Read and mutation authorization follow owning-agent permissions.
- Anonymous, in-use, missing, stale, and offline devices are refused on enable.
- Disable remains available in every device and agent state.
- A mounted local-storage disk is `unassigned + inUse` and cannot be selected.
- A later-phase `osd + inUse + osdId` combination remains representable.

### Web tests

- Navigation includes the Devices page under Storage.
- Site filtering and site/agent grouping preserve every returned row.
- Missing and anonymous warnings render.
- Use reasons and server refusal text render.
- Unsafe unselected switches are disabled.
- Selected unsafe devices can still be switched off.
- Enabling requires the destructive-future-intent confirmation.

### Verification commands

Implementation verification will run focused tests for `shared`, `agent`, and
the control-plane test target; database-backed tests with the repository's
PostgreSQL configuration; OpenAPI TypeScript generation; frontend tests,
lint/type checks, and a production web build. Validation will report package
and platform boundaries precisely. No live disk, Ceph, or formatting action is
part of verification.
