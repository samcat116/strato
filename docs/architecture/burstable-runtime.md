# Burstable runtime enforcement foundations (STR-272)

These helpers consume the executable
[STR-267 class contract](./resource-classes-contract.md) at checkpoint
`d926f182ab59a158e2ce92a4cd0c3cedcabf330f`. They are not yet wired to workload
lifecycle execution. No burstable capability is advertised or placement enabled
by this change. Guaranteed workloads retain their existing runtime path. The
canonical class snapshot and wire v67 belong to the coordinated STR-267
implementation, not an additional DTO here.

`BurstableResourceLimits` in StratoAgentKit wraps canonical `WorkloadRuntimeLimits`
and delegates byte arithmetic to `WorkloadResourceClassPolicy.runtimeLimits` and
page alignment to `WorkloadRuntimeLimits.aligned(pageSizeBytes:)`.
Its `plan` adapter consumes the persisted admitted snapshot and returns nil for
missing/guaranteed snapshots, preserving the existing runtime path. The shared
policy owns percentage/weight validation, checked quotient/remainder arithmetic,
and runtime overflow refusal. Backend allowance is never percentage-discounted:

```
memory.high = floor(current guest grant * percentage / 100) + backend allowance
memory.max  = current guest grant + backend allowance
cpu.weight  = admitted class weight
```

Placement's architecture-aligned QEMU hotplug commitment is a different
operand. Host reserve, remaining allocatable memory, placement ratios, and
balloon targets do not enter these runtime limits. The hard-ceiling contract
remains STR-265's current guest grant plus backend allowance.

Jailer entries put `memory.high` before `memory.max`, followed by `cpu.weight`.
They deliberately contain no `cpu.max` quota. Their caller must use the existing
jailer ownership helper and install the plan before Firecracker execution.
Ordinary Firecracker VMs currently run unjailed and cannot be admitted as
burstable without a new fully enforced ownership boundary.

`DomainBurstableTuning` in StratoAgentDomainXML plans libvirt `memtune` hard and
soft limits and `cputune` shares. It preserves unrelated XML, normalizes the
managed limit elements, and returns nil when no rewrite is required. Duplicate
tuning containers, invalid roots/text, and positive or malformed thread-group
quotas refuse the rewrite; a shared workload must not silently inherit a CPU
quota. This helper does not write cgroup files.

Libvirt's cgroup-v2 backend maps soft limits to `memory.high` and shares to
`cpu.weight` (or systemd CPUWeight); see the
[libvirt implementation](https://raw.githubusercontent.com/libvirt/libvirt/master/src/util/vircgroupv2.c)
and [CPU tuning documentation](https://libvirt.org/formatdomain.html#cpu-tuning).
Libvirt memory parameters use KiB, but kernel controls are page-granular. KiB-only
rounding can collapse the pressure interval after kernel quantization. Callers
must supply the actual enforcement host's page size; it is never assumed to be
4096. The plan rounds high down to that page size and max up to it, checks for
overflow, and requires `0 < effective high < effective max`. Both libvirt's KiB
arguments and jailer byte arguments represent these same aligned targets
exactly. The shift in each direction is less than one page. A threshold too
small to represent refuses enforcement. Desired raw bytes and effective
page-aligned bytes remain distinct. This alignment contract is agreed with STR-267 and lives in its shared model;
the guaranteed ceiling path remains unchanged.

The [kernel page-counter implementation](https://raw.githubusercontent.com/torvalds/linux/master/mm/page_counter.c)
parses memory limits in pages; [kernel documentation](https://docs.kernel.org/admin-guide/cgroup-v2.html#memory-interface-files)
also warns about page-size quantization. Readback must check the actual aligned
values and fail closed if a backend/kernel does not realize them.

The read-only `scripts/check-burstable-cgroup.py` scaffold checks effective files
at an explicitly supplied owned cgroup path against expected values and captures
memory events, memory/CPU PSI, and CPU statistics. It does not establish
ownership, ancestor restrictions, delegation, lifecycle application, reclaim,
OOM containment, CPU fairness, or transient-limit safety by itself.

Remaining integration requires backend-supported pre-execution/live control application, stable lifecycle
ownership, effective readback, complete capability gating, and coordinated
telemetry. Controller listing or unit-test fixtures alone never enable support.
Actual QEMU and jailed Firecracker kernel tests must verify create/restart/adopt,
pressure survival, workload-local containment, and CPU fairness/idle use before
claiming runtime acceptance.

## Lifecycle hook design pending canonical class integration

| Path | Required integration | Failure behavior |
| --- | --- | --- |
| Create | Resolve the persisted admitted snapshot; validate complete backend support; define libvirt controls or pass the jailer plan before execution. | Refuse burstable before spawning when any required control is unavailable. |
| Boot/restart | Converge persistent QEMU controls in the required pre-boot hook immediately before `bootVM`; Firecracker respawn uses the persisted jailer plan and ownership identity. | A failed required rewrite blocks boot at the same generation. Never fall back to unlimited controls. |
| Adoption | Use the persisted admitted snapshot and actual guest grant; validate owned membership; converge supported live/config controls and read back before reporting enforcement. | Keep the existing workload and grant; report unknown/degraded enforcement and refuse new burstable commitment. Do not relabel the agent/shared cgroup as workload-owned. |
| Positive memory growth | Keep the old pressure threshold while safely widening containment, update the pressure threshold, then grow the guest. Existing controls remain active throughout. | Preserve the previous applied echo until backend acknowledgement; report failure against the current generation. |
| Memory shrink | Reduce the guest grant first, then converge lower pressure/containment targets through backend controls. | Do not lower containment under the old guest grant. |
| Delete | Stop the owning backend process before removing its exact owned cgroup; preserve other workloads' boundaries. | Cleanup failure must not authorize touching unowned parents or descendants. |
| Catalog edit | No runtime call for an unchanged admitted snapshot. | Existing grants and limits remain intact. |

`BurstableRuntimeGate` consumes the canonical four-part enforcement metadata.
All four requirements must be true; nil or partial metadata blocks burstable
work with a retryable blocked convergence error. Runtime create/adopt/resize and
QEMU required pre-boot convergence refuse burstable specs before backend or
storage work. Sandbox create/adopt/boot/restore apply the same refusal. These
backends currently supply no complete evidence, so support remains disabled.
Missing and guaranteed snapshots continue through existing paths. Delete is
not gated, so refusal never prevents cleanup of an existing workload.

`BurstableCgroupReadback` samples only the explicit boundary supplied by a
backend ownership authority. It rejects the hierarchy root, traversal and
noncanonical paths, validates finite aligned memory controls, the class weight
and unlimited `cpu.max`. Missing or malformed values never acknowledge applied
limits. This sampler does not establish ownership, ancestor behavior or write
controls and is not yet wired to wire telemetry.

The control plans are not connected to backend application. Stable QEMU
ownership, safe live transition order, pre-execution restore and desired/applied
wire telemetry remain implementation blockers; enabling only some of them
would violate the canonical support gate. Unit planning tests establish
arithmetic, persisted XML idempotence and conflict refusal; they do not establish
actual application order, owned kernel paths, adoption safety or cleanup.
