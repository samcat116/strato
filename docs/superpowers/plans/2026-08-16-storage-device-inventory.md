# Storage Device Inventory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let operators see every physical block device reported by every visible agent and opt safe, unused, stably identified devices into future Ceph OSD orchestration without performing any disk mutation in this phase.

**Architecture:** A Linux-only agent probe produces a complete, bounded `lsblk` snapshot with WWN-first identity and serial fallback. The control plane transactionally reconciles each successful snapshot into durable rows, retaining missing devices and operator intent, while a separate API computes and enforces OSD-eligibility safety. A new Storage page consumes that API and exposes only the OSD-eligibility decision.

**Tech Stack:** Swift 6.2, Swift Testing, Vapor, Fluent/PostgreSQL, SQLKit, Next.js, React, TypeScript, TanStack Query, Vitest, Testing Library, OpenAPI.

## Global Constraints

- Wire protocol version 52 is an exact cutover. Do not add a v51 compatibility decoder or a dual-format registration path.
- A device path is display data only. Never use `/dev/sd*` as durable identity or to retain OSD intent.
- Normalize a WWN by trimming whitespace, lowercasing, and removing a leading `0x`. Normalize a serial by trimming whitespace only.
- A successful empty observation means that the agent has no qualifying whole disks and marks its existing rows missing. A failed observation is `nil` and makes no database changes.
- Only whole physical disks (`TYPE=disk`) become top-level inventory rows. Descendants inform usage; they do not become independently eligible devices.
- Devices without WWN or serial remain visible but can never become OSD-eligible. Anonymous rows may correlate only by the same current path while present and must never retain OSD intent across disappearance or path changes.
- Reconciliation preserves `role` and `osdId` on stably identified rows, rejects the whole storage snapshot on duplicate or invalid observations, and does not block workload observed-state processing.
- Enabling OSD eligibility requires stable identity, presence, `available` state, an online agent, and an observation no older than 60 seconds. Disabling eligibility always succeeds.
- `role=osd` is an operator selection only. This issue must not format disks, run Ceph commands, assign an OSD ID, or mutate local storage.
- Existing operating-system and local-only data disks remain `unassigned`; their observed use makes them `inUse`, which prevents selection without changing their current function.
- Use request cancellation, bounded subprocess runtime, and bounded output. Do not invoke a shell.
- Run the stated red test before production code and confirm that it fails for the expected missing behavior, not for unrelated setup.
- Keep generated `control-plane/web/src/types/openapi.ts` generated from `control-plane/Sources/App/openapi.yaml`; do not hand-edit it.

## File and Responsibility Map

| Area | Files | Responsibility |
| --- | --- | --- |
| Shared wire | `shared/Sources/StratoShared/StorageDeviceInventory.swift`, `ReconciliationProtocol.swift`, `WireProtocol.swift` | Canonical observation types and v52 report field |
| Agent probe | `agent/Sources/StratoAgentCore/BlockDeviceInventory.swift` | Bounded `lsblk` launch, decoding, use classification, refresh cache |
| Agent lifecycle | `agent/Sources/StratoAgent/Agent.swift` | Registration refresh, heartbeat refresh, report attachment |
| Persistence | `control-plane/Sources/App/Models/StorageDevice.swift`, `Migrations/CreateStorageDevices.swift`, `configure.swift` | Durable inventory, constraints, registration |
| Reconciliation | `control-plane/Sources/App/Services/StorageDeviceInventoryReconciler.swift`, `AgentService.swift` | Transactional full-snapshot merge independent of workload apply |
| API and IAM | `control-plane/Sources/App/Controllers/StorageDeviceController.swift`, `IAM/AgentAuthorization.swift`, `AgentController.swift`, `routes.swift`, `openapi.yaml` | Visible listing, eligibility mutation, shared agent authorization |
| Web data | `control-plane/web/src/types/api.ts`, `lib/api/storage-devices.ts`, `lib/hooks/use-storage-devices.ts`, generated OpenAPI types | Typed list and mutation client |
| Web UI | `components/storage-devices/*`, `components/ui/switch.tsx`, dashboard page, navigation | Grouped inventory, site filter, warnings, eligibility control |

---

## Task 1: Add the v52 Storage Observation Contract

**Files:**

- Create: `shared/Sources/StratoShared/StorageDeviceInventory.swift`
- Create: `shared/Tests/StratoSharedTests/StorageDeviceInventoryTests.swift`
- Modify: `shared/Sources/StratoShared/ReconciliationProtocol.swift`
- Modify: `shared/Sources/StratoShared/WireProtocol.swift`
- Modify: `shared/Tests/StratoSharedTests/WireProtocolTests.swift`
- Modify: `shared/Tests/StratoSharedTests/AgentMessageTests.swift`

