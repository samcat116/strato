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
- authorization is scoped to what each agent was handed (issue #562). Every
  point that emits download URLs to an agent — desired-state sync assembly for
  a VM placed on it, and a volume create it is asked to service — records a
  coordination grant (`imggrant:agent:{agentId}:image:{imageId}`, 30-minute
  TTL) as the URLs are produced, and the route serves an agent only images it
  holds a grant for. The TTL is the grace window: a placement revoked mid-pull
  does not fail a download already in flight, and every periodic sync refreshes
  the grant while the placement stands. Sandbox images are unaffected — those
  pull from a registry with credentials minted into the sync, never through
  this route. Grant reads fail *open* when the coordination store cannot
  answer, so a Valkey outage degrades to the previous trust model instead of
  stalling every image pull in the fleet.
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
[ADR 0002](../adr/0002-ceph-for-distributed-block-storage.md) has since
chosen Ceph/RBD per site as the distributed backend (see
[distributed-storage](./distributed-storage.md)).

## Key design points

### Typed disk attachments

Operations that produce a disk return a `DiskAttachment` (host path + actual
`DiskFormat`). Hypervisor drivers declare that format when attaching the disk
instead of assuming qcow2.

### One image-materialization path

`materializeDisk(at:from:format:)` is the single image → disk path, used by:

- `LibvirtService` for boot disks (`<vmStoragePath>/<vmId>/disk.qcow2`),
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

### Inspection reads through the image lock

Every read of an image's metadata — `volumeInfo`, and the format detection
behind materialization, cloning and snapshot overlays — goes through one
`qemu-img info` helper, and that helper passes `-U` (force-share).

A running QEMU holds a write lock on every image it has open, so without `-U`
the query fails outright against any image a live guest has open (STR-193).
Resize is where that was reachable: both the size probe and the grow
precheck inspect the volume, so a grow against an attached volume degraded
with `Volume info query failed` before it ever reached the guard below that
was supposed to decide the question. Snapshotting and cloning an attached
volume would have failed in the same helper, but the control plane refuses
both at admission for their own reasons, so they never got that far.

`-U` belongs on that call and no other. It is safe on inspection precisely
because inspection is read-only; the worst case is reading a field a
concurrent writer is mid-update on. On a mutating invocation (`create`,
`convert`, `resize`) the lock is doing real work, and forcing it there is
exactly the "rewrite qcow2 metadata underneath a live guest" failure the grow
guard exists to prevent. Note that `qemu-img create -b` does *not* need it: it
opens the backing file read-only, so a snapshot overlay over a live volume
takes no lock of its own.

### Deleting a VM removes its directory whole

A materialized boot disk has no volume row, so nothing in the volume lifecycle
reclaims it; the hypervisor driver's delete does, by removing
`<vmStoragePath>/<vmId>` recursively (`VMDirectoryLayout.removeDirectory`)
once the hypervisor session is torn down. Everything the VM owns on the host
lives there — boot disk, cloud-init ISO, UEFI varstore, sockets — and removing
the directory rather than a list of known
filenames is deliberate: the earlier file-by-file cleanup grew one unlink per
feature and never included the boot disk, leaking it on every delete. Attached
volumes are unaffected: they live under `volume_storage_path` and are reclaimed
by `deleteVolume`. Sandboxes already tore their directory and jail chroot down
this way.

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

The control plane never derives paths. Since volumes became desired state
(STR-148) the path travels in exactly one direction: the agent reports it on
`ObservedVolumeState` and the control plane stores what it is told. No desired
entry carries a path, and nothing on the wire lets the control plane suggest
one — which is what makes a create whose report was lost recoverable, since
every verb works from ids alone.

Presence means *complete*. Every write path stages into `<name>.partial` and
publishes with a rename inside the same directory, so `listVolumes` — the
agent's presence set for reconciliation — can answer "does this volume exist?"
with "the published file is there". Without that, a truncated disk from an
interrupted `qemu-img create` would read as a converged volume; with it, the
directory a crashed create left behind reports as absent and the next sync
re-drives it.

And an *empty* inventory means empty. `listVolumes` distinguishes a store that
does not exist yet — the ordinary state of a fresh host, and genuinely no
volumes — from one that exists but cannot be read or is not a directory, which
throws. The distinction is load-bearing because an empty inventory is
authoritative to everything downstream: the reconciler would plan a create for
every volume the sync wants, over bytes almost certainly still on disk, and the
observed report's full-list semantics would confirm deletions that never
happened. An agent that cannot answer reports `volumes: nil` and converges no
volumes that round, which costs one sync and nothing else.

### Volumes are desired state

A volume's lifecycle runs on the reconciliation loop, not on RPCs (ADR 0001
stage 5). The control plane writes what it wants — the volume exists, at this
size, in this format, attached here — bumps a per-volume generation, and
returns `202 Accepted`; the agent converges and reports back, and the volume's
`conditions` are what say a mutation finished. Six imperative messages
(`volume_create/delete/attach/detach/resize/clone`) were deleted in wire v31,
and the `volume_info` read followed in v32 (STR-149) with no replacement: the
control plane answers from the observed report and its own columns. The two
snapshot verbs went at v33 (see below), so no volume frame is left at all.

