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

### Deleting a VM removes its directory whole

A materialized boot disk has no volume row, so nothing in the volume lifecycle
reclaims it; the hypervisor driver's delete does, by removing
`<vmStoragePath>/<vmId>` recursively (`VMDirectoryLayout.removeDirectory`)
once the hypervisor process is torn down and swtpm is stopped. Everything the
VM owns on the host lives there — boot disk, cloud-init ISO, UEFI varstore,
TPM state, sockets — and removing the directory rather than a list of known
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
an online grow path yet, so growing an attached volume today is accepted and
then sits degraded until the agent-side work lands. And growing the block
device never grows what is on it: guest-side rescan and filesystem expansion
(`resize2fs`, `xfs_growfs`, or the Windows equivalent) stay the user's job.

Deletion is the same finalizer dance VMs use. A `DELETE` does not remove the
row: it marks the volume absent, stamps `agent.absent`, and the row survives
until the agent's full-list report *omits* the volume — which is the only thing
that confirms the data is gone. A delete against an agent that cannot confirm
(offline, or below wire v31) force-clears the token instead, because a dead
agent must not make its volumes undeletable.

### Attachment is desired state, realized at boot or by hot-plug

An attachment is a fact the control plane records on the volume
(`vm_id`/`device_name`/`boot_order`/`readonly`) and the agent realizes. Which
way it realizes depends on the target VM:

- **live hypervisor session** — the agent writes the attachment into the VM's
  manifest entry first, then hot-plugs it over QMP, then updates the driver's
  stored spawn configuration. Record-first is deliberate: a crash between the
  two re-drives an idempotent hot-plug, whereas the other order would leave a
  plugged device nothing remembers.
- **present but powered off** — the record *is* the realization. The spawn path
  rebuilds the guest's disk set from the recorded volumes, so the disk lands at
  the next boot. Reporting "not attached" here would leave the volume
  permanently unconverged and get it degraded for the crime of having a stopped
  VM.
- **not on this agent at all** — classified as waiting on a dependency, so it
  burns no attempt and retries on the next sync. Only ever a race, since the
  control plane emits an attachment only for a VM placed on this agent.

The observed attachment is read from that durable record, not from a live QMP
query, for the same reason: a powered-off guest has no device list.

This is also what fixed a live bug. `respawn` rebuilds a QEMU process from the
configuration captured at create time, and an image-backed VM's spawn path used
to treat `VMSpec.volumes` as a *fallback* it never reached — so a hot-plugged
disk silently disappeared at the guest's next power cycle while the control
plane still called the volume attached.

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
snapshot that captured nothing, which is worse than refusing. `QGAClient` still
speaks `guest-fsfreeze-freeze`/`-thaw` for whoever implements the real live
snapshot — QMP `blockdev-snapshot-sync` (or `blockdev-backup`), which makes the
overlay the guest's active layer and needs the volume's `storagePath`, the VM
manifest, and snapshot deletion to follow the resulting backing chain.

### Full-VM checkpoints

Volume snapshots above are disk-only. A **checkpoint** (issue #564) captures
guest RAM, device state, and disks at one consistent point — the primitive
behind "save this VM and bring it back exactly as it was" — and lives at
`POST/GET/DELETE /api/vms/:id/snapshots` plus `.../restore`, in the
`vm_snapshots` table.

The mechanism is QEMU's `snapshot-save` / `snapshot-load` / `snapshot-delete`
background jobs, driven over each VM's dedicated QMP stats monitor by
`QMPProbeClient` and polled through `query-jobs` to `concluded`. The state goes
into an *internal* snapshot of the VM's own qcow2 disks, tagged
`strato-<snapshotId>`, so there is no separate state file to track: the agent
re-derives the tag from the ids on every call, which makes delete idempotent
and lets a retried checkpoint rejoin a job its first attempt started.

Consequences of "internal to the disks":

- **Every writable disk must be qcow2.** A writable raw volume would run on
  while the qcow2 disks were frozen, restoring to a machine whose memory and
  disks disagree, so the agent refuses the whole checkpoint rather than
  capturing part of it.
- **The UEFI variable store is excluded on purpose.** It is a raw pflash image
  and could not hold an internal snapshot anyway, but the exclusion is a
  decision: boot order and enrolled Secure Boot keys are firmware
  configuration, not guest run state, and refusing every UEFI VM over them
  would rule out nearly all of them.
- **Checkpoints do not move between hosts.** Restore is pinned to the agent
  that took it (`VMSnapshot.agentId`). Off-node export — either shared storage
  (#352/#353) or an object-storage copy like sandboxes got in #428 — is the
  follow-up.

Restore loads the state back into the VM's live QEMU process and resumes it.
The VM only has to *exist* on the agent, not be running: after an agent restart
the desired-state sync re-creates a stopped VM's process (its disks, and the
checkpoint inside them, never left the host) and the restore loads into that,
which is what makes checkpoint → stop → restart-agent → restore work with no
extra machinery.

Machine state is written to the VM's **boot disk**, not to whichever qcow2 disk
sorts first. A hot-plugged volume's QMP backend is anonymous, so a positional
rule picks it over the VM's own root disk — and then detaching that volume
silently makes a `ready` checkpoint unrestorable, while a volume clone quietly
carries a copy of the guest's RAM. Restore does not re-derive the choice: it
finds the vmstate node by the tag, so a checkpoint stays restorable across disk
hot-plug.

Quota counts only the machine state (`VMSnapshot.size`), not the disks — those
are already charged under the VM, and an internal snapshot does not copy them.

One operational consequence is worth knowing before running this at scale:
**a checkpoint holds the VM's QMP stats monitor for the whole job** (up to the
1200s agent budget). That monitor is single-client and is also where
balloon/guest-memory stats come from, so `memoryStats` returns nil for the
duration — and it swallows the failure, so the metrics gap looks like a guest
that stopped reporting rather than a self-inflicted hole.

A second one is *gone* as of STR-150 and worth recording as such. A checkpoint
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
  mutationId}`; the client polls the artifact's own `conditions`. A delete's
  success is the artifact's absence, so it polls the operations façade with
  `mutationId` instead — the rule everywhere else in ADR 0001.
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
  turn a quota into a suggestion. Volume snapshots draw on no pool and skip
  this.

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
  stuck-operation sweep releases any such row it still finds, which is what
  covers a replica still running an older build mid-rollout.

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