**Interfaces:**

- Produces `StorageDeviceIdentityKind`, `StorageDeviceIdentity`, `StorageDeviceUse`, `StorageDeviceState`, and `ObservedStorageDevice` for the agent and control plane.
- Extends `ObservedStateReport` with `storageDevices: [ObservedStorageDevice]?`.
- Raises `WireProtocol.currentVersion` from 51 to 52.

- [ ] Write identity normalization and preference tests first:

```swift
@Test func preferredIdentityUsesNormalizedWWNBeforeSerial() {
    #expect(
        StorageDeviceIdentity.preferred(wwn: " 0x5000CCA123ABCDEF ", serial: " SERIAL-1 ")
        == StorageDeviceIdentity(kind: .wwn, value: "5000cca123abcdef")
    )
}

@Test func preferredIdentityFallsBackToTrimmedSerial() {
    #expect(
        StorageDeviceIdentity.preferred(wwn: "  ", serial: " SERIAL-1 ")
        == StorageDeviceIdentity(kind: .serial, value: "SERIAL-1")
    )
}

@Test func preferredIdentityRejectsBlankInputs() {
    #expect(StorageDeviceIdentity.preferred(wwn: nil, serial: "   ") == nil)
}
```

- [ ] Add an observed-state round-trip test containing one identified device and one anonymous device, plus a decode test proving an omitted `storageDevices` field becomes `nil` within protocol v52.
- [ ] Update the protocol-version assertion to expect 52 and add a retired-v51 assertion following the existing retired-discriminator/version style.
- [ ] Run `cd shared && swift test --filter StorageDeviceInventoryTests`; expect failure because the types do not exist.
- [ ] Implement the shared types as `public`, `Codable`, `Equatable`, `Hashable`, and `Sendable` where applicable:

```swift
public enum StorageDeviceIdentityKind: String, Codable, Sendable {
    case wwn
    case serial
}

public struct StorageDeviceIdentity: Codable, Equatable, Hashable, Sendable {
    public let kind: StorageDeviceIdentityKind
    public let value: String

    public init(kind: StorageDeviceIdentityKind, value: String) {
        self.kind = kind
        self.value = value
    }

    public static func preferred(wwn: String?, serial: String?) -> Self? {
        if let wwn = normalizedWWN(wwn) {
            return Self(kind: .wwn, value: wwn)
        }
        if let serial = normalizedSerial(serial) {
            return Self(kind: .serial, value: serial)
        }
        return nil
    }
}

public enum StorageDeviceUse: String, Codable, CaseIterable, Sendable {
    case mounted
    case filesystem
    case partitionTable
    case swap
    case lvmPhysicalVolume
    case readOnly
    case childDevice
}

public enum StorageDeviceState: String, Codable, Sendable {
    case available
    case inUse
    case draining
    case faulted
}
```

- [ ] Define `ObservedStorageDevice` with `identity`, `devicePath`, `sizeBytes`, `model`, `serial`, `wwn`, `rotational`, `uses`, and `state`. Its initializer must preserve the raw serial and WWN display values while accepting the preferred normalized identity separately.
- [ ] Add `storageDevices: [ObservedStorageDevice]? = nil` to the report initializer and stored properties so existing call sites continue to compile while nil retains the explicit no-op meaning.
- [ ] Change the current wire version to 52 without adding compatibility branches.
- [ ] Run `cd shared && swift test --filter StorageDeviceInventoryTests` and `cd shared && swift test --filter WireProtocolTests`; expect both to pass.
- [ ] Run `cd shared && swift test`; expect the whole shared package to pass.
- [ ] Commit with `git add shared && git commit -m "Add storage inventory wire contract"`.

## Task 2: Build the Bounded Linux Block-Device Probe

**Files:**

- Create: `agent/Sources/StratoAgentCore/BlockDeviceInventory.swift`
- Create: `agent/Tests/StratoAgentTests/BlockDeviceInventoryTests.swift`

**Interfaces:**

- Consumes `ProcessRunner.run(executableURL:arguments:timeout:environment:maxOutputBytes:)` and shared observation types.
- Produces `BlockDeviceInventoryProbe.observe() async -> [ObservedStorageDevice]?` and a throttled `StorageDeviceInventoryCache`.

