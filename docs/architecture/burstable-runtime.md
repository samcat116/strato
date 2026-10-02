# Burstable runtime enforcement (STR-272)

These helpers consume the executable
[STR-267 class contract](./resource-classes-contract.md) at checkpoint
`ea7763845b17df11c09d11fc9fb10ce71f264451` (draft PR #1455). They are wired to guarded workload lifecycle execution. No burstable capability is advertised or placement enabled
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

Production factories still supply no complete enforcement evidence. The guarded paths are implemented, but capability activation requires a supported stable QEMU ownership arrangement and real backend/kernel acceptance. Fixture controller files establish deterministic decisions, not actual kernel enforcement.

## Guarded lifecycle implementation

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

QEMU persistent XML stores the canonical admitted snapshot and last acknowledged guest grant. Boot and checkpoint restore start paused, verify the owned controller root, then resume. Live growth widens containment, sets pressure/weight and verifies before growing the guest; shrink changes the guest first. Retry recognizes only known old/target finite phase values, then requires exact target acknowledgement. Adoption validates identity and existing effective controls without destroying an unknown workload. A per-domain operation guard prevents overlapping control transitions.

QEMU ownership requires a trusted backend-supplied stable controller-root path, domain UUID/PID-file identity, unchanged process incarnation, bounded emulator membership, and controller-root process membership. It never searches arbitrary descendants or writes cgroup files. The default path provider is nil. Libvirt's resource partition provides a parent, while its machine scope includes the runtime domain identifier; a UUID-shaped guessed scope therefore does not establish stable physical ownership. An approved supported host/backend arrangement must supply this boundary before activation. See [libvirt machine cgroup setup](https://github.com/libvirt/libvirt/blob/master/src/hypervisor/domain_cgroup.c) and [QEMU machine naming](https://github.com/libvirt/libvirt/blob/master/src/qemu/qemu_domain.c).

Jailed Firecracker uses the SDK's existing exact jailer cgroup helper for create, restart, adoption and cleanup. A pinned process identity surrounds readback. New-process validation happens before machine configuration or snapshot load, and failure destroys only that newly tracked process. Burstable restores load paused, verify effective restored CPU/RAM against the admitted grant, verify controls again, then resume. Failed adoption preserves the existing process. Ordinary unjailed Firecracker remains unsupported for burstable workloads.

Local `WorkloadResourceLimitsEvidence` distinguishes raw desired bytes, aligned targets, applied native Int64 values, unlimited controls, ownership and acknowledgement. Missing/malformed evidence remains unknown. Existing workload pressure/events are sampled at a verified controller root; a QEMU PID's emulator leaf is never treated as that root. Structured diagnostics expose desired/applied evidence locally. Adding this evidence to shared wire telemetry remains blocked on the STR-267/reconciler owner's field and schema-version allocation; this branch allocates no additional wire version or competing class model. Wire v64 remains reserved for GuestConfig.

Deterministic tests cover transition ordering, failure at each acknowledgement stage, retries from every known phase, exact ownership/process identity, persistent snapshot replay, and native integer telemetry. SDK fixtures cover refusal before snapshot load and confirmed fresh-process rollback. These are process/file fixtures, not kernel acceptance. This cloud environment has no KVM device or backend binaries and mounts cgroup-v2 read-only. No host controls, infrastructure or security configuration were changed. Actual pressure survival, local OOM containment, CPU fairness/idle borrowing and backend create/restart/adopt/delete acceptance remain unverified.

## Generation and host-report acknowledgement dependency

STR-267's final placement checkpoint `dff67c73f2e7272e643d2c6aab26bb16b80bf8ec` requires generation-specific enforcement acknowledgement that proves the admitted footprint appears in the same host net-resource report. Local desired/applied diagnostics alone cannot release placement or growth reservations.

The proposed coordinated acknowledgement must bind workload kind/id, current desired generation, admitted class id/revision, backend, admitted reservation identity/footprint, and the enclosing host-report identity. Applied limits must equal the canonical aligned targets, CPU quota must be unlimited, ownership must be verified, and the report must account for that same admitted reservation exactly once. Unknown/failed evidence, stale generations or reports, and a mismatch between the workload acknowledgement and net-resource accounting preserve the reservation and block activation. This is an invariant proposal pending agreement with the STR-267/STR-266 owners; no wire fields/version have been allocated here. Host cgroup paths remain local diagnostics rather than an assumed wire field. Capability remains disabled until the report and rollback contracts are integrated and validated.