What the agent gains from the move is what the imperative handlers uniquely
lacked: retry with a per-generation attempt cap, per-volume serial lanes, a
`waitingOnDependency` classification for work blocked on something else in the
same sync, and convergence that survives an agent restart because it is
re-derived from the filesystem rather than remembered.

**Resize is grow-only, and no longer detach-only** (STR-19). The old rule
refused an attached volume outright, because the only path the agent had was
`qemu-img resize` — which the image lock refuses on a file a running hypervisor
holds open, so the guard was load-bearing rather than merely cautious. The API
no longer pre-judges it: the desired size converges, and whether it is reached
online or offline is the agent's call, since only the agent knows whether a
process holds the image. A *shrink* stays refused at both ends — `400` from the
endpoint, a permanent convergence failure at the agent — because truncating a
guest's filesystem is not something a retry makes safe. That one grow-only rule
is also what refuses an attached shrink; there is no separate guard.

Two caveats belong to the caller rather than to the control plane. No agent has
an online grow path yet, so growing a volume attached to a *running* guest is
accepted and then degrades — the agent refuses it (see below). And growing the
block device never grows what is on it: guest-side rescan and filesystem
expansion (`resize2fs`, `xfs_growfs`, or the Windows equivalent) stay the
user's job.

Concretely, an attached grow is **refused by the agent** rather than attempted.
`volumeReconcileResize` looks up the volume's recorded attachment and grows the
image only when the owning VM is confirmed `.shutdown`; anything else —
running, paused, or a status the agent cannot read — is a convergence failure
naming the VM, so the control plane degrades the volume with something an
operator can act on.

That refusal is **blocked, not permanent** (STR-199), and the distinction is
the whole value of naming a remedy. Classified permanent, the refusal exhausted
the generation's attempt budget on its first try: an operator who read "stop the
guest, or detach" and did it got nothing, because no later sync re-drove the
grow. The volume sat short of a size nothing had withdrawn until someone asked
for a *different* one. A `blocked` failure is reported exactly like a permanent
one — the reason has to reach a person — but burns no attempt, so every
level-triggered sync retries and the grow lands the moment the guest stops.
Nobody re-asks; the desired size was never in doubt.

The two are still distinct classifications, because most permanent failures
name no remedy that a retry would notice. A shrink is permanent: no state of
the host makes truncating a filesystem safe.

Both halves of the remedy have to be reachable for any of this to be true, and
the *detach* half was not. `volumeSteps` planned the grow before it looked at
the attachment, so a volume detached while a grow was outstanding got `.resize`
— refused — as its only step, forever, and the detach that would have lifted
the refusal was never planned. A desired **removal** of an attachment now
outranks a pending grow; an attachment that is merely *moving* keeps the
original order, since there the resize really does have to land before the slot
changes underneath it.

