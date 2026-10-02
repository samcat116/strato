# Workload resource classes: STR267 / STR272 contract

Status: shared wire v67 and ratio bounds accepted by parent; gated model implemented. No capability may be
advertised and no burstable workload may be admitted until STR272 has complete
runtime enforcement and effective readback for the selected backend.

STR267 is stacked on STR265 PR1444, exact head
`be5c7f10b2bddc290bd4841c80cb0152ee91d24f`. Issues #1246 and #1251 govern the
control-plane and runtime halves. Wire v64 is GuestConfig, v65 is host density,
and v66 is headroom; v67 is the coordinated resource-class schema.
Do not independently allocate another version for STR272 fields while both
changes remain unmerged. Exact-version agent/control-plane registration remains
mandatory.

## Canonical snapshot

The canonical resource-class snapshot belongs on `VMSpec.resourceClass` and
`SandboxSpec.resourceClass`, so creation, desired-state replay, manifest
serialization, restart, and adoption consume one policy. Snapshot fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `classID` | UUID | Site-scoped persisted class identity |
| `siteID` | UUID | Placement must match this site |
| `revision` | Int64, positive | Policy revision admitted for this workload |
| `kind` | guaranteed / burstable | Strict enum; unknown values fail decoding |
| `cpuAllocationRatio` | finite number 1...64 | Requested vCPU / physical CPU commitment |
| `memoryAllocationRatio` | finite number 1...16 | Guest placement commitment / physical guest commitment |
| `cpuWeight` | integer 1...10000 | cgroup v2 fair share, never CPU quota |
| `memoryHighPercent` | integer | Guaranteed 100; burstable 1...99 |
| `hardLimitPolicy` | guestAndBackend | Current guest grant plus backend overhead |

The guaranteed class is the immutable site default: both ratios 1, weight 100,
memory-high percent 100. Missing references in old database rows, request bodies,
and manifests resolve to this behavior. They do not imply burstable, and must
not cause a runtime policy rewrite during adoption. Unknown, corrupt, cross-site,
or unsupported explicit references fail closed rather than becoming guaranteed.
Proposed initial burstable defaults are CPU ratio 4, memory ratio 1, weight 100,
and memory-high percent 80. Ratio bounds above are accepted policy ceilings, not safe overcommit recommendations;
apply the values consistently to API, clients, persistence,
and wire decoding before accepting configurable policies.

## Runtime limits and arithmetic

For burstable workloads let `G` be **current granted guest memory bytes**, `O`
be backend process allowance, and `P` be `memoryHighPercent`:

```
memory.max  = G + O
memory.high = floor(G * P / 100) + O
cpu.weight  = cpuWeight
```

Use quotient/remainder integer arithmetic to avoid overflowing `G * P`.
Reject nonpositive grants and overflow in runtime limits; require
`0 < memory.high < memory.max`. Percentage uses guest grant as its denominator;
backend overhead is added afterward and is never discounted. It does not use
`maxMemoryBytes`, balloon targets, ratio-discounted reservation, host reserve,
or host physical memory. Guaranteed follows its existing runtime path.

QEMU's placement memory operand is the realized architecture-aligned hotplug
guest commitment from `WorkloadMemoryReservation`, which can exceed current
grant. That operand is distinct from the runtime process ceiling above.
Libvirt must own QEMU memtune/cputune configuration and effective readback.
Firecracker uses its jailer-owned cgroup and applies limits before execution.
An ordinary unjailed Firecracker VM cannot enforce this contract and rejects
burstable. No shared-tier `cpu.max`, quotas, or CPU pinning.

## Placement, admission, and persistence

Physical CPU commitment is requested vCPU divided by the admitted CPU ratio;
retain fractional precision (four 1-vCPU grants at 4:1 consume one physical
unit). Proposed capacity storage is nonnegative Int64 CPU micro-units, rounded
up per admission; one physical CPU equals 1,000,000 units. Both inventory and
coordination claims must use the same unit rather than rounding each workload
up to an integer CPU. Physical memory commitment is ceiling of guest placement commitment
divided by memory ratio, plus undiscounted backend overhead. Saturate placement
arithmetic toward full capacity, never toward more free capacity.

`HostMemoryAccounting.remainingAllocatableBytes` is already net of host reserve
and inventory workload commitments. Subtract only outstanding coordination
claims; do not subtract host reserve or backend overhead again. Mixed guaranteed
and burstable inventory must sum each workload's persisted admitted commitment.
Provisional identity-based claims and partially observed growth retain PR1444's
single-counting invariant.