- [ ] Add decoder tests with literal `lsblk` JSON fixtures for:

  - a blank disk with WWN and no descendants (`available`, no uses);
  - an OS disk whose child partition is mounted and has a filesystem (`inUse`, descendant-derived uses);
  - an LVM physical volume (`inUse`, `.lvmPhysicalVolume`);
  - a swap child (`inUse`, `.swap`);
  - a read-only disk (`inUse`, `.readOnly`);
  - a disk with a partition table but no mounted children (`inUse`, `.partitionTable`);
  - a zero-sized disk and disks with known offline/failed kernel states (`faulted`, which takes precedence over use);
  - a WWN-less disk with serial fallback;
  - an identityless disk that remains in the returned array;
  - non-disk top-level nodes that are excluded;
  - malformed JSON and negative sizes that fail the complete observation.

- [ ] Add launch tests through an injected `@Sendable` runner closure to assert the first existing executable from `/usr/bin/lsblk`, `/bin/lsblk`, `/usr/sbin/lsblk`, `/sbin/lsblk`, exact arguments, `LC_ALL=C`, a 5-second timeout, and a 4 MiB shared output ceiling.
- [ ] Add failure tests proving missing executable, nonzero exit, timeout, output overflow, and invalid UTF-8/JSON all return `nil`, never `[]`.
- [ ] Add cache tests proving a failed refresh makes the latest report value nil while leaving control-plane durability to preserve prior rows, a successful empty refresh stores `[]`, ordinary refresh respects a 30-second minimum interval, and `force: true` bypasses the interval.
- [ ] Run `cd agent && swift test --filter BlockDeviceInventoryTests`; expect failure because the probe does not exist.
- [ ] Implement private `Decodable` structs matching `blockdevices` and recursive `children`. Decode `size` as an integer that accepts the JSON number/string shapes emitted by supported util-linux versions.
- [ ] Implement descendant traversal that unions uses into the whole-disk record. Treat any nonempty `fstype`, `mountpoints`, `pttype`, `FSTYPE=swap`, `FSTYPE=LVM2_member`, `TYPE=lvm`, child presence, or read-only flag as in use. Map known offline/failed kernel states and a zero size to `faulted`; faulted takes precedence over in-use. Sort and deduplicate uses by raw value for deterministic wire output.
- [ ] Implement the probe with no shell:

```swift
public struct BlockDeviceInventoryProbe: Sendable {
    public static let timeout: Duration = .seconds(5)
    public static let maxOutputBytes = 4 * 1024 * 1024

    public func observe() async -> [ObservedStorageDevice]? {
        #if os(Linux)
        // Resolve a fixed candidate URL, run lsblk, validate status, decode all rows.
        #else
        return nil
        #endif
    }
}
```

- [ ] Pass these exact arguments as separate array elements:

```swift
[
    "--json", "--bytes", "--tree",
    "--output", "NAME,PATH,TYPE,SIZE,MODEL,SERIAL,WWN,ROTA,RO,FSTYPE,PTTYPE,MOUNTPOINTS,STATE"
]
```

- [ ] Implement an actor cache with injected clock time so cadence tests do not sleep:

```swift
public actor StorageDeviceInventoryCache {
    public typealias Observer = @Sendable () async -> [ObservedStorageDevice]?

    public func refresh(force: Bool, now: ContinuousClock.Instant) async
    public func snapshot() -> [ObservedStorageDevice]?
}
```

  Store the latest completed observation outcome and last attempt time. Coalesce concurrent refresh calls so only one subprocess runs. A failed observation replaces the report value with nil and still throttles repeated attempts until the next interval; it does not synthesize an empty list.
- [ ] Run `cd agent && swift test --filter BlockDeviceInventoryTests`; expect all focused tests to pass.
- [ ] Run `cd agent && swift test`; expect the agent package to pass on macOS with the non-Linux public path returning nil and the injected decoder/runner paths tested directly.
- [ ] Commit with `git add agent/Sources/StratoAgentCore/BlockDeviceInventory.swift agent/Tests/StratoAgentTests/BlockDeviceInventoryTests.swift && git commit -m "Enumerate agent block devices"`.

## Task 3: Attach Inventory to Agent Registration and Heartbeats

**Files:**

- Modify: `agent/Sources/StratoAgent/Agent.swift`
- Modify: `agent/Tests/StratoAgentTests/BlockDeviceInventoryTests.swift`

**Interfaces:**

