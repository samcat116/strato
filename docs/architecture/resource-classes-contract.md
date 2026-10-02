# Workload resource classes: STR267 / STR272 contract proposal

Status: proposal awaiting parent coordination on wire v67. No capability may be
advertised and no burstable workload may be admitted until STR272 has complete
runtime enforcement and effective readback for the selected backend.

STR267 is stacked on STR265 PR1444, exact head
`be5c7f10b2bddc290bd4841c80cb0152ee91d24f`. Issues #1246 and #1251 govern the
control-plane and runtime halves. Wire v64 is GuestConfig, v65 is host density,
and v66 is headroom; propose v67 for the coordinated resource-class schema.
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
and memory-high percent 80. Ratio bounds above are proposed and await parent
agreement; apply the settled values consistently to API, clients, persistence,
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

This proposal changes no executable schema and leaves wire v66 unchanged.

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
  accounting; it currently uses integer CPU reservations and requires the
  coordinated fractional-capacity update.
- `control-plane/Sources/App/Services/SchedulerService.swift` owns candidate
  requirements and ratio-aware physical reservation diagnostics.
- `control-plane/Sources/App/Services/WorkloadPlacementService.swift` builds
  fleet candidates from already-net resource reports and claims placement.
- `control-plane/Sources/App/Services/CoordinationService.swift` must preserve
  fractional CPU commitments and atomic reservation behavior.
- `control-plane/Sources/App/Services/DesiredStateAssembler.swift` must read
  persisted admitted snapshots instead of repricing from the mutable catalog.