Class edits update the catalog revision only. Do not assemble the newest catalog
policy onto all existing desired specs, increment existing workload generations,
restart, migrate, reclaim grants, or recompute their old reservations. New
placement resolves the current revision. Positive growth retains the existing
commitment and admits only the increase under the current revision. Persist
both the runtime snapshot and admitted aggregate commitment so mixed-revision
growth is reproducible after restart; do not reprice the old allocation.
Runtime policy changes for an explicitly accepted workload mutation participate
in its generation and manifest persistence. Applying a new percentage or weight
to old grants solely because the catalog changed is forbidden.

Backend capability requires validated controller delegation, an owned workload
cgroup, complete pre-execution enforcement, and effective readback. Listing root
controllers is insufficient. Class management may exist before runtime support,
but assignment, placement, start, restore, and growth must refuse burstable
until all required enforcement exists. No unconditional capability flag.

Pressure/contention gates use explicitly available CPU and memory PSI samples
from #1245, configured thresholds and freshness. Missing or stale required
signals refuse additional burstable commitment with an actionable reason.
Guaranteed retains existing capacity safety behavior. Gate new placement and
positive growth, not unchanged existing grants. Placement diagnostics expose
class identity/revision, effective reservation operands, and the exact refusal.

## Required verification before the implementation PR

- Missing reference preserves unchanged guaranteed scheduling and manifests.
- Four 1-vCPU burstable grants at 4:1 consume one physical CPU unit.
- Backend overhead is not ratio-discounted or double-subtracted.
- Catalog edits preserve old grants, generations, and admitted commitments;
  positive growth charges only its new portion, including mixed revisions.
- Invalid fields, unknown kinds, cross-site references, unsupported backends,
  incomplete capabilities, and missing/stale pressure signals fail closed.
- Restart/adoption preserve runtime snapshot and admitted accounting.
- Both backends verify effective runtime controls before capability activation;
  unjailed Firecracker VMs remain ineligible for burstable.
- API/generated clients/CLI/UI, schema migrations, manifests, wire round trips,
  scheduler concurrency, and host-local admission cover the same contract.

The executable shared schema uses wire v67. Both specs additionally persist
`admittedReservation: WorkloadAdmittedReservation?` with `grantedCPUs`,
`guestCommitmentBytes`, `cpuMicroUnits`, `discountedGuestBytes`, and
`backendOverheadBytes`; nil denotes the unchanged historical 1:1 path.

`WorkloadResourceClassSnapshot.policy` is the Swift accessor for policy fields;
JSON flattens the policy fields alongside class/site/revision. Admission gate
fields are `maxCPUPressure10` (default 10), `maxMemoryPressure10` (default 5),
and `maxTelemetryAgeSeconds` (default 60, range 15...300). Missing or malformed
explicit fields fail decoding. Built-in class IDs are UUIDs ending in 0001
(guaranteed) and 0002 (burstable), scoped by siteID.