- Consumes `StorageDeviceInventoryCache` and `ObservedStateReport.storageDevices`.
- Produces an initial forced inventory on registration and a refreshed snapshot after each heartbeat without delaying the heartbeat itself.

- [ ] Extend cache orchestration tests with a recording observer to prove the call sequence: forced registration refresh, snapshot read, heartbeat send boundary, due refresh, snapshot read. Keep this in the testable core abstraction instead of source-text assertions against `Agent.swift`.
- [ ] Run `cd agent && swift test --filter BlockDeviceInventoryTests`; expect the new lifecycle test to fail until the cache exposes the required behavior.
- [ ] Add one cache instance to `Agent`, constructed with `BlockDeviceInventoryProbe().observe` for normal Linux operation and an observer returning nil for simulation/non-Linux operation.
- [ ] In the successful registration path, await `refresh(force: true, now: .now)` immediately before the first `sendObservedStateReport()`. The probe budget is bounded, so registration waits at most the probe timeout plus termination grace.
- [ ] Preserve the current heartbeat ordering: send the heartbeat first, then refresh storage when due, then send the bounded event-driven observed-state report. Do not move the probe ahead of `_sendHeartbeat()`.
- [ ] Populate every `ObservedStateReport` construction with `storageDevices: await storageDeviceInventory.snapshot()` so forced, periodic, and event-triggered reports all reuse the last completed successful result.
- [ ] Confirm a fresh process with no completed result sends nil. Confirm a later probe failure sends nil rather than re-reporting the prior snapshot as fresh or converting it to an empty snapshot; the control plane retains the prior durable rows unchanged.
- [ ] Run `cd agent && swift test --filter BlockDeviceInventoryTests` and `cd agent && swift build --target StratoAgent`; expect both to pass.
- [ ] Commit with `git add agent/Sources/StratoAgent/Agent.swift agent/Tests/StratoAgentTests/BlockDeviceInventoryTests.swift && git commit -m "Report storage inventory from agents"`.

## Task 4: Persist Storage Devices with Database Safety Constraints

**Files:**

- Create: `control-plane/Sources/App/Models/StorageDevice.swift`
- Create: `control-plane/Sources/App/Migrations/CreateStorageDevices.swift`
- Modify: `control-plane/Sources/App/configure.swift`
- Create: `control-plane/Tests/AppPlatformTests/StorageDevicePersistenceTests.swift`

**Interfaces:**

- Consumes shared identity/use/state enums and the existing `Agent` foreign key.
- Produces the `storage_devices` table and Fluent model used by reconciliation and API layers.

- [ ] Write migration tests first to migrate a test database and verify:

  - two agents may report the same WWN;
  - one agent cannot persist duplicate nonnull `(identity_kind, identity_value)`;
  - identity kind and value must both be null or both nonnull;
  - anonymous rows are allowed;
  - invalid role/state values and negative sizes are rejected;
  - deleting an agent cascades its device rows.

- [ ] Run `cd control-plane && swift test --filter StorageDevicePersistenceTests`; expect failure because the model and migration do not exist.
- [ ] Define persisted enums and the model:

```swift
enum StorageDeviceRole: String, Codable, CaseIterable, Sendable {
    case unassigned
    case osd
    case excluded
}

final class StorageDevice: Model, @unchecked Sendable {
    static let schema = "storage_devices"
    // id, agent parent, optional identity kind/value, display fields,
    // uses, role, state, osdId, present, lastSeenAt, timestamps.
}
```

  Use nullable string fields for identity, `@Field` for `[StorageDeviceUse]`, `@Enum` for role/state, `@OptionalField` for `osdId`, and `@Timestamp` for `createdAt`/`updatedAt`.
- [ ] Create the schema with snake-case columns: `agent_id`, `identity_kind`, `identity_value`, `device_path`, `size_bytes`, `model`, `serial`, `wwn`, `rotational`, `uses`, `role`, `state`, `osd_id`, `present`, `last_seen_at`, `created_at`, and `updated_at`.
- [ ] Add PostgreSQL constraints and indexes with SQLKit:

  - unique index on `(agent_id, identity_kind, identity_value)`;
  - check that identity kind/value nullability matches;
  - check identity kind in `wwn,serial` when nonnull;
  - check size is nonnegative;
  - checks for role and state raw values;
  - index `(agent_id, present)` for listing/reconciliation.

