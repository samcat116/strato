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
unbootable guest). Materialization is idempotent: an existing disk at the
target path is reused.

### The agent owns path layout

Volume placement is decided by the storage backend:

```
<volumeStoragePath>/<volumeId>/volume.<format>
<volumeStoragePath>/<volumeId>/snapshots/<snapshotId>.qcow2
```

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
attachment requires the volume and VM to live on the same agent.

## Future work

- Backing-file/reflink instantiation for image-backed volumes and clones
  (the protocol already expresses these as driver operations).
- Image metadata (architecture, artifact kinds, per-hypervisor
  compatibility) is tracked separately in issue #214.