Normalize to the host's base page size `S` before either backend applies
limits: `alignedHigh = floor(rawHigh / S) * S` and
`alignedMax = ceil(rawMax / S) * S`. Checked arithmetic rejects overflow and
requires `0 < alignedHigh < alignedMax`. For example, raw 9900/10000 becomes
8192/12288 with S=4096. Shared `WorkloadRuntimeLimits.aligned(pageSizeBytes:)`
implements this contract. Libvirt uses aligned targets divided by 1024;
the jailer uses aligned bytes. Telemetry retains raw intent and applied
page-aligned values; readback compares aligned targets. This avoids collapse
when the [kernel parser](https://raw.githubusercontent.com/torvalds/linux/master/mm/page_counter.c)
divides limits by PAGE_SIZE.

Registration's optional `resourceClassEnforcement` array has entries with
`backend` (`qemuVM` or `jailedFirecrackerSandbox`), `controllersDelegated`,
`stableOwnership`, `preExecutionEnforcement`, and `effectiveReadback`.
`supportsBurstable` requires all four booleans. Nil/empty is unsupported.
This branch sends none and retains unconditional burstable refusal until the
complete STR272 runtime is integrated and validated. Listing root controllers
or setting one backend flag cannot enable placement.

## Exact source integration points

- `shared/Sources/StratoShared/WorkloadMemoryReservation.swift` owns the
  undiscounted guest/backend/effective operands and already-net host accounting.
- `shared/Sources/StratoShared/VMSpec.swift` and `SandboxModels.swift` own
  canonical specs. `ReconciliationProtocol.swift` carries those specs without
  a second parallel resource-class field.
- `agent/Sources/StratoAgentCore/VMManifestStore.swift` owns durable workload
  specs and QEMU's realized hotplug reservation.
- `agent/Sources/StratoAgentCore/HostCapacityAdmission.swift` owns host claims,
  positive deltas, identity-based provisional de-duplication, and manifest
  accounting; it uses CPU micro-unit reservations and retains the coordinated
  fractional-capacity accounting.
- `control-plane/Sources/App/Services/SchedulerService.swift` owns candidate
  requirements and ratio-aware physical reservation diagnostics.
- `control-plane/Sources/App/Services/WorkloadPlacementService.swift` builds
  fleet candidates from already-net resource reports and claims placement.
- `control-plane/Sources/App/Services/CoordinationService.swift` must preserve
  fractional CPU commitments and atomic reservation behavior.
- `control-plane/Sources/App/Services/DesiredStateAssembler.swift` must read
  persisted admitted snapshots instead of repricing from the mutable catalog.

## Gated implementation and activation boundary

The site API exposes immutable guaranteed and configurable burstable catalog
entries through the existing site permissions. Class references in VM/sandbox
creation are site-scoped and checked against the project's root organization.
`strato resource-class list/configure --site <UUID>` uses this catalog; creation
commands accept `--resource-class-site` and `--resource-class-id` together. The
UI exposes catalog configuration and guaranteed selection, and disables
burstable selection. Both detail views expose the admitted class revision.

Migration columns are optional, with no workload backfill or repricing. API
assignment, scheduler placement, positive VM growth, and agent realization each
refuse burstable. The class snapshot and aggregate ledger round-trip through
models, canonical specs, and manifests. No enabled path admits a discounted
commitment. Placement holds the workload row lock and a shared site catalog lock through
selection and persistence of owner, snapshot and admitted ledger. Repeating a
committed placement preserves its owner and pricing. Growth plans from the
freshly locked row and preserves the old aggregate's pricing; sizing, snapshot,
ledger, quota and desired generation commit in one transaction. A burstable
row missing its ledger cannot infer historical pricing. Lifecycle and metadata
saves refresh the admitted state so stale models cannot overwrite it.
Guaranteed uses its existing host physical-footprint path even when a ledger
is present, and historical nil rows remain unchanged.
This draft does not claim that runtime activation or full #1246 acceptance
criteria are complete. STR272 remains the activation dependency.

## Remaining activation evidence

`hostRefusal` requires exactly one complete enforcement record for the selected
backend and site, plus fresh CPU/memory PSI measured by control-plane receipt
time. Repeated identical samples retain their prior receipt time. The host
readiness predicate is necessary evidence; helper tests do not prove kernel
enforcement or a workload's applied limits. The runtime owner must specify
backend evidence lifetime/invalidation and its generation-guarded workload
application/readback contract before activation.

Generation-specific growth claims use
`<workload UUID>:growth:<generation>:<mutation UUID>`, so a retry within an
attempt replaces its own claim. Mutation identity protects another writer
when an aborted transaction's next generation is reused. The delta is the positive increase over the persisted
admitted aggregate. The producer reserves the positive delta inside the locked mutation before
committing sizing, snapshot, ledger, quota and generation. Rollback cleanup
only targets its mutation-owned claim; uncertain commit outcomes retain it.
This producer is behind the unchanged burstable gate.

### Agreed coherent acknowledgement (wire67)

`ObservedStateReport.resourceEnforcement` is optional. Its
`ResourceEnforcementSnapshot` carries `agentBootID: UUID`, `sequence: Int64`,
`sampledAt: Date`, `inventoryComplete: Bool` and
`acknowledgements: [WorkloadEnforcementAcknowledgement]`. Each acknowledgement
carries `kind`, `workloadId`, `appliedGeneration`, canonical `resourceClass`,
`backend`, canonical `accountedReservation`, `runtimeGuestBytes`,
`pageSizeBytes`, canonical `desiredLimits`/`appliedLimits`,
`cpuQuotaUnlimited` and `ownershipVerified`. Shared commit
`e109ffe88d2586a968beac839a1a09265038d7b6` publishes these exact names.

The producer must capture reservation inventory, acknowledgements and the SAME
report's net resources from a versioned snapshot. Recheck ownership/generation/
ledger after asynchronous backend reads; retry or omit an acknowledgement on
mutation. Each certified ledger debits net resources exactly once. Applied
generation means successful guarded backend convergence, not a manifest target
or matching controller-file samples. Desired limits describe that applied
snapshot and actual grant; applied limits equal canonical page normalization.
The observed workload must be uniquely present, running, at that generation,
with neither convergence in progress nor a same-generation failure.

PostgreSQL `agent_resource_admissions` stores ordered report state and pending
mutation commitments. Growth adds its positive charge in the sizing/quota/
generation transaction, serialized on the agent row. Placement and subsequent
growth subtract pending charges from the last coherent net report (legacy
agents retain their normal reported resources). Charges have no TTL: Valkey
expiry/restart, CP outages and uncertain commit results never expose them as
free. Conservative double charging while a coordination key remains is safe.
Rollback removes the staged durable change along with the mutation.

The existing authenticated inventory-session fence binds report and heartbeat
processing to the current connection across replicas. The durable cursor
accepts strictly increasing nonnegative sequences; a different boot ID is
permitted only across a session transition. Rotation and revocation atomically
invalidate predecessor capacity while preserving durable pending charges; a
fresh coherent report is required before placement resumes. Restart must
invalidate producer acknowledgements until fresh adoption/readback. Once coherent reporting is
established, heartbeat resource fields cannot overwrite it. Agent wall-clock
`sampledAt` is diagnostic, never a replacement for receiver freshness time.

The consumer requires complete inventory, unique acknowledgements, internally
consistent host memory accounting, precise CPU units, and acknowledged totals
within the report's debited totals. Incomplete or inconsistent accounting zeros
the effective placement capacity until a fresh valid report. It validates owner/site/backend readiness,
current class snapshot, current committed generation and exact ledger, actual
guest grant, canonical limits, verified ownership and unlimited CPU quota.
Persisting net resources and removing proven covered durable claims is one
transaction; exact coordination keys are released only after commit. A failed
release leaves conservative double charging. Sequence rejection precedes any
resource or claim changes.

A newer generation covers earlier claims only through a stored monotonic
ledger chain: every subsequent claim's previous ledger must equal its
predecessor's admitted ledger, ending in the exact acknowledged current
ledger/snapshot. Missing links, forks, mismatches and newer pending generations
retain charges. No prefix deletion or ordinary observed workload-ID release
can remove these mutation-owned keys. Missing/unknown/failed/incomplete evidence
retains commitments. Terminal cleanup requires separate proof of absence or
rollback; it is not a successful-enforcement acknowledgement.

STR267 owns canonical DTOs and CP consumption; STR272 owns coherent production
and runtime acknowledgement; STR266 owns detailed desired/applied telemetry.
Production activation remains disabled pending stable QEMU ownership, complete
backend enforcement evidence and actual kernel acceptance. The coordinator
owns integration and eventual activation.

Independent database regressions cover concurrent mixed-revision growth,
rollback of snapshot/ledger/sizing/generation, catalog lock serialization,
unchanged/shrinking grants, a missing historical ledger, and concurrent
sandbox placement with a single retained owner/claim. These are transaction
proofs rather than evidence of runtime enforcement.

### Integration review of STR272 producer

Producer `3a63040f3376c3ebb999ca4fcdc333a0285789fb` uses the canonical
wire67 fields, generation-bound success records, current backend evidence,
versioned identity/accounting fences and explicit incomplete snapshots.
Accounting checks are compatible with its fractional CPU and host-memory
projection. Consumer transaction-failure tests prove that rejected persistence
retains durable and coordination commitments.

Socket registration provenance now supplies boot-binding authority without an
additional wire field. Each authenticated socket receives a locally generated
immutable inventory-session UUID. Registration is awaited by the serial frame
handler and persists that exact token. Report and heartbeat dispatch retain the
socket token through deferred tasks rather than looking up a successor's token
by shared identity. Actor and PostgreSQL ownership checks reject stale tokens.
Network registration captures its predecessor session at the first database
read; comparison under the inventory fence rejects a late completion if another
replica has changed that session. This prevents an in-flight predecessor
registration from replacing a successor's binding. A socket already registered
on an older replica cannot re-register over a different current SQL session.
A successor drains predecessor registration before activating; a superseded
socket cannot start registration. Existing revocation/EOF cleanup remains
unchanged, and #1448's administrative holds/save guards must be preserved by
coordinator integration.

The first coherent report from the correctly fenced session establishes boot
identity. Same-boot reconnects preserve the sequence cursor and remain invalid
until a higher coherent sequence arrives. Restart permits a new boot/sequence
space only in the successor session; no acknowledgement is emitted before
fresh adoption/readback. The deterministic S1/B1/101 regression delays enqueue
until after S2 registers: it cannot restore predecessor capacity, release
pending charges or poison S2's boot binding. A stale S1 heartbeat is rejected
as well. STR272 producer correction `8ab18dda` now filters running, error-free and
phase-free observed entries consistently with the consumer. The receipt-time
provenance correction adds no shared fields. Activation remains disabled.
