# Distributed Storage (Proposed)

> **Status: design proposal, partially implemented.** The phase-1 data model
> (`StoragePool` + `VolumeReplica`, issue #349) has shipped. Nothing else in
> this document has. Current behavior is in [`storage.md`](./storage.md) —
> today every volume is host-local and pinned to a single agent.
>
> The choice of Ceph, and the reversal of the earlier ZFS + DRBD design, is
> recorded in [ADR 0002](../adr/0002-ceph-for-distributed-block-storage.md).
> Read that first for *why*; this document is *how*.

## Motivation

Volumes are files on one agent's local disk (`storage.md`, "Volume placement
across agents"). Three things are blocked by that:

- **Live migration.** A VM cannot move to another agent because its disk is
  not reachable from anywhere else. The `supportsLiveMigration` capability
  flag exists (`shared/Sources/StratoShared/HypervisorTypes.swift`) with no
  implementation behind it.
- **Durable snapshots.** Snapshots are local qcow2 overlays chained on the
  live volume; losing the agent loses the volume and every snapshot with it.
- **Stateful workloads on managed Kubernetes** (#626), where an agent-pinned
  PVC pins the pod to the agent for the life of the volume.

The fix is to make a volume reachable from every agent in its site. We do
that with Ceph: RBD images in a per-site cluster, placed by CRUSH rather
than by us.

## Shape: one cluster per site

```
Site "us-east-1a"
├── agent-1   storage controller   mon + mgr + osd × 4   ceph client
├── agent-2   cluster member       mon       + osd × 4   ceph client
├── agent-3   cluster member       mon       + osd × 4   ceph client
└── agent-4   client only                                ceph client
                    │
                    └── RBD pool "strato-<siteId>" ── volumes as RBD images
```

A `Site` is already the group of agents sharing a routable underlay and one
OVN deployment — the same boundary a storage fault domain wants. Clusters do
not span sites; cross-site replication (RBD mirroring) is deliberately out
of scope.

Two roles are separable, and separating them is what makes this shippable in
pieces:

- **Ceph client** — has `ceph.conf` and a keyring, runs no daemons, and can
  open RBD images. Every agent that hosts workloads on a Ceph pool needs
  this and nothing more.
- **Cluster member** — additionally runs mon/mgr/OSD daemons under cephadm.

An agent can be a client of a cluster it is not a member of, which is
exactly the bring-your-own-Ceph case: a site whose pool points at an
existing external cluster has clients and no members. The same client code
path serves both.

**Exactly one member per site is the storage controller**, holding the admin
keyring and the cephadm SSH key. This mirrors the existing per-site network
controller (`SiteNetworkAuthority`) — including its problems, which that
file has already solved once: auto-designating the first eligible member,
reporting a controller-less site as a loud API error instead of a silent
stall (#743), and handling a *standing* designation whose agent has since
gone away (#833). The storage designation should reuse that shape rather
than reinvent it.

## Data model (control plane)

Phase 1 already split the logical volume from its physical home. Ceph
extends that model rather than replacing it.

```
StoragePool  (modified)
  mode: { local, ceph }               // `replicated` REMOVED (see below)
  backing: { filesystem }             // `zfs` REMOVED (see below)
  memberAgentIds: [String]            // local pools only; ceph uses siteId
  siteId: UUID?                       // NEW — ceph pools are site-scoped
  cephClusterId: UUID?                // NEW
  cephPoolName: String?               // NEW — the RBD pool within the cluster
  cephNamespace: String?              // NEW — per-project RBD namespace

CephCluster  (NEW)
  id, siteId
  fsid: String
  managed: Bool                       // orchestrated by us, or external
  monEndpoints: [String]
  clientName: String                  // cephx identity, e.g. client.strato
  keyringSecretRef: String            // never the key itself
  storageControllerAgentId: String?
  health: { unknown, ok, warn, err }  // last observed
  capacityBytes, usedBytes, observedAt

StorageDevice  (NEW — physical inventory, see "Device inventory")
  id, agentId
  devicePath, sizeBytes, model, serial, rotational
  role:  { unassigned, osd, excluded }
  state: { available, inUse, draining, faulted }
  osdId: Int?
```

`VolumeReplica` **narrows to `local` pools**. A Ceph volume has no per-copy
placement for Strato to track — CRUSH owns that, and mirroring it into
Postgres would produce a second, always-stale copy of the cluster's own map.
Replica *health* for a Ceph pool is a cluster-level property (`CephCluster.health`),
not a per-volume one.

### What the phase-1 fields mean now

Three fields on `StoragePool` were shaped by the DRBD design and need
explicit dispositions, or phase-2 implementers will each guess differently:

- **`mode: replicated` is removed.** Nothing ever implemented it, and its
  `agentCanReach` branch ("any member agent reaches it") is true for Ceph
  and false for anything that exists — a selectable mode that silently
  misbehaves. Removal is not free: `mode` is a Fluent `@Enum` column, so it
  needs an `updateEnum().deleteCase("replicated")` migration and a check
  that no row carries it.
- **`backing: zfs` is removed** for the same reason and by the same
  argument — it exists solely to describe "ZFS datasets (replicated
  pools)". `filesystem` is the only backing a `local` pool has; a Ceph pool
  does not use the field at all.
- **`replicationFactor` is not authoritative for Ceph.** Durability is a
  property of the Ceph pool (`ceph osd pool get <pool> size`), set on the
  cluster, and mirroring it into `StoragePool` would create a second copy
  that drifts. Read it as *observed* onto `CephCluster`; on `StoragePool`
  it survives only as the `local`-pool constant 1, and should be removed
  along with `replicated` if nothing else reads it.
- **`memberAgentIds` stays, but does not gate Ceph pools.** For a `local`
  pool it is the eligibility list (empty = unrestricted). For a Ceph pool,
  `siteId` plus the Ceph-client capability decides, and `memberAgentIds` is
  not consulted.

### Naming, and the `storagePath` coupling

The volume's RBD image name follows the existing invariant that **the agent
owns naming**: the agent reports the image it created
(`<pool>/<namespace>/vol-<uuid>`) and the control plane stores and replays
that string verbatim. Delete still works from IDs alone.

But "no new column, we reuse the existing location field" understates the
coupling, and this is the sharpest piece of hidden work in phase 2:

- **`Volume.storagePath` is paired with `hypervisorId` at every reader.**
  `VolumeController` guards resize, snapshot, and clone with
  `guard volume.hypervisorId != nil, volume.storagePath != nil`
  (`VolumeController.swift:591`, `:656`, `:753`). For a Ceph volume
  `hypervisorId` is meaningless — un-pinning it is the entire point — so
  either those guards relax to pool-aware reachability, or a synthetic
  agent id gets written just to satisfy them. Relax them.
- **`VolumeSpec.storagePath` is documented on the wire as "Host path of the
  volume as previously reported by the owning agent"**
  (`shared/Sources/StratoShared/VMSpec.swift:203`). Putting a `pool/image`
  string in it makes `pool.mode` the only discriminator between two
  incompatible meanings of one field — exactly the untyped-path problem the
  sum-type refactor below exists to delete. **The typed attachment should
  carry the RBD coordinates end to end** rather than smuggling them through
  a path-shaped field.

`StoragePool.agentCanReach` gains its third case: for `.ceph`, an agent
reaches the pool if it is a configured client of the pool's cluster —
membership in the site plus the Ceph-client capability. This is the entire
"placement" story for Ceph volumes.

## Data path (compute node)

```
guest ── virtio-blk ── QEMU ── librbd ──┐
                                        │  (network)
guest ── virtio-blk ── Firecracker ─────┤
                       /dev/rbdN (krbd) │
                                        ▼
                             Ceph OSDs across the site
```

- **QEMU** opens the image natively: `blockdev-add` with `driver=rbd`,
  carrying pool, image, cephx user and auth mode. No local file, no host
  path. This reuses the existing hot-plug path
  (`QEMUService.attachDisk`/`detachDisk`) — it is a change to *what* is
  attached, not a new hypervisor driver.
- **Firecracker** has no librbd, so the agent maps the image with krbd
  (`rbd map` → `/dev/rbdN`) and hands Firecracker the resulting block
  device. The kernel RBD client lags librbd on features, and a `map` of an
  image using an unsupported one fails outright, so images that may be
  mapped must pin their feature set at create time rather than inheriting
  the cluster default. Concretely: enable `layering` and `exclusive-lock`
  (kernel ≥ 4.9); disable `object-map`, `fast-diff`, `deep-flatten`, and
  `journaling`, none of which krbd supports.
- **`exclusive-lock` matters for correctness**, not just features: it is
  what prevents two hosts from writing the same image, and its cooperative
  hand-off is what makes live migration safe. Enable it for QEMU images.

## `StorageBackend` and disk attachments as a sum type

> Named carefully: [`storage.md`](./storage.md) already has a "Typed disk
> attachments" section describing the *shipped* `DiskAttachment` (host path
> + `DiskFormat`) as the typed attachment. This section is about turning
> that struct into a sum type, which is a different change.

The agent-side protocol (`agent/Sources/StratoAgentCore/StorageBackend.swift`)
survives largely intact — create, delete, resize, snapshot, clone, and info
all map onto `rbd` operations more directly than they map onto qemu-img. The
part that breaks is `DiskAttachment`, which is a **host path plus format**.
An RBD disk has no path.

So `DiskAttachment` becomes a typed value, exactly as NICs already did when
`NetworkAttachment` replaced an assumed TAP path:

```swift
enum DiskAttachment {
    case file(path: String, format: DiskFormat)      // today
    case blockDevice(path: String)                    // krbd, LVM later
    case rbd(pool: String, image: String, user: String, monHosts: [String])
}
```

Hypervisor drivers switch on it instead of opening a path. This refactor is
worth doing **first and on its own**, against today's filesystem backend
with no Ceph in sight: it is the change that touches the most existing code,
it needs a wire-protocol version bump and capability gating (the
`volume_snapshot_delete` precedent), and it de-risks everything after it.

`CephRBDStorageBackend` then implements the protocol against `rbd`, and
registers in the agent's driver registry alongside `FileSystemStorageBackend`
the way hypervisor drivers do — one registration, no new switch sites.

## Deployment: cephadm under our reconciler

cephadm is itself declarative and level-triggered: `ceph orch apply -i <spec>`
states what should run where, and cephadm converges. That is the same
contract as our own reconciler, so the two nest cleanly:

```
control plane            desired state              storage controller
(what the fleet          ──────────────►            agent
 should look like)        DesiredStorageState        │
                                                     ├─ cephadm bootstrap (once)
                                                     ├─ ceph orch host add
                                                     ├─ ceph orch apply -i spec
                          ◄──────────────            └─ ceph -s / orch ls
                          ObservedStorageState
```

The control plane renders service specs from its own model — which agents
are mons, which `StorageDevice` rows are OSDs — and never runs Ceph commands
itself. The storage controller applies them. Nothing requires the control
plane to reach into a site.

### Bootstrap and host enrollment

1. The control plane designates a storage controller and sends it a desired
   state saying "bootstrap a cluster for this site."
2. The agent runs `cephadm bootstrap --mon-ip <underlay IP>`, which creates
   the first mon and mgr, writes `/etc/ceph/ceph.conf` and the admin
   keyring, and generates an SSH key pair whose public half is
   `/etc/ceph/ceph.pub`.
3. The agent reports the fsid, mon endpoint, and `ceph.pub` back as observed
   state. The control plane records the `CephCluster` row.
4. Every other member agent receives `ceph.pub` in its next desired-state
   sync and installs it into root's `authorized_keys`. This is the
   intra-site trust path ADR 0002 calls out: agents authorize each other,
   and the control plane distributes the key but never holds an SSH session.
5. The controller runs `ceph orch host add <host> <ip>` for each member that
   has confirmed key installation, then applies mon/mgr/OSD specs.

Members must satisfy cephadm's host requirements — systemd, podman or
docker, LVM2, python3, and working time sync. These belong in the existing
`HostPreflight` checks, reported as capability, so a site cannot be
configured for Ceph on hosts that cannot run it.

### Device inventory

Strato has no model of an agent's physical disks today, and Ceph needs one.
Agents report block devices (path, size, model, serial, rotational, whether
already in use); operators mark which are Ceph-eligible; the control plane
renders an OSD service spec from the marked set. Serial-keyed identity
matters — device paths are not stable across reboots, and an OSD spec that
follows `/dev/sdb` onto a different physical disk is a data-loss bug.

### Day two

The parts that are easy to leave out of a design and impossible to leave out
of an operable system:

- **Disk replacement** — `ceph orch osd rm <id> --replace` keeps the OSD ID
  reserved for the new disk; the `StorageDevice` row moves to `faulted` and
  its replacement to `osd`.
- **Node decommission** — `ceph orch host drain <host>` before a site
  removes an agent, and `Site.status = draining` should stop OSD growth.
- **Near-full** — Ceph stops accepting writes at `full_ratio`. The control
  plane should surface it and refuse new volume placement well before then,
  rather than letting a create fail at the agent.
- **Upgrades** — `ceph orch upgrade start --image <version>` is staged and
  resumable; cluster version belongs alongside the existing agent
  auto-update story (`agent-updates.md`).

## Security boundaries

Three of these are decisions that are cheap now and expensive later, so
they belong in the design rather than in an implementation's judgement.

**Tenant isolation: one namespace per project, decided up front.** The
naive shape — one RBD pool and one `client.strato` identity per site —
hands every client agent a key that reads and writes every volume in the
site, across projects and organizations. That is *worse* than today, where
a compromised agent reaches only the volumes it physically hosts. The
mitigation is RBD namespaces with per-project cephx users
(`profile rbd pool=<pool> namespace=<project>`), which is why
`StoragePool.cephNamespace` appears in the data model above. **An image's
namespace is fixed when it is created**, so retrofitting means migrating
every image — this cannot be a follow-up.

**Keyring storage.** `CephCluster.keyringSecretRef` is written above as a
reference rather than a key, but Strato has no secret-reference
indirection today (the nearest comparable secret, `OIDCProvider.clientSecret`,
is a plain column). Either build the indirection or store the key and say
so; a `…SecretRef` field name that dereferences to a plain column is worse
than an honest one.

**Wire encryption.** Volume I/O currently never leaves the host. After
this it crosses the site underlay, which SPIFFE does not cover — agent
mTLS secures the control channel, not RADOS traffic. Enable msgr2 `secure`
mode at bootstrap and separate the public network from the cluster
network; both are far cheaper to set at bootstrap than to retrofit onto a
cluster carrying data.

**Quota is not capacity.** `QuotaUsageAggregator` sums *provisioned* bytes
and `QuotaEnforcementService` admits creates against that total. RBD
clones consume only their own writes, so a project can sit at quota while
using nearly nothing; and near-full is a cluster-wide property spanning
every project in the site, so a site can refuse writes while every project
is under quota. Keep charging provisioned bytes — it is the predictable
number for tenants — but treat cluster capacity as a separate admission
check rather than assuming quota implies headroom.

## What the existing orchestration seams do now

**Scheduler: almost nothing.** The DRBD design needed
`selectAndReserveAgent` generalized to select N distinct agents with
anti-affinity. With Ceph that requirement disappears entirely — CRUSH places
data, and volume "placement" collapses to `agentCanReach`. The scheduler
keeps doing compute placement and gains only a "can this agent reach the
pool the VM's volumes live in" filter.

**Desired state: a storage channel alongside the VM one.** Mirroring
`DesiredVMState`, generation-guarded and level-triggered:

```swift
struct DesiredStorageState {
    let siteId: UUID
    let role: { none, client, member, controller }
    let cluster: CephClusterConfig?   // fsid, mons, client keyring ref
    let sshPublicKey: String?         // for members, to authorize
    let serviceSpecs: [CephServiceSpec]?   // controller only
    let generation: Int64
}
```

Note what this *does not* carry: per-volume region state. The DRBD design
needed `DesiredRegionState` per volume because Strato owned replica
placement. Here the desired state describes **daemon roles and cluster
shape** — a substantially smaller reconciler surface than the DRBD design
needed. Per-*volume* desired state is not this document's invention: it
arrives with the declarative volume migration
([ADR 0001](../adr/0001-declarative-agent-protocol.md), stage 5), and a
Ceph volume is simply a desired volume entry whose pool resolves to an RBD
image.

**Progress reporting: conditions, not an operations side-table.** Cluster
bootstrap, OSD provisioning, and backfill are slow, and the instinct is to
give them rows in an operations side-table. ADR 0001 deleted that table
(STR-152), so the correct home is the one every other resource uses:
`generation` / `observedGeneration` / `convergencePhase` / `lastError` on the
cluster resource, projected as a conditions block, with the
stuck-*convergence* sweep flipping `degraded` past budget.

This is the sharpest sequencing constraint in the whole roadmap, so it is
worth stating plainly: **anything here that touches the volume wire messages
is touching messages ADR 0001 is converting.** Typed disk attachments
(phase 1) change what an attachment *is*, which is orthogonal to how it is
delivered — that work is safe in either order, and doing it first simply
means the declarative conversion carries a richer type. The Ceph *control-plane*
volume lifecycle is not orthogonal: building it against the imperative
`volume_*` RPCs would be building on messages scheduled for deletion. Prefer
landing the declarative volume conversion first; if Ceph must move sooner,
scope it to the agent-side backend and accept the conversion cost knowingly
rather than by accident.

## Images on RBD

Ceph changes the image path for the better. Instead of every agent
downloading and copying an image per VM:

1. Import the image once into the site's RBD pool as a base image.
2. Snapshot it and `rbd snap protect` the snapshot.
3. Every VM boot disk is `rbd clone` of that snapshot — instant, COW,
   consuming only its own writes.

That removes the per-agent `ImageCacheService` copy from VM create on Ceph
pools, and makes create latency independent of image size. The existing
cache stays for `local` pools and for Firecracker artifacts that are not
disk images (kernel, initramfs).

Two consequences to design for: a protected base snapshot cannot be deleted
while clones exist (image deletion must either refuse or `rbd flatten` the
children), and the import needs somewhere to run — the storage controller is
the natural place, driven by the same grant-scoped download route agents
already use (`storage.md`, "Why agents still fetch through the control
plane").

Separately, and independently of the block work: Ceph RGW speaks S3, so it
can back `ImageObjectStore`'s existing `s3` mode with no code change.

## Snapshots and backup

RBD snapshots are instant, cheap, and — unlike qcow2 overlays — safe on an
**attached** image. That lifts the detached-only restriction (#747) for Ceph
pools; the restriction was never about snapshots being hard, it was about
the overlay reading through to a base the guest kept writing.

What follows:

- **Snapshot** — `rbd snap create`, per volume, no overlay chain.
- **Clone** — `rbd clone` from a protected snapshot, instant, replacing the
  `qemu-img convert` that requires a quiesced source (`canClone`).
- **Restore** — `rbd snap rollback`, which finally gives the modeled-but-
  unimplemented `.restoring` status an agent operation behind it (#352).
- **Off-node backup** — `rbd export-diff` / `import-diff` to S3-compatible
  storage, incremental after the first full export. This closes the "the
  agent dies and its snapshots die with it" gap for good.

Full-VM **checkpoints** (`storage.md`, "Full-VM checkpoints") are a separate
mechanism and stay QEMU-internal for now. They are pinned to the agent that
took them because the machine state lives inside the VM's own qcow2 disks;
on RBD there is no qcow2 layer to hold an internal snapshot, so checkpoints
on Ceph pools need a different home for vmstate. That is a real gap to close
before Ceph pools can be the default, not a detail.

## Live migration

With volumes reachable from any client in the site, migration is a
compute-side problem:

1. Scheduler picks a target agent that reaches the volume's pool.
2. QEMU on the target opens the *same* RBD image; the `exclusive-lock`
   hand-off, not a storage operation, is what serializes the writers. There
   is no detach/attach dance and no data movement.
3. QEMU streams RAM and device state over QMP, gated on the existing
   `supportsLiveMigration` flag.
4. The OVN logical switch port and `VMNetworkInterface` binding move to the
   target.
5. VM ownership moves in the agent manifest; the reconciler converges on
   both sides, generation guards preventing flap.

This is materially simpler than the DRBD version, which needed a primary
role to migrate between hosts in step with the guest.

## Phasing

Each phase is independently useful. The ordering principle is that the
**client path and the orchestration path are separable**, and the client
path is where all the value is.

1. **Disk attachments as a sum type.** Replace the path-carrying
   `DiskAttachment`, thread it through the hypervisor drivers and volume
   wire messages, bump the wire version with capability gating. Pure
   refactor, no Ceph.
2. **Bring-your-own-Ceph client path.** `StoragePool.ceph` + `CephCluster`
   pointing at an existing cluster; `CephRBDStorageBackend`; QEMU `rbd`
   blockdev; agent advertises the Ceph-client capability; per-project RBD
   namespaces and the relaxed `hypervisorId`/`storagePath` guards.
   **Volumes stop being agent-pinned here** — this alone unblocks #353 and
   #626.
3. **Device inventory.** `StorageDevice` reporting and operator marking.
   Prerequisite for anything orchestrated.
4. **Orchestrated cluster per site.** Storage-controller designation,
   cephadm bootstrap, key distribution, host add, mon/OSD service specs,
   health and capacity surfaced in the API and UI, plus the day-two
   operations above.
5. **RBD-native images and snapshots.** Base image + protected snapshot +
   COW clone boot disks; snapshots on attached volumes; restore; export to
   object storage.
6. **Live migration** (#353), then the Kubernetes CSI driver (#626).

## Non-goals and cost

- **Cross-site replication** (RBD mirroring) is out of scope. It is the
  natural DR follow-up; decide it separately.
- **The `local` pool stays the default and stays supported.** Sites below
  roughly three nodes with real disks cannot run Ceph well, and that is a
  permanent product boundary rather than a gap to close.
- **macOS agents stay local.** Firecracker is included via krbd; macOS is
  not.
- This is a quarters-not-weeks effort, and phase 4 hands us an ongoing
  operational surface (see ADR 0002, "What this costs"). Phases 1–2 deliver
  most of the user-visible value and none of that burden, which is why they
  come first.
