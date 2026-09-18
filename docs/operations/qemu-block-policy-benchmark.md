# QEMU block policy validation and benchmark

Use this runbook to validate STR-269 on a Linux libvirt agent and to collect
the evidence required before changing the default block mode. It deliberately
keeps `conservative` as the product default; this document defines the
comparison but contains no fabricated benchmark result.

## Test matrix

Run at least these cases with the same guest image, vCPU count, memory, disk
size, and `fio` job:

| Backend and format | `conservative` | `direct` | `cachedShared` | TRIM check |
| --- | --- | --- | --- | --- |
| Local thin raw file | required | required | optional | required |
| Local qcow2 file | required | required | required | required |
| Native RBD raw image | required | required fallback | optional | required |
| Shared golden-image backing layout | required | required | required | only when the writable overlay supports it |

The RBD `direct` case is a negative control today: it must converge while
reporting that native RBD does not use the probed POSIX io_uring path. Run the
shared-base row only when the storage layout actually shares a read-only base
inode or RBD parent; independent full copies do not test page-cache sharing.

## Prerequisites

- A source-built fresh stack and Linux QEMU agent from
  [E2E testing](../development/e2e-testing.md).
- A QEMU guest image with the Strato guest agent enabled, plus `fio`, `fstrim`,
  and a filesystem mounted with discard support.
- Four or more assigned vCPUs for the multiqueue case.
- Access to `qemu:///system`, the local volume directory, and `rbd du` for the
  selected Ceph pool.
- A dedicated benchmark host. Dropping caches or creating storage pressure on
  a production host invalidates both the safety and the results.

Record the Strato commit, QEMU/libvirt/kernel/Ceph versions, CPU model, host
filesystem and mount options, RBD pool settings, image format, and guest
kernel/filesystem with every result.

## Prove requested and applied state

Create otherwise-identical VMs with `blockMode` set to `conservative`,
`direct`, and `cachedShared`. Create and hot-attach an identically configured
data volume to each VM. Use `guestAgentEnabled: true` if the benchmark will run
commands through `POST /api/vms/{vmID}/actions/run`.

For every boot and data volume, read the volume API response and save:

```text
blockMode
appliedBlockPolicy.active
appliedBlockPolicy.cacheMode
appliedBlockPolicy.ioMode
appliedBlockPolicy.discard
appliedBlockPolicy.nonRotational
appliedBlockPolicy.queueCount
appliedBlockPolicy.fallbackReason
```

Then inspect the live domain:

```bash
virsh -q -c qemu:///system dumpxml "$VM_ID" > "$VM_ID.xml"
python3 - "$VM_ID.xml" <<'PY'
import sys, xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
for disk in root.findall("./devices/disk"):
    target = disk.find("target")
    driver = disk.find("driver")
    serial = disk.findtext("serial", default="unmanaged")
    print(serial, target.attrib if target is not None else {},
          driver.attrib if driver is not None else {})
PY
```

The boot disk is the cold path and the data disk is the hot-attach path. For
the same requested mode, backend, and vCPU count, their `cache`, `io`,
`discard`, `detect_zeroes`, and `queues` values must match. `rotation_rate`
must be absent on both paths while libvirt rejects it for virtio-blk; the API
must report `nonRotational: false` and name that limitation in the fallback
reason.
Restart the agent while the VM is running, let it re-adopt the domain, and
confirm that the API still reports the same applied values.

For an unsupported direct-I/O combination, the VM must still converge. The
XML must omit both `cache='none'` and `io='io_uring'`, and the API must contain
a non-empty `fallbackReason`. It is a failure if only half of that pair is
emitted or the fallback makes VM creation fail.

## Prove discard reclaims allocated bytes

Use a dedicated data disk so root-filesystem background activity cannot hide
the result. In the guest, fill most of the mounted filesystem, sync it, delete
the file, sync again, and trim:

```bash
fio --name=trim-fill --filename=/mnt/strato-trim/payload \
  --rw=write --bs=1M --size=4G --direct=1 --fsync_on_close=1
sync
rm /mnt/strato-trim/payload
sync
fstrim -v /mnt/strato-trim
```

Measure allocated bytes after the write and again after `fstrim`. For a local
file, use allocated blocks rather than apparent length:

```bash
stat -c '%b * 512' "$VOLUME_PATH" | bc
du -B1 "$VOLUME_PATH"
```

For RBD, use the exact image named by the attachment:

```bash
rbd du --pool "$RBD_POOL" --image "$RBD_IMAGE" --format json
```

The post-trim allocated value must be lower in both supported rows. Also save
the guest's `fstrim -v` output and the applied policy. A lower guest free-space
counter alone does not prove backend reclamation.

## Prove virtio-blk multiqueue

Inside the guest, the number of queue directories must equal the applied
`queueCount` (the assigned vCPU count, capped at 256):

```bash
DEVICE=vdb
find "/sys/block/$DEVICE/mq" -mindepth 1 -maxdepth 1 -type d | wc -l
```

To prove use rather than configuration alone, mount debugfs on the disposable
guest, capture every hardware-context `dispatched` counter before and after a
parallel direct-I/O run, and retain the deltas:

```bash
mountpoint -q /sys/kernel/debug || mount -t debugfs debugfs /sys/kernel/debug
grep -H . "/sys/kernel/debug/block/$DEVICE"/hctx*/dispatched
fio --name=mq --filename=/mnt/strato-data/mq.bin --rw=randrw --rwmixread=70 \
  --bs=4k --ioengine=io_uring --direct=1 --iodepth=64 \
  --numjobs="$(nproc)" --runtime=60 --time_based --group_reporting
grep -H . "/sys/kernel/debug/block/$DEVICE"/hctx*/dispatched
```

More than one hardware context must increase. If that debugfs counter is not
available in the guest kernel, use `blktrace` or an equivalent blk-mq trace and
record the per-hardware-context evidence; `fio --numjobs` by itself does not
prove multiple queues were used.

## Compare cache modes

Run at least three iterations per matrix cell. Alternate mode order to avoid
giving every warm-cache run to one mode. Save `fio --output-format=json` for a
read-heavy golden-image workload and a mixed writable workload, together with:

- throughput, IOPS, mean and p95/p99 latency;
- QEMU host CPU time and peak RSS;
- host page-cache growth and reclaim pressure;
- guest CPU time and major faults;
- backend allocated bytes before and after the run;
- every applied policy and fallback reason.

Use the same durability semantics in every cell. Do not substitute
`cache=unsafe`, disable barriers, or omit application flushes to make one mode
look faster. For `cachedShared`, run enough identical guests concurrently to
measure shared host pages; a single VM tests caching, not density.

Attach the raw result files and a summary table to the issue. A default change
needs representative local and RBD evidence, no integrity errors across crash
or forced-stop testing, and an explicit explanation of the density/latency
trade-off. Until then, callers must opt into either optimized mode.