- [ ] Register `CreateStorageDevices()` after the current post-baseline migrations in `configure.swift`. Do not modify `CurrentSchema.sql` as a substitute for the forward migration.
- [ ] Run `cd control-plane && swift test --filter StorageDevicePersistenceTests`; expect all focused tests to pass.
- [ ] Commit with `git add control-plane/Sources/App/Models/StorageDevice.swift control-plane/Sources/App/Migrations/CreateStorageDevices.swift control-plane/Sources/App/configure.swift control-plane/Tests/AppPlatformTests/StorageDevicePersistenceTests.swift && git commit -m "Persist agent storage devices"`.

## Task 5: Reconcile Complete Snapshots Without Losing Operator Intent

**Files:**

- Create: `control-plane/Sources/App/Services/StorageDeviceInventoryReconciler.swift`
- Create: `control-plane/Tests/AppPlatformTests/StorageDeviceInventoryReconcilerTests.swift`
- Modify: `control-plane/Sources/App/Services/AgentService.swift`

**Interfaces:**

- Consumes optional device snapshots from authenticated agent reports.
- Produces atomic upserts, missing-device retention, and isolated error handling.

- [ ] Write reconciler tests first for:

  - nil makes no change;
  - successful empty marks all existing agent rows `present=false` without deletion;
  - WWN retains the same row and `role=osd` when `/dev/sdb` becomes `/dev/sdc` after reboot;
  - serial fallback has the same path-renumber behavior;
  - a device that disappears and reappears retains stable identity, role, and OSD ID;
  - a currently present anonymous row updates by same path;
  - an anonymous row that disappears remains missing and a later different-path anonymous disk gets a new row with `unassigned` role;
  - rows belonging to another agent are untouched;
  - duplicate normalized identities reject the whole snapshot;
  - invalid or duplicate paths, negative sizes, identity/raw-fact mismatch, `draining`, duplicate use reasons, or inconsistent state/use combinations reject the whole snapshot;
  - an observation update never overwrites `role` or `osdId`.

- [ ] Add an integration test around `AgentService.applyObservedStateReport` proving an invalid device snapshot is logged/ignored while valid workload observed state from the same message is still applied.
- [ ] Run `cd control-plane && swift test --filter StorageDeviceInventoryReconcilerTests`; expect failure because the reconciler does not exist.
- [ ] Implement this interface:

```swift
struct StorageDeviceInventoryReconciler: Sendable {
    let application: Application

    func apply(
        _ observations: [ObservedStorageDevice],
        for agent: Agent,
        receivedAt: Date
    ) async throws
}
```

- [ ] Validate and normalize the entire array before opening the transaction. Reject duplicate stable identities and any duplicate path. Require an absolute `/dev/` path, nonnegative size, identity values consistent with normalized raw WWN/serial facts, unique use reasons, no agent-emitted `draining`, and `.available` only when `uses` is empty. Accept zero-size devices only as `faulted`.
- [ ] In one database transaction, lock all device rows for the agent with `SELECT id FROM storage_devices WHERE agent_id = $1 FOR UPDATE`, reload them through Fluent, and build stable-identity and currently-present-anonymous-path maps.
- [ ] Upsert stable devices by `(agent, identity kind, identity value)`. Update path/display facts, uses, state, `present=true`, and `lastSeenAt=receivedAt`; preserve role and OSD ID.
- [ ] Match anonymous observations only to a currently present anonymous row at the same path. Force anonymous rows to `role=unassigned` and `osdId=nil` on every update and insert.
- [ ] After all observations are applied, mark every previously present unseen row `present=false`; leave path, role, OSD ID, and `lastSeenAt` intact.
- [ ] In `AgentService`, call the reconciler only when `report.storageDevices` is nonnil, outside the workload manifest/version guard. Catch and log its error so workload processing continues; let database infrastructure failures be visible in logs and metrics without acknowledging a partial device snapshot.
- [ ] Run `cd control-plane && swift test --filter StorageDeviceInventoryReconcilerTests`; expect focused tests to pass.
- [ ] Run `cd control-plane && swift test --filter AgentService`; expect existing observed-state tests plus the new isolation case to pass.
- [ ] Commit with `git add control-plane/Sources/App/Services/StorageDeviceInventoryReconciler.swift control-plane/Sources/App/Services/AgentService.swift control-plane/Tests/AppPlatformTests/StorageDeviceInventoryReconcilerTests.swift && git commit -m "Reconcile reported storage devices"`.

## Task 6: Add the Storage Device API and Eligibility Guard

**Files:**

