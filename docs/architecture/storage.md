# Storage Architecture

There are two independent storage layers, and they are easy to confuse:

- **Control-plane image storage** — where uploaded and imported image bytes
  live, behind the `ImageObjectStore` protocol. Covered directly below.
- **Agent-side disk storage** — how an agent turns a cached image into an
  attachable disk, behind the `StorageBackend` protocol. Covered from
  [Agent-side storage](#agent-side-storage) onward.

## Control-plane image storage

The control plane keeps image bytes behind `ImageObjectStore`
(`control-plane/Sources/App/Services/ImageObjectStore.swift`), chosen at
startup by `IMAGE_STORAGE_BACKEND`:

| Backend | Value | Where bytes go |
| --- | --- | --- |
| Filesystem (default) | `filesystem` | A local directory, `IMAGE_STORAGE_PATH` |
| S3-compatible | `s3` | Any S3 API implementation — AWS, MinIO, Garage, Ceph RGW, R2 |

Object keys are exactly the relative paths already stored in
`Image.storagePath` / `ImageArtifact.storagePath` —
`{projectId}/{imageId}/{filename}`, or
`{projectId}/{imageId}/{kind}/{filename}` for typed artifacts. Switching
backends therefore needs no database migration, only a copy of the bytes.

### Why agents still fetch through the control plane

Agents do **not** talk to the object store. They fetch from
`GET /api/projects/{p}/images/{i}/download`, and the control plane streams the
object through. Presigned bucket URLs would be one round trip cheaper, but:

- the download route is the single place artifact authentication lives:
  agents authenticate with their SPIFFE SVID over the Envoy mTLS listener
  (issue #493 retired the HMAC-signed URLs). You cannot put SVID RBAC on a
  presigned S3 URL.
- bucket credentials never leave the control plane, and agents need no network
  route to the object store.

Per-node caching makes the extra hop cheap: `ImageCacheService` fetches a given
image once per agent (see [the host image cache](#the-host-image-cache)).

### Uploads stream

Both upload handlers (`POST .../images` and `POST .../images/{id}/artifacts`)
stream the multipart body into the store via `StreamingMultipartReceiver`
rather than buffering it. A 4 GiB image used to cost 4 GiB of control-plane
RAM before a byte was persisted. SHA-256 and size are computed over the bytes
as they pass, and the disk format is sniffed from the first few bytes, so
nothing has to re-read the finished object.

Because the object key must be known before the first byte is written, an
artifact upload has to name its `kind` up front: either as a `?kind=` query
parameter, or as a `kind` form field ordered ahead of the `file` part. Fields
that only affect the database row (`name`, `description`, `format`, …) may
appear anywhere in the body.

A write that fails part-way is never published — the filesystem backend stages
to a sibling path and publishes with `rename(2)`, and the S3 backend abandons
the multipart upload — so an agent can never fetch a truncated image. If the
control plane dies mid-upload the filesystem staging file is left behind;
opening a writer in that directory sweeps `.partial.*` siblings older than a
day, so abandoned bytes are reclaimed rather than accumulating unreferenced.

### Configuration

`IMAGE_S3_BUCKET` is required when the backend is `s3`. Leave
`IMAGE_S3_ENDPOINT` empty for AWS; set it to e.g. `http://minio:9000` for a
self-hosted implementation, which is addressed path-style by default
(`IMAGE_S3_VIRTUAL_HOST_STYLE=true` switches to virtual-host addressing).
`IMAGE_S3_REGION` defaults to `us-east-1` and is still needed for request
signing even by implementations that ignore regions. Setting
`IMAGE_S3_ACCESS_KEY_ID` and `IMAGE_S3_SECRET_ACCESS_KEY` together uses static
credentials; leaving both unset falls back to the ambient credential chain
(IRSA, workload identity, instance role), which is preferable where available.
`IMAGE_S3_SESSION_TOKEN` is optional alongside static credentials.

Every `IMAGE_S3_*` variable treats an empty value as unset. Deployment
templates routinely set a variable to the empty string rather than omitting it
— Compose's `KEY: ${KEY:-}` form always sets the key — so "leave it empty"
and "leave it unset" mean the same thing here.

No object store is bundled with either deployment path — you supply the bucket.

### Which backend to run

`deploy/compose` is single-host, so the filesystem backend on the
`image_storage` volume is the right default there.

**On Kubernetes, use `s3`.** The Helm chart mounts no persistent volume for
images, so the filesystem backend writes into the pod's ephemeral filesystem:
uploads are lost on restart, and with more than one replica (the chart ships an
HPA) each replica sees a different partial set — an agent can be handed a
download URL that whichever replica answers it has never heard of. The
filesystem default survives only so a single-replica install still starts.

## Agent-side storage

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
(`agent/Sources/StratoAgentCore/ImageCacheService.swift`) under
`image_cache_dir` (default `/var/cache/strato/images`), laid out as
`{projectId}/{imageId}/[{artifactKind}/]{filename}`. Repeat launches of the
same image verify the cached file's SHA-256 against the control plane's
checksum and skip the download entirely; downloads are staged and published
by atomic rename, so the cache never holds partial bytes. Concurrent requests
for the same entry are collapsed into one download by a `SingleFlight` lane
keyed on the destination path, so two workloads placed together against a cold
image share a download instead of racing to publish it. Materialization
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
