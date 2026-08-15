# STR-154 Disk Attachments Design

## Goal

Replace the agent's host-path `DiskAttachment` with one value that can describe
file-backed disks, host block devices, and native RBD images. Carry that value
through the current desired-state wire contract and control-plane persistence
without changing filesystem-backed VM or volume behavior.

## Current-system constraints

- The filesystem backend remains the only storage backend in this issue and
  returns `.file(path:format:)` from every operation that produces a disk.
- STR-148 removed the imperative `volume_*` messages. Volume locations now
  travel from agent to control plane in `ObservedVolumeState` and return to the
  agent in each VM's `VolumeSpec`.
- Wire registration requires an exact version match. STR-154 therefore bumps
  `WireProtocol.currentVersion`; it does not add a second feature capability.
- The agent owns storage layout. The control plane stores the complete reported
  attachment on `VolumeReplica` and projects it back without deriving or
  rewriting it.
- Existing `volume_replicas.dataset_path` rows represent file attachments. The
  upgrade migration must preserve them as `.file`, using the existing
  extension rule (`raw` only for `.raw`; `qcow2` otherwise).

## Architecture

`StratoShared` owns a single `Codable`, `Equatable`, `Sendable`
`DiskAttachment` enum and the `DiskFormat` enum it embeds:

```swift
public enum DiskAttachment: Codable, Equatable, Sendable {
    case file(path: String, format: DiskFormat)
    case blockDevice(path: String)
    case rbd(pool: String, image: String, user: String, monHosts: [String])
}
```

This is the only disk-location representation across package boundaries.
`StorageBackend.listVolumes()` and disk-producing storage operations return it;
`ObservedVolumeState` reports it; `VolumeReplica` persists it as JSON; and
`VolumeSpec` echoes it to the VM-hosting agent.

Agent-only logic keeps path-based filesystem operations narrow. Code that calls
`qemu-img`, adopts historical bytes, snapshots, clones, or probes virtual size
must explicitly require `.file` (the only backend implemented in this phase).
Hypervisor realization switches over all cases:

- libvirt renders file disks as `<disk type="file">`, block devices as
  `<disk type="block">`, and RBD images as `<disk type="network">` with an
  RBD source, monitor hosts, and cephx user.
- Firecracker accepts `.file` and `.blockDevice` as host paths and rejects
  native `.rbd`; a later Ceph backend will map RBD through krbd and supply the
  resulting `.blockDevice`.

`ResolvedDisk` contains the typed attachment plus attach-only options rather
than splitting it back into path and format. Create-time and hot-plug libvirt
XML share one attachment-aware builder so their representations cannot drift.

## Data flow

1. `FileSystemStorageBackend` creates or inventories a volume and returns
   `.file(path:format:)`.
2. Agent reconciliation reports that exact value as
   `ObservedVolumeState.attachment`.
3. `ObservedStateApplier` stores it in `VolumeReplica.diskAttachment`.
4. `DesiredStateAssembler` loads that value for the VM's receiving agent and
   `VMSpecBuilder` writes it into `VolumeSpec.attachment`.
5. Before create or attach, the agent replaces any echoed value with its own
   current storage inventory value, preserving agent authority.
6. Libvirt or Firecracker switches on the attachment case and emits the
   backend-native disk configuration.

## Persistence migration

Add nullable JSON `volume_replicas.disk_attachment`, backfill every non-null
`dataset_path` into the synthesized-Codable `.file` representation, make the
new field authoritative, then drop `dataset_path`. Update the reviewed
`CurrentSchema.sql` baseline to contain only the new field. The revert restores
`dataset_path` only for `.file` rows; non-file values have no faithful legacy
representation and therefore revert to null.

The public `VolumeReplicaResponse` widens from `datasetPath` to
`diskAttachment`. This prevents a future RBD value from being hidden or
misrepresented as a path.

## Error behavior

- A filesystem-only operation receiving a non-file attachment fails with a
  classified, explicit error rather than manufacturing a path.
- Firecracker rejects native RBD with `notSupported`; `.blockDevice` is valid.
- Libvirt reports malformed or unsupported realization through its existing
  `diskError`/`invalidConfiguration` paths.
- Missing attachments remain retryable dependencies where a missing path is
  retryable today.

## Tests

- Shared wire tests pin all three JSON shapes and their round trips, plus the
  wire version bump.
- Agent storage tests prove the filesystem backend still returns `.file`.
- Domain XML tests cover file, block-device, and RBD create/hot-plug fragments;
  Firecracker tests cover accepted path cases and native-RBD rejection at its
  pure resolution boundary where possible.
- Control-plane tests prove an observed RBD value is stored verbatim and then
  emitted in a VM spec, while file-backed convergence remains unchanged.
- Migration/baseline tests verify the new column shape and old-path backfill.

## Out of scope

- A Ceph storage backend, cephx secret distribution, krbd mapping, pool modes,
  RBD lifecycle operations, and snapshots.
- Compatibility with older wire versions; exact-version registration already
  rejects skew.
- Generalizing the still-filesystem-only resize/snapshot/clone APIs beyond the
  explicit case checks needed to keep this refactor type-safe.