The refusal is a check rather than a hope, and that distinction is the point.
Left to itself, `qemu-img resize` on an open image is turned back by the image
lock — but `locking=auto` gives up *quietly* wherever OFD locks do not work,
NFS being the case to worry about, and on such a pool the resize would not fail:
it would rewrite qcow2 metadata underneath a running guest. Deferring to the
lock would make correctness a property of the filesystem. This is also what
makes "the agent decides online vs offline" true rather than aspirational —
until there is an online grow path, the agent's decision is *no*.

A volume attached to a stopped VM does grow, which the old detach-only rule
refused outright.

**A volume reports the size it has, not just the size it was asked for**
(STR-199, wire v38). `Volume.size` is desired state — a resize answers `202` and
converges, so it moves when the mutation is accepted — and until `sizeBytes`
joined `ObservedVolumeState` it was also the only size the API could report. A
volume whose grow the agent had refused therefore answered with the size it had
*failed* to reach, which reads exactly like a grow that worked. The observed
size lands in `observed_size_bytes` and surfaces as `observedSize` alongside
`size`, so a grow still outstanding is legible as `1 GiB → 3 GiB` rather than
silently as `3 GiB`.

The original argument against the field — a `qemu-img info` subprocess per
volume per report — expired on its own: the planner needs the same number to
decide whether a grow is outstanding, so the agent already computes and caches
one per volume, and reporting it adds no work. Absence is read the way the
applied I/O ceilings are: nil is "this agent said nothing" (a pre-v38 agent, or
a probe that could not read the image), never zero, and never a licence to
clear what a previous report recorded.

Deletion is the same finalizer dance VMs use. A `DELETE` does not remove the
row: it marks the volume absent, stamps `agent.absent`, and the row survives
until the agent's full-list report *omits* the volume — which is the only thing
that confirms the data is gone. A delete against an agent that cannot confirm
(offline, or below wire v31) force-clears the token instead, because a dead
agent must not make its volumes undeletable.

### Attachment is desired state, realized live or in the domain definition

An attachment is a fact the control plane records on the volume
(`vm_id`/`device_name`/`boot_order`/`readonly`) and the agent realizes. The
agent writes the attachment into the VM's manifest entry first, then asks the
driver to attach. Record-first is deliberate: a crash between the two
re-drives an idempotent attach on the next sync, whereas the other order
would leave a plugged device nothing remembers. How the attach lands depends
on the target VM:

- **domain defined on this host** — libvirt attaches with
  `VIR_DOMAIN_AFFECT_LIVE | _CONFIG` (config-only when the guest is shut
  off), so the disk reaches the running guest *and* the persistent domain
  definition in one call; the next boot reads that definition, so there is no
  separate spawn-configuration bookkeeping to keep in step. The attach is
  idempotent by volume serial — a redelivered sync finds the serial already
  in the domain and does nothing — and the guest device name is chosen from
  the domain's own device inventory, never trusted from the control-plane
  label. One fixed budget applies: a domain's spare PCIe root ports are
  reserved when it is defined (STR-192), so a live attach with no free port
  fails with guidance rather than succeeding on retry.
- **not created on this host yet** — the record *is* the realization:
  `createVM` builds the domain's disk set from the manifest, so the disk
  lands when the VM does. A missing VM is classified as waiting on a
  dependency, so it burns no attempt and retries on the next sync — only
  ever a race, since the control plane emits an attachment only for a VM
  placed on this agent.

The observed attachment is read from that durable record, not from a live
device query, for the same reason: a VM that is not defined yet has no
device list.

The record-first shape is also what fixed a live bug in the deleted
process-QEMU driver, whose spawn path treated `VMSpec.volumes` as a
*fallback* it never reached — a hot-plugged disk silently disappeared at the
guest's next power cycle while the control plane still called the volume
attached. The libvirt driver closes that class of bug structurally: a device
attached live is written to the definition in the same call.

