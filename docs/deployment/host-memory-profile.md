# Opt-in host memory density profile

STR-268 is an operator bootstrap policy, not desired state. The agent only
reads configuration and effective kernel state. It never writes sysfs, activates
swap, or starts KSM from a heartbeat or API request. No profile is installed by
default. STR-266 / PR #1361 is the telemetry prerequisite.

Drain the host before installing, disabling, or changing its tenant classification.
A `single` classification is an explicit operator assertion that every workload
on that host belongs to one trust boundary. Do not use it on a shared site.
There is no API that enables KSM. Both the bootstrap validator and the agent
observer reject `ksm: true` with `tenant_class: multi`.

Prepare an NVMe swap device or fully allocated swap file yourself. The helper
checks its swap signature and its NVMe backing device. It does not create,
format, resize, delete, or discard the fallback. Device-mapper, RAID, and other
indirect backing devices are deliberately rejected because their NVMe provenance
is not proven by this profile. Existing operator swaps remain enabled.

Example JSON for a multi-tenant host:

```json
{
  "tier": "zram",
  "tenant_class": "multi",
  "nvme_swap": "/dev/nvme0n1p1",
  "zram_bytes": 1073741824,
  "require_mglru": true
}
```

For zram, load the zram module before bootstrap and leave `zram0` unused; the
helper refuses an operator-owned initialized device. Bootstrap installs a
modules-load file to load zram again at boot. For zswap, select `"tier": "zswap"`
and optionally `"zswap_pool_percent": 20` (1–50). The zswap module/control must
already exist. Unsupported controls fail with their exact missing sysfs path.
THP must support `madvise`; explicit hugepages are outside this policy and
unknown profile keys, including hugepage settings, are rejected.

Run the reviewed helper from the same checkout/release as the installer:

```sh
sudo python3 deploy/agent/host-memory-profile.py install --config /path/to/profile.json
```

Alternatively supply `--host-memory-profile /path/to/profile.json` and
`--host-memory-tool /path/to/host-memory-profile.py` to `deploy/agent/install.sh`.
Systemd and Python 3 are required. This is an explicit privileged operator action.
The helper installs a oneshot unit ordered before the agent. A failed boot-time
application remains a profile health failure; it does not weaken authentication.
The independent dependency observer fences every hypervisor backend, including
Firecracker and sandboxes without networking, while the profile is unhealthy or
its observation is stale.

## Settings, persistence, and rollback

The root-only configuration lives at `/etc/strato/host-memory-profile.json`.
The root-only recovery journal at `/var/lib/strato/host-memory-profile.json` is
written before host effects. A process lock serializes apply/install/disable.
Applying the same profile twice preserves the original baseline and avoids
reformatting or reactivating an active swap. Changing a profile requires disable
first. Keep the host drained until rollback and the next observation are healthy.

| Setting | Effective policy and reboot | Disable behavior |
| --- | --- | --- |
| zram | Owned `zram0`, label `strato-density`, priority 100; initialized at boot | Swap off and reset only the profile device; refuse a replaced operator device |
| zswap | Enabled with bounded pool percentage; reapplied at boot | Restore captured enabled/pool settings |
| NVMe fallback | Prepared device/file, activated at priority 10 if initially inactive | Swap off only if activated by this profile; never delete or format it; initially active fallback remains active |
| Other operator swaps | Preserve; reject zram profile if another priority is ≥100 | Preserve |
| THP | `madvise`, reapplied at boot; no explicit hugepage changes | Restore captured selected THP policy |
| MGLRU | Observe actual main enable bit (`0x1`); optionally require it | Never mutate it |
| KSM | Off by default, including unmerging inherited pages | Always off; restore captured scanner controls, never re-enable inherited KSM |

Disable with:

```sh
sudo /usr/local/libexec/strato-host-memory-profile disable
```

Disable first removes boot activation, then requests KSM unmerging (`run=2`).
Nonzero `pages_shared` or `pages_sharing` yields
`ksm_unmerge_pending_no_hostile_placement`. Retry disable until both are zero;
only then is `run=0` applied and recovery/configuration removed. This fences new
placements while pages age out/unmerge; it does not relocate existing workloads.
Only after that boundary may an operator classify the host as multi-tenant and
install the new profile. Swapoff can fail under pressure; the journal is retained
for retry, and the host must stay drained. Rollback never uses `swapoff -a`.

Single-tenant KSM additionally accepts `ksm: true`, `ksm_pages_to_scan` (1–1000,
default 100), and `ksm_sleep_millisecs` (50–60000, default 100). These bound scan
work and frequency; they are not a hard CPU quota for the kernel thread. Observe
CPU pressure and reduce scanning if workload latency regresses. The agent checks
that the running scanner matches those controls.

## Observation and pressure verification

The existing independent 15-second sampler reports bootstrap intent alongside
active tier, selected THP, KSM, and a specific mismatch reason. Missing kernel
signals remain unavailable, never measured zero. MGLRU's secondary feature bits
do not imply the main enable bit is active. Dependency health is observe-only.

Telemetry exposes compressed original/used bytes and their ratio, swap-in/out
pages per second, and bounded `swap_thrashing` / `oom_kill` warning series.
The first sample and a reset/decreasing counter have no rate. Thrash means
both swap-in and swap-out increased while memory PSI `full avg10` is at least
0.5 percent; OOM means `oom_kill` increased between completed samples.
Zram priority 100 ensures the compressed swap is selected before priority-10
NVMe. Zswap caches pages before writing them to its backing swap; a full or
incompressible pool may immediately spill to disk.

The deterministic pressure fixture checks tier priority, compressed allocation,
swap rates, counter resets, and the exact warning boundary. It does not prove
physical-kernel pressure behavior. Before production rollout, use a drained,
disposable Linux host: gradually allocate compressible anonymous memory, inspect
`/proc/swaps`, zram `mm_stat` or `Zswap`/`Zswapped`, and observe compression grow
before NVMe usage; then exceed the tier to exercise spill and thrash alerts.
Repeat with incompressible memory and under constrained free RAM. No such live
host tuning is performed by the repository test suite.

Wire version 65 carries the observations. Version 64 is reserved for concurrent
GuestConfig work; integrate that change and deploy matching agent/control-plane
builds together before rollout.
