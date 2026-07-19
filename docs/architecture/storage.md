# Storage Architecture

## Overview

Agent-side storage is abstracted behind the `StorageBackend` protocol
(`agent/Sources/StratoAgentCore/StorageBackend.swift`) — the storage
counterpart of `HypervisorService` (compute) and `NetworkServiceProtocol`
(networking). Everything that turns images and empty space into attachable
disks goes through it: volume create/delete/resize, snapshots, clones, info
queries, and image materialization.

The first implementation is `FileSystemStorageBackend`: qemu-img operating on
a local directory. Future backends (LVM, Ceph RBD, ZFS, raw-file layouts for
Virtualization.framework) implement the same protocol and can realize
`createVolumeFromImage`/`cloneVolume` efficiently — backing files, reflinks,
COW snapshots — instead of full copies.

## Key design points

### Typed disk attachments

Operations that produce a disk return a `DiskAttachment` (host path + actual
`DiskFormat`). Hypervisor drivers declare that format when attaching the disk
instead of assuming qcow2.

### One image-materialization path

`materializeDisk(at:from:format:)` is the single image → disk path, used by:

- `QEMUService` for boot disks (`<vmStoragePath>/<vmId>/disk.qcow2`),
- `FirecrackerService` for root drives (`<vmStoragePath>/<vmId>/rootfs.raw`),
- `createVolumeFromImage` for image-backed volumes.

It inspects the cached image with `qemu-img info` and converts with
`qemu-img convert` when the source format differs from the requested one, so
a qcow2 cloud image really becomes a raw rootfs for Firecracker (previously
the qcow2 bytes were copied verbatim to `rootfs.ext4`, producing an
unbootable guest). Materialization writes to a staging path and publishes via
atomic rename, so the final path never holds a half-written disk; that makes
the operation safely idempotent — an existing disk at the target path is
reused.

### The host image cache

Downloaded image artifacts are cached on the host by `ImageCacheService`
(`agent/Sources/StratoAgent/ImageCacheService.swift`) under
`image_cache_dir` (default `/var/cache/strato/images`), laid out as
`{projectId}/{imageId}/[{artifactKind}/]{filename}`. Repeat launches of the
same image verify the cached file's SHA-256 against the control plane's
checksum and skip the download entirely; downloads are staged and published
by atomic rename, so the cache never holds partial bytes. Materialization
always copies/converts out of the cache — cached files are never used as
qcow2 backing files — so evicting an entry can't break an existing VM.

The cache is bounded by `image_cache_max_size_gb` (unset = unbounded): before
each download, least-recently-used image directories are evicted (shared
`DiskCacheLRU` helper in `StratoAgentCore`) until the cache plus the incoming
artifact fits the budget. Cache hits refresh an image's last-use time, and
images used within the last 30 minutes are never evicted — a VM create that
is still copying an image out of the cache can briefly hold it over budget.
The sandbox rootfs cache applies the same budget mechanism via
`sandbox_image_cache_max_size_gb` (see `sandboxes.md`).

### The agent owns path layout

Volume placement is decided by the storage backend:

```
<volumeStoragePath>/<volumeId>/volume.<format>
<volumeStoragePath>/<volumeId>/snapshots/<snapshotId>.qcow2
```

The volume root is the agent's `volume_storage_dir` config key (default
`/var/lib/strato/volumes` on Linux), so a non-root agent can point it at a
directory it can write.

The control plane never derives paths; it stores whatever path the agent
reports in `VolumeStatusResponse` and passes it back verbatim on later
operations. Delete and snapshot-delete work from IDs alone, so cleanup
succeeds even when a create's response was lost before the control plane
recorded the path. (The wire messages still carry optional legacy path-hint
fields for compatibility; new control planes leave them nil.)

### Snapshots

Snapshots are external qcow2 overlays created with the volume as backing
file. The backing format is detected per volume rather than assumed, so raw
volumes snapshot correctly.

### Volume placement across agents

Volumes are host-local. The control-plane `VolumeService` places volumes on
online QEMU-capable agents (attachment goes through QEMU's block layer), and
attachment requires the VM's agent to be able to reach the volume's data —
for a local pool, the same agent that holds it.

### Pools and replicas (data model)

Placement is expressed through the phase-1 data model from
[`distributed-storage.md`](./distributed-storage.md): every `Volume` belongs
to a `StoragePool` (mode `local`/`replicated`, backing
`filesystem`/`zfs`, member agents, replication factor), and each physical
copy of a volume is a `VolumeReplica` row (agent, agent-owned dataset path,
health state, reconciliation generation). Today the only pool is the
migration-seeded `default` local pool — one replica per volume, `filesystem`
backing, any QEMU-capable agent eligible — which reproduces the host-local
behavior above exactly. While attached, `Volume.attachedAgentId` records the
agent the attachment runs on. The legacy `hypervisor_id`/`storage_path`
columns are dual-written alongside the replica row until nothing reads them.
The agent-side `StorageBackend` protocol and the wire protocol are untouched
by this model.

## Future work

- Backing-file/reflink instantiation for image-backed volumes and clones
  (the protocol already expresses these as driver operations).
- Image metadata (architecture, artifact kinds, per-hypervisor
  compatibility) is tracked separately in issue #214.