### Snapshots

Snapshots are external qcow2 overlays created with the volume as backing
file. The backing format is detected per volume rather than assumed, so raw
volumes snapshot correctly.

They are **desired artifacts** since ADR 0001 stage 8 (wire v33): a snapshot is
its own converging, finalizable resource with a generation, an agent, and a
finalizer that keeps its row alive until that agent's report omits it. See
[Snapshots and checkpoints as desired artifacts](#snapshots-and-checkpoints-as-desired-artifacts)
below for what that means across all three families.

One consequence is worth naming here, because it removed a borrowed status: a
volume no longer passes through `snapshotting`. The status existed only to
represent something happening *to* the volume that had nowhere else to live;
with the snapshot as its own resource, there is nothing to borrow and nothing
to restore on a failure path.

**Only detached volumes can be snapshotted** (issue #747). The overlay reads
through to the volume, and nothing switches a running QEMU's active layer onto
it — the guest would keep writing the same base the overlay points at, so the
"snapshot" would track the live volume instead of freezing a moment in time.
The control plane rejects a snapshot of an attached volume with `409`
(`Volume.canSnapshot`), and the agent refuses any capture whose entry still
names an attached VM in `DesiredSnapshotCapture.attachedVMId` — which matters
more now than it did as an RPC guard, because a level-triggered entry outlives
the request that made it and the volume may have been attached since.

Cloning has its own `canClone` with the same rule, for a related reason: it is
a `qemu-img convert` of the volume's file, and a guest writing the source
mid-copy produces a torn image. The two are separate properties so a future
live-snapshot path can relax one without relaxing the other.

This replaces the fs-freeze quiescing added in issue #563: freezing the guest
around overlay creation produced an application-consistency *signal* for a
snapshot that captured nothing, which is worse than refusing. A real live
snapshot remains future work: it would switch the guest's active layer onto
the overlay (a libvirt external disk snapshot), and needs the volume's
`storagePath`, the VM manifest, and snapshot deletion to follow the resulting
backing chain. (The QGA freeze/thaw plumbing this section used to point at
went with the process-QEMU driver in STR-136; a future implementation would
drive quiescing through libvirt, which owns the guest-agent channel.)

### Full-VM checkpoints

Volume snapshots above are disk-only. A **checkpoint** (issue #564) captures
guest RAM, device state, and disks at one consistent point — the primitive
behind "save this VM and bring it back exactly as it was" — and lives at
`POST/GET/DELETE /api/vms/:id/snapshots` plus `.../restore`, in the
`vm_snapshots` table.

The mechanism is a libvirt **system checkpoint** (`DomainSnapshotXML`,
STR-134): one `domainSnapshotCreateXML` call whose document names the tag and
no disks — naming none lets libvirt capture every disk it can, which is the
selection the old QMP-driven capture spent its rules arriving at. The state
goes into an *internal* snapshot of the VM's own qcow2 disks, tagged
`strato-<snapshotId>`, so there is no separate state file to track: the agent
re-derives the tag from the ids on every call, which makes delete idempotent,
and a create whose reply was lost is confirmed by asking the daemon whether
the tag exists rather than failing every retry. Guest RAM is included only
when the domain is running — libvirt rejects a memory snapshot of an inactive
one, where the checkpoint is the disks alone.

Consequences of "internal to the disks":

- **Every writable disk must be qcow2.** A writable raw volume cannot hold
  internal snapshot state, so the capture fails rather than freezing part of
  the machine — restoring memory alongside disks that ran on would produce a
  machine whose halves disagree.
- **The UEFI variable store is included**, and that is a host precondition,
  not an accident: libvirt refuses internal snapshots of a pflash-firmware VM
  unless the varstore can hold one, so `DomainXMLBuilder` emits a **qcow2**
  NVRAM varstore (STR-130/STR-188) and `LibvirtProbe.minimumVersion` gates
  `.qemu` on libvirt ≥ 11.5, where the modern snapshot job API landed.
- **Checkpoints do not move between hosts.** Restore is pinned to the agent
  that took it (`VMSnapshot.agentId`). Off-node export — either shared storage
  (#352/#353) or an object-storage copy like sandboxes got in #428 — is the
  follow-up.

Restore is `domainRevertToSnapshot` with the running flag: reverting a
`SHUTOFF` domain to a system checkpoint starts it, so the VM only has to
*exist* on the agent, not be running. After an agent restart the desired-state
sync re-defines a stopped VM's domain (its disks, and the checkpoint inside
them, never left the host) and the restore reverts that, which is what makes
checkpoint → stop → restart-agent → restore work with no extra machinery.
Delete works on a **stopped** VM too — libvirt removes an internal snapshot
through the disks rather than through a live monitor — so a delete no longer
waits for the operator to start the VM again.

Quota counts only the machine state (`VMSnapshot.size`), not the disks — those
are already charged under the VM, and an internal snapshot does not copy them.

One old operational hazard is *gone* with the libvirt driver and worth
recording as such: a checkpoint no longer occupies the VM's QMP stats monitor
for the duration of the job, because there is no agent-owned monitor at all —
balloon/guest-memory stats come from libvirt's own `domainMemoryStats`, so
metrics keep flowing during a capture.

A second is gone as of STR-150 in the same way. A checkpoint
used to occupy the VM's one pending operation slot, so a large one could block
start/stop/delete on that VM for up to half an hour with no feedback beyond a
bare `409`. A checkpoint is its own resource now, with its own generation and
its own budget; it contends with the VM's lifecycle only for the agent's
per-VM serial lane, which is real mutual exclusion for the duration of the
capture rather than a half-hour API lockout.

### Snapshots and checkpoints as desired artifacts

All three artifact families — volume snapshots, full-VM checkpoints, and
sandbox snapshots — run on the reconciliation loop since ADR 0001 stage 8
(STR-150, wire v33). The header this replaced claimed a checkpoint "is an
action rather than a state"; that is true of the verb and false of the result.
**"Checkpoint C exists for VM V" is a durable artifact** with an identity, a
footprint and a host, which an agent can enumerate, diff and converge on.

What changes, uniformly:

- **Capture and delete answer `202`** with `{resource, targetGeneration,
  mutationId}`; the client polls the artifact's own `conditions`, where
  `converged` and a `degraded` naming the target generation are mutually
  exclusive. A delete's success is the artifact's absence, so it polls the
  operations façade with `mutationId` instead — the rule everywhere else in
  ADR 0001.
- **The row outlives the delete.** It goes only once the owning agent's
  full-list report omits the artifact, which is the only thing that confirms
  the bytes are gone. A delete against an agent that cannot confirm (offline,
  or below v33) force-clears the token, because a dead agent must not make its
  checkpoints undeletable.
- **The captured metadata comes back on the observed report** — footprint,
  QEMU/Firecracker version, device nodes, fork layout, CPU template. As an RPC
  reply it was delivered once, so both old paths had to treat a dropped socket
  as a protocol error and mark a checkpoint that in fact existed `.error`.
- **A capture never re-runs.** It is a *create strategy* read only while the
  artifact is absent from the host — the property that makes it safe for a
  level-triggered sync to carry an instruction that pauses a live guest.
- **Statuses are purely observed.** `creating`/`ready`/`available`/`error` are
  derived by `ObservedStateApplier` from what the agent reports about the
  bytes; the control plane writes none of them.
- **The storage quota is re-checked when the real footprint arrives.**
  Admission reserves an *estimate* — a checkpoint's memory grant, a sandbox's
  guest RAM — and the agent's report replaces it with a number that can be much
  larger (a sandbox snapshot adds vmstate and, without reflink support, a full
  rootfs copy). If that puts an enabled quota over its limit the artifact is
  deleted and its `errorMessage` names the quota, which is the pre-conversion
  contract kept deliberately: tolerating the overage instead would silently
  turn a quota into a suggestion. Volume snapshots *do* draw on the pool
  (STR-181) but skip this check, because their reported figure is re-measured on
  every report rather than settled once at capture — see "Volumes and the storage
  quota" below.

The agent keeps a durable record of what it captured
(`SnapshotRecordStore`, `<vmStoragePath>/snapshot-records.json`), for the
reason `VMManifestStore` exists: a Firecracker checkpoint's fork-layout version
and CPU template are not recoverable from its files at all, and enumerating
qcow2 internal snapshots costs a subprocess per VM per report. It inherits the
same caveat — an artifact deleted out of band reports present until something
tries to use it — which is affordable because every backend's deletion is
idempotent. A record file that cannot be *read* makes the agent report
`snapshots: nil`, never an empty list: an empty inventory is authoritative
downstream and would reap every checkpoint row the control plane holds.

#### Retention

Durable artifact objects need an end, which fire-and-forget RPCs never raised —
the `Job.ttlSecondsAfterFinished` lesson ADR 0001 names as a cost of this
stage. Every artifact carries an optional absolute `expires_at`, resolved at
creation from a per-request `ttlSeconds` or the fleet default
(`SNAPSHOT_DEFAULT_TTL_SECONDS`, unset by default, so an upgrade changes
nothing until an operator opts in); `ttlSeconds: 0` keeps one forever,
overriding the default.

`SnapshotRetentionSweep` is a cluster-singleton pass that marks expired
artifacts absent down the same path an operator's `DELETE` takes — quota
release, the audit trail and the tombstone dance all come for free — attributed
to the `system` actor, the sandbox expiry sweep's arrangement. Absolute rather
than relative, because a TTL re-evaluated against "now" on each pass drifts
with every restart and an artifact whose expiry keeps moving never expires.

Count-based retention ("keep the last N per parent") is deliberately not
implemented: it needs a per-parent ordering a delete has to re-evaluate
transactionally, and the interesting failure — a snapshot deleted out from
under a fork that depends on it — is one the sandbox lineage guard already
refuses (and which the sweep shares, so a clock is refused for exactly the
reasons a human is). Time is enough to bound the leak.

### I/O ceilings

A volume carries an optional pair of absolute I/O ceilings — `iopsTotal` and
`bpsTotal` — set at create or replaced through `POST /api/volumes/:id/io-limits`
(STR-19). Quotas cap *capacity*; these cap *rate*, which is what stops one
tenant's guest saturating a shared spindle for everyone else on the host.

Total-only, deliberately. QEMU and libvirt can both express read/write splits,
burst allowances and bucket sizes; none of them has a caller yet, and one knob
per dimension is the version that can be explained in a UI. The wire type can
grow optional members later without a version bump.

The endpoint is a **full replacement**: an omitted field clears that cap, and an
empty body removes both. Zero is refused with `400` rather than read as
unlimited — QEMU spells unlimited as zero, so accepting it would make a typo
indistinguishable from a deliberate removal, on the one setting where that
difference is "this tenant is capped" versus "this tenant is not".

The ceilings travel on `DesiredVolumeState.ioLimits` (wire v35) and come back on
`ObservedVolumeState.ioLimits` as an **echo of what the agent actually applied**,
recorded separately from what was requested. The echo exists because STR-19
ships no capability gate: an agent that has never heard of ceilings drops the
field and still advances its `observedGeneration`, so the generation pair alone
would call an ignored mutation converged. Its nil rule is the load-bearing part
— nil means *"this agent does not report applied limits"*, never *"the caps were
removed"*, and an agent reporting an explicitly uncapped disk sends a
present-but-empty value instead.

**Nothing enforces these yet.** No agent applies ceilings, so `appliedIOLimits`
is null for every volume and a set `ioLimits` alongside a null `appliedIOLimits`
is the expected reading rather than a fault. Enforcement arrives with the
agent-side work; the desired state, the API and the receiving end are what
exists today.

### Volume placement across agents

Volumes are host-local. `VolumeService.selectVolumeAgent` places a volume on an
online, QEMU-capable agent (attachment goes through QEMU's block layer) that
speaks wire v31 or later, and attachment requires the VM's agent to be able to
reach the volume's data — for a local pool, the same agent that holds it.

Placement is a committed database fact *before* any sync can carry the volume,
because sync assembly finds a volume by its `hypervisor_id`. It therefore runs
as the create mutation's dispatch rather than in-band, and a create with no
eligible agent degrades the volume with that reason instead of failing the
request.

The wire-version filter is the one placement gate here that refuses rather than
degrades: with the imperative volume frames gone, a volume on a pre-v31 agent
could never be created. Both constraints — same agent, QEMU-capable — stay
enforced synchronously at accept time, so a bad attach is a `400` now rather
than a `202` that degrades a minute later.

Attachment is also contained by project: a volume may only be attached to a VM
in its own project, and a cross-project attempt is refused with `400` even when
the caller holds `attach` on the volume and `update` on the VM. Permission on
both sides is not enough — a caller with rights in two projects would otherwise
move a volume's data across the boundary silently, leaving the storage quota
attributed to the volume's project while the workload consuming it lived in
another. This is the same containment VM create applies to networks and
security groups.

### Volumes and the storage quota

Volumes, their snapshots and their clones draw on `ResourceQuota.maxStorage`
(STR-181). Until then they drew on nothing, which made the one storage object a
caller could create directly, repeatedly, at up to 256 TiB a time
(`Volume.maxSizeGB`) the only one nobody counted — and the failure was host-wide
rather than tenant-wide, because `qemu-img create` is sparse: an over-provisioned
volume succeeds instantly and the bytes arrive later, on a filesystem shared with
every other guest's disk on that node.

The blocker was scoping, not accounting. `QuotaScope.predicate` is one SQL
fragment over `project_id` **and** `environment`, shared by every aggregate so
all of them measure the same rows, and neither table had an environment. Both
carry one now, resolved from the creating request against its project exactly as
a VM's is (omitted takes the project's default) and denormalized onto the
snapshot the way `VMSnapshot` and `SandboxSnapshot` already denormalize theirs.
On upgrade, an attached volume is backfilled from its consuming VM, its existing
snapshots follow that resolved volume environment, and only unattached storage
falls back to the project's default.

What each object is charged:

| Object | Admitted against | Charged |
| -- | -- | -- |
| Volume, clone | requested `size`; any larger materialized source size before attachment | desired `size` |
| Resize | the **delta** | the new `size` |
| Volume snapshot | the parent volume's **whole** size | the parent volume's **whole** size |

A volume is charged its desired `size`, not raw `observed_size_bytes`. Normally
that is the size it asked for. Before an image-backed or cloned volume enters a
VM, attachment requires the agent's materialized virtual size and atomically
admits any delta above the request; on success, desired `size` rises to that
floor. The other mismatch is an outstanding grow, and a grow the agent refused
is blocked rather than withdrawn — it lands the moment the guest stops, with no
API call in between to admit it. Charging that smaller observed size would make
a pending grow free.

For a snapshot, `size` is the parent volume's size at capture. An overlay cannot
outgrow the volume behind it, so that is the bound, and both admitting and
continuing to reserve against it mean the pool can absorb the snapshot fully
grown. Replacing that reservation with a small first footprint would let a
caller admit several snapshots sequentially before any of their overlays had
diverged, even though all could then grow without another API call to refuse.
`observed_size_bytes` still exposes the overlay's actual allocated footprint for
observability and billing; it does not release quota capacity.

Two things this deliberately does not do:

- **No auto-delete.** The post-capture re-check that deletes an over-quota
  artifact (above) stays off for volume snapshots. The parent-sized reservation
  already protects admission, while an overlay's reported footprint never stops
  moving; arming deletion on it would re-run the check every report and destroy
  snapshots because their volume diverged.
- **No charge for a VM's boot disk twice.** For a volume whose `storage_path`
  equals a VM's `disk_path`, even after detachment clears the mutable `vm_id`,
  the `volumes` term deducts the bytes already reserved by `SUM(vms.disk)`.
  Growth above that legacy VM size remains charged, while the compatibility row
  stays out of `volume_count`. Only the rows `MigrateVMDisksToVolumes` backfilled
  can match; nothing since inserts a volume for a VM's boot disk. Without the
  deduction, an upgraded deployment would double every legacy VM's disk. The
  path identity follows the agent's own rule:
  `LibvirtService.resolveDisks` dedupes the pair by path into a single disk.

The enabling migration recomputes both `volume_count` and the complete
`reserved_storage` cache for existing quotas. Without that recount, list/detail
responses would keep showing the pre-upgrade storage reservation until an
unrelated create, resize, delete or quota update happened to trigger a resync.

`ResourceQuota` also gained an optional `max_volumes` count limit. Optional where
`max_vms` and `max_sandboxes` are required, because the only plausible backfill
was `max_vms` and it is the wrong one: a deployment that gives each VM a data
disk or two has more volumes than VMs, and would come out of the upgrade refusing
creates against a limit nobody chose. Unset means no count limit; `maxStorage`
remains the ceiling that protects the host.

Release is the reap, not the request. A `DELETE` leaves the row in place until
the agent confirms the bytes are gone, so `Volume.reap` recounts after the row
goes — one call covering the volume's snapshots too, since their rows cascade
with it and release recomputes rather than decrements.

### The attachment itself

The desired attachment is stored across five columns on `volumes` — `vm_id`,
`device_name`, `boot_order`, `readonly`, `attached_agent_id` — which the
sync projects into `DesiredVolumeAttachment`. `VolumeAttachmentService` owns
every transition so they cannot disagree (STR-129):

- **Claiming** happens inside the mutation's own transaction, under a per-VM
  Postgres advisory lock — the same idiom `IPAMService` uses for address
  allocation — so the read-allocate-write behind an auto-generated `disk<N>`
  serializes across replicas. A unique index on `(vm_id, device_name)`,
  matching the NIC tables, is the backstop; `(vm_id, boot_order)` has one too,
  so no two disks on a VM sit at one priority.
- **Every transition bumps the generation and none writes `status`.** The
  agent drops a desired entry no newer than the one it applied, so a cleared
  attachment without a bump would leave the disk plugged in forever; `status`
  moves only when the agent reports what it observed.
- **Device names are validated at the boundary** (`VolumeDeviceName` in
  `StratoShared`): they become hypervisor object ids, so a name outside
  `[A-Za-z0-9][A-Za-z0-9._-]{0,31}` is refused with `400` rather than
  surfacing later as an opaque hot-plug rejection. `VolumeSpec` carries the
  validated type, so a spec cannot express an illegal one.
- **Detach resolves the disk by volume id, never by device name.** The agent
  registers a hot-plugged disk under `vol-<volume-id>` (`QEMUDiskIdentity`);
  a device name is a per-VM label, and resolving by one is what made a
  duplicate able to unplug the wrong disk from a running guest.
- **Deleting a VM releases its volumes** inside the delete transaction: the
  volume outlives the VM and its data is intact on the agent. `volumes.vm_id`
  is `ON DELETE RESTRICT`, so a delete path that forgets fails loudly instead
  of leaving the row naming a device on a VM that no longer exists. The
  stranded-attachment sweep releases any such row it still finds, which is
  what covers a replica still running an older build mid-rollout.

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
The replica row is written from the *observed* report — it records placement an
agent has confirmed — rather than from a dispatch that awaited a response.

## Future work

- Backing-file/reflink instantiation for image-backed volumes and clones
  (the protocol already expresses these as driver operations).
- Image metadata (architecture, artifact kinds, per-hypervisor
  compatibility) is tracked separately in issue #214.