- Create: `control-plane/Sources/App/IAM/AgentAuthorization.swift`
- Create: `control-plane/Sources/App/Controllers/StorageDeviceController.swift`
- Create: `control-plane/Tests/AppPlatformTests/StorageDeviceControllerTests.swift`
- Modify: `control-plane/Sources/App/Controllers/AgentController.swift`
- Modify: `control-plane/Sources/App/routes.swift`
- Modify: `control-plane/Sources/App/openapi.yaml`
- Modify generated: `control-plane/web/src/types/openapi.ts`
- Modify if required by structural coverage: `control-plane/Tests/AppPlatformTests/ValidatedRequestBodyCoverageTests.swift`

**Interfaces:**

- Produces `GET /api/storage-devices` with optional `organization_id`, `site_id`, and `agent_id` filters plus offset pagination.
- Produces `PATCH /api/storage-devices/{deviceId}` accepting exactly `{ "osdEligible": Bool }`.
- Reuses canonical `agent:read`/`agent:manage` authorization for parent-agent scope.

- [ ] Write controller tests first for list behavior:

  - only devices whose parent agents pass existing visibility filtering are returned;
  - organization, site, and agent filters compose and cannot widen visibility;
  - `total`, `limit`, and `offset` describe the authorization-filtered result;
  - ordering is deterministic by site name, agent name, presence, path, then device ID;
  - missing rows remain listed;
  - anonymous rows expose a blocked reason.

- [ ] Write mutation tests first for:

  - `agent:manage` is required and read-only access receives 403;
  - `false` always moves `osd` to `unassigned`, including missing/stale/offline/in-use devices;
  - `true` returns 409 for missing identity, missing device, `inUse`, `draining`, `faulted`, offline agent, or `lastSeenAt` older than 60 seconds;
  - `true` succeeds for a present, fresh, available, identified device on an online agent;
  - repeating the already-selected role succeeds idempotently;
  - a concurrent observation update cannot cause enablement against stale pre-lock facts;
  - an unknown request field is rejected by validated-body decoding.

- [ ] Run `cd control-plane && swift test --filter StorageDeviceControllerTests`; expect failure because the route does not exist.
- [ ] Extract the current private agent-node authorization logic into:

```swift
extension Request {
    func requireAgentAction(_ action: String, on agent: Agent) async throws
}
```

  Preserve the existing scopeless-agent system-admin behavior and error semantics. Replace all private helper call sites in `AgentController` and run its authorization tests before adding new behavior.
- [ ] Define API content types in `StorageDeviceController.swift`: `StorageDeviceResponse`, `UpdateStorageDeviceRequest: Content, ValidatedRequestBody`, and the blocked-reason enum/string representation documented in OpenAPI.
- [ ] Centralize eligibility computation in one pure function shared by list serialization and mutation. Evaluate blockers in this stable order: identity, presence, observed state, agent online status, freshness. Return `canMarkOsdEligible=true` only when none apply. An already-selected device exposes `osdEligible=true` even when current conditions would prevent new selection.
- [ ] Implement list by starting from `AgentController.visibleAgents(req:)`, applying optional parent filters without bypassing visibility, querying their devices, sorting deterministically by site name, agent name, presence, path, and row ID, then applying `ListPaging` after authorization. Expose agent and site IDs in each row; the web client resolves their display names from its existing agent/site queries.
- [ ] Implement patch inside a database transaction: lock the device row, reload its parent agent, authorize `agent:manage`, and reload/evaluate current facts. When `osdEligible=false`, set `role=unassigned`. When true and role is not already OSD, enforce the guard and set `role=osd`; return 409 with the same blocked reason used by GET when refused.
- [ ] Register `StorageDeviceController()` in `routes.swift`.
- [ ] Document the list filters, page envelope, all response fields, eligibility patch body, 403, 404, 409, and enum values in `openapi.yaml`.
- [ ] Run `cd control-plane/web && bun run generate:api-types`; inspect that only `src/types/openapi.ts` changes and that the generated request/response shapes match the Swift content types.
- [ ] Run `cd control-plane && swift test --filter StorageDeviceControllerTests` and the existing `AgentController` authorization-focused tests; expect them to pass.
- [ ] Run `cd control-plane && swift test --filter ValidatedRequestBodyCoverageTests`; expect the new request body to be covered.
- [ ] Commit with `git add control-plane/Sources/App/IAM/AgentAuthorization.swift control-plane/Sources/App/Controllers/AgentController.swift control-plane/Sources/App/Controllers/StorageDeviceController.swift control-plane/Sources/App/routes.swift control-plane/Sources/App/openapi.yaml control-plane/Tests/AppPlatformTests/StorageDeviceControllerTests.swift control-plane/Tests/AppPlatformTests/ValidatedRequestBodyCoverageTests.swift control-plane/web/src/types/openapi.ts && git commit -m "Expose storage device eligibility API"`.

