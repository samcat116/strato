# Burstable runtime enforcement foundations (STR-272)

These helpers prepare runtime enforcement for the
[STR-267 class contract](./resource-classes-contract.md). They are not yet wired
to workload lifecycle execution. No burstable capability is advertised or
placement enabled by this change. Guaranteed workloads retain their existing
runtime path. The canonical class snapshot and wire v67 belong to the
coordinated STR-267 implementation, not an additional DTO here.

`BurstableResourceLimits` in StratoAgentKit computes an agent-local plan from
current granted guest RAM, backend allowance, memory-high percentage, and CPU
weight. It uses quotient/remainder integer arithmetic for the percentage and
rejects nonpositive grants, negative allowance, percentages outside 1...99,
weights outside 1...10000, overflow, and a missing pressure interval. Backend
allowance is never percentage-discounted:

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
Libvirt memory parameters use KiB. The plan rounds the pressure threshold down,
starting reclaim at most 1023 bytes earlier, and rounds the containment ceiling
up as the existing ceiling code does. Thresholds too small to represent refuse
enforcement. This backend quantization must be reflected in desired/applied
readback and coordinated with the class-contract owner before integration.

The read-only `scripts/check-burstable-cgroup.py` scaffold checks effective files
at an explicitly supplied owned cgroup path against expected values and captures
memory events, memory/CPU PSI, and CPU statistics. It does not establish
ownership, ancestor restrictions, delegation, lifecycle application, reclaim,
OOM containment, CPU fairness, or transient-limit safety by itself.

Remaining integration requires the executable canonical class snapshot,
backend-supported pre-execution/live control application, stable lifecycle
ownership, effective readback, complete capability gating, and coordinated
telemetry. Controller listing or unit-test fixtures alone never enable support.
Actual QEMU and jailed Firecracker kernel tests must verify create/restart/adopt,
pressure survival, workload-local containment, and CPU fairness/idle use before
claiming runtime acceptance.