## Task 7: Add the Web Data Layer and View Model

**Files:**

- Modify: `control-plane/web/src/types/api.ts`
- Create: `control-plane/web/src/lib/api/storage-devices.ts`
- Create: `control-plane/web/src/lib/hooks/use-storage-devices.ts`
- Modify: `control-plane/web/src/lib/hooks/index.ts`
- Create: `control-plane/web/src/components/storage-devices/storage-device-model.ts`
- Create: `control-plane/web/src/components/storage-devices/storage-device-model.test.ts`

**Interfaces:**

- Consumes the generated OpenAPI contract and shared API client/pagination helpers.
- Produces TanStack Query list/mutation hooks and pure grouping/formatting behavior for the page.

- [ ] Add pure model tests first for grouping devices by site and agent, stable sorting, missing status, byte formatting, use-label formatting, and selection confirmation text.
- [ ] Run `cd control-plane/web && bun run test -- src/components/storage-devices/storage-device-model.test.ts`; expect failure because the model does not exist.
- [ ] Add manual application-facing types matching the OpenAPI schema: identity kind/value, role, state, uses, presence, timestamps, agent/site IDs, `osdEligible`, `canMarkOsdEligible`, and `osdEligibilityBlockedReason`. Agent and site display names come from the existing agent/site hooks rather than the storage response.
- [ ] Implement `storageDevicesApi.list(filters, signal)` with `listAllPages`, translating camel-case client filters to `organization_id`, `site_id`, and `agent_id`. Implement `setOsdEligibility(deviceId, osdEligible)` as PATCH.
- [ ] Implement query keys containing organization/site/agent filter values. The mutation must invalidate all storage-device list keys on success and preserve the server's 409 reason for UI display.
- [ ] Implement pure grouping helpers that never infer eligibility client-side. The server-provided booleans and blocked reason are authoritative.
- [ ] Run `cd control-plane/web && bun run test -- src/components/storage-devices/storage-device-model.test.ts`; expect all focused tests to pass.
- [ ] Run `cd control-plane/web && bun run lint`; fix only issues introduced by this task.
- [ ] Commit with `git add control-plane/web/src/types/api.ts control-plane/web/src/lib/api/storage-devices.ts control-plane/web/src/lib/hooks/use-storage-devices.ts control-plane/web/src/lib/hooks/index.ts control-plane/web/src/components/storage-devices/storage-device-model.ts control-plane/web/src/components/storage-devices/storage-device-model.test.ts && git commit -m "Add storage inventory web data model"`.

## Task 8: Build the Storage Devices Operator Page

**Files:**

- Create: `control-plane/web/src/components/ui/switch.tsx`
- Create: `control-plane/web/src/components/storage-devices/storage-device-inventory.tsx`
- Create: `control-plane/web/src/components/storage-devices/storage-device-inventory.test.tsx`
- Create: `control-plane/web/src/app/(dashboard)/storage/devices/page.tsx`
- Modify: `control-plane/web/src/components/layout/nav.ts`
- Modify: `control-plane/web/src/components/layout/nav.test.ts`

**Interfaces:**

- Consumes sites, agents, permissions, and storage-device hooks.
- Produces `/storage/devices`, grouped inventory, a site filter, and the only operator control in this phase: OSD eligibility.

- [ ] Write component tests first to prove:

  - all devices render grouped under site then agent;
  - site filtering hides other sites without changing query authorization;
  - path, size, model, serial/WWN, rotational type, uses, state, last seen, and missing status render;
  - a safe unselected device shows an enabled off switch;
  - enabling opens a confirmation dialog stating future OSD orchestration may erase the disk and that this action does not format it now;
  - confirming calls the mutation once with true;
  - blocked unselected devices show disabled controls and the server reason;
  - selected but now unsafe devices retain an enabled on switch so the operator can disable them without confirmation;
  - disabling calls the mutation with false directly;
  - users without `agent:manage` see the state but cannot mutate it;
  - loading, empty, fetch-error, mutation-error, and 409 refusal states are accessible and visible.

- [ ] Add a navigation test expecting `Storage > Devices` at `/storage/devices` and correct page-title/active-section behavior.
- [ ] Run `cd control-plane/web && bun run test -- src/components/storage-devices/storage-device-inventory.test.tsx src/components/layout/nav.test.ts`; expect failures because the component and nav entry do not exist.
- [ ] Build an accessible reusable switch with a native button, `role="switch"`, `aria-checked`, visible focus state, disabled styling, and no hidden mutation behavior.
- [ ] Build the page using existing layout, card, table, select, badge, dialog, skeleton, and toast conventions. Use `usePermissions` checks keyed by agent ID with `action: "agent:manage"` and node type `agent`; fail closed while those permissions load.
- [ ] Group rows by site then agent. Keep disappeared devices in their group with a prominent `Missing` badge and retained path as last-reported display data.
- [ ] Use the confirmation dialog only for false-to-true transitions. Copy must say: `Future Ceph OSD provisioning may erase all data on this disk. This selection does not format or modify the disk now.`
- [ ] Add the dashboard page as a client page that reads current organization, sites, and agents, owns the optional site filter, and passes resolved names to the inventory component.
- [ ] Add `Devices` under the existing Storage navigation group with the `HardDrive` icon.
- [ ] Run the focused component and nav tests; expect them to pass.
- [ ] Run `cd control-plane/web && bun run test`, `cd control-plane/web && bun run lint`, and `cd control-plane/web && bun run build`; expect all frontend checks to pass.
- [ ] Commit with `git add control-plane/web/src/components/ui/switch.tsx control-plane/web/src/components/storage-devices/storage-device-inventory.tsx control-plane/web/src/components/storage-devices/storage-device-inventory.test.tsx 'control-plane/web/src/app/(dashboard)/storage/devices/page.tsx' control-plane/web/src/components/layout/nav.ts control-plane/web/src/components/layout/nav.test.ts && git commit -m "Add storage device inventory page"`.

## Task 9: Prove the Acceptance Path and Run Full Verification

**Files:**

- Modify tests only if an uncovered acceptance assertion is needed; do not add production behavior in this task.
- Verify: all files changed since the plan baseline.

**Interfaces:**

- Consumes all prior tasks.
- Produces evidence that stable identity survives path renumbering and that local/in-use/anonymous/missing disks cannot be newly selected.

- [ ] Add or consolidate one acceptance-level control-plane test that executes this sequence through report reconciliation and the API: report WWN `5000cca1` at `/dev/sdb`, enable OSD eligibility, report the same WWN at `/dev/sdc`, list devices, and assert one row remains with the same ID, `osdEligible=true`, and updated display path.
- [ ] In the same test suite, cover local/in-use, anonymous, stale, offline, and disappeared rows as refused enablement cases, then prove an already-selected disappeared row can be disabled.
- [ ] Run focused verification:

```sh
cd shared && swift test
cd agent && swift test
cd control-plane && swift test --filter StorageDevice
cd control-plane/web && bun run test -- src/components/storage-devices src/components/layout/nav.test.ts
```

- [ ] Run package/application verification:

```sh
cd control-plane && swift test
cd control-plane/web && bun run test
cd control-plane/web && bun run lint
cd control-plane/web && bun run build
```

- [ ] Inspect `git diff --check` and fix whitespace errors.
- [ ] Inspect `git diff 830b17e --stat` and `git diff 830b17e --name-status`; confirm every changed production file maps to a responsibility in this plan and no unrelated user changes were overwritten.
- [ ] Search changed files for unfinished implementation markers with `git diff 830b17e --name-only -z | xargs -0 rg -n "TODO|FIXME|placeholder|fatalError\(\"not implemented"`; confirm no new unfinished path remains.
- [ ] Search changed files for path-keyed identity or destructive actions with `git diff 830b17e --name-only -z | xargs -0 rg -n "devicePath.*identity|/dev/sd|mkfs|ceph-volume|wipefs"`; inspect every match and remove any durable path identity or disk mutation.
- [ ] Confirm protocol types, persisted enum raw values, OpenAPI enums, generated TypeScript, and manual TypeScript use the same casing.
- [ ] Confirm the migration is registered once, routes are registered once, nil observations make no persistence call, empty observations mark missing, and device reconciliation errors cannot skip workload reconciliation.
- [ ] Review every OSD-enable path for the five hard gates and transaction locking; review every OSD-disable path to ensure it remains available.
- [ ] Commit any test-only acceptance refinements with `git add <exact test files> && git commit -m "Verify storage inventory acceptance path"`. Skip this commit when the preceding commits already contain the complete evidence.
- [ ] Record exact verification results in the handoff. If a platform-specific suite cannot run locally, state which suite was not run and why; do not describe it as passing.
