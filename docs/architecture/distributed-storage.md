# Distributed Storage (Proposed)

> **Status: design proposal, not implemented.** This document describes a
> target architecture for replicated block storage and the incremental path
> to it. Current behavior is in [`storage.md`](./storage.md); today every
> volume is host-local and pinned to a single agent. Nothing here ships yet.

## Motivation

Volumes are currently files on one agent's local disk (`storage.md`,
"Volume placement across agents"). Two capabilities we want are blocked by
that single assumption:

- **Live migration.** A VM can't move to another agent because its disk
  isn't reachable from anywhere else. The `supportsLiveMigration` capability
  flag exists (`shared/Sources/StratoShared/HypervisorTypes.swift`) but has
  no implementation behind it.
- **Durable, exportable snapshots and no-single-point-of-failure storage.**
  Snapshots are local qcow2 overlays chained on the live volume; losing the
  agent loses the volume and every snapshot with it.

The reference design most relevant to us is Oxide's **Crucible**: ZFS stays
*local* to each node, and replication is done by a client that writes to N
independent per-node block servers — not by a distributed cluster daemon
(no Ceph-style MON/OSD consensus, no LINSTOR controller). That shape maps
onto our existing driver-registry / reconciler / scheduler seams with mostly
control-plane work. See the discussion in `storage.md` "Future work" for the
lighter-weight alternatives (NFS, single-node ZFS) that trade HA for
simplicity.

## The core decision: who does replication

Crucible's hard part is its **upstairs** — a correct N-way replicating block
client with quorum writes, crash consistency, and *live repair* of a stale
replica. Two ways to get it:

- **Variant A — build the client.** Truly Crucible-shaped; we own a
  replicating daemon. Maximum control, and we take on Crucible's hardest
  correctness problems ourselves.
- **Variant B — DRBD does replication + repair.** DRBD (in-kernel,
  ~20 years mature) provides synchronous N-way replication and automatic
  resync of a returned/replaced replica, exposing a normal block device.
  We build the control plane and lifecycle, not the consensus.

**The control-plane design below is identical for both variants** —
placement, data model, reconciler wiring, snapshot lifecycle, and live
migration don't change. Only the agent-side data path differs. **Variant B
is recommended**: the valuable-and-hard part (the control plane) is what we
build either way and what fits our seams; the hard-and-commodity part
(synchronous replication with live resync) is already solved in-kernel.

DRBD is Linux-only, which is fine — the replicated path is QEMU/Linux-only
regardless, and macOS stays on the local pool.

## Data model (control plane)

Today `Volume` conflates the logical volume with its single physical home
(`hypervisorId` + `storagePath`). Split them:

```
StoragePool
  id, name
  mode: { local, replicated }        // local = today's FileSystemStorageBackend
  replicationFactor: Int             // e.g. 3 for replicated
  memberAgentIds: [String]           // agents eligible to host regions
  backing: { zfs, filesystem }

Volume  (modified)
  ...existing fields...
  poolId: UUID                       // NEW
  attachedAgentId: String?           // NEW — where the attachment currently runs
                                     //       (replaces hypervisorId as "single owner")

VolumeReplica  (NEW — the "region")
  id, volumeId
  agentId: String                    // node holding this copy
  datasetPath: String                // agent-owned, e.g. tank/strato/vol-<id>
  state: { provisioning, healthy, degraded, resyncing, faulted }
  generation: Int64                  // reuse the reconciler's generation idiom
```

A replicated volume becomes **one `Volume` + N `VolumeReplica` rows on N
distinct agents**. `VolumeSnapshot` stays but becomes pool-native: a ZFS
snapshot taken on every replica's dataset, tracked per-replica so
consistency can be reasoned about.

This is the change that unlocks everything else: a volume is no longer
pinned to one agent, so the same-hypervisor attach guard in
`VolumeController` relaxes to "can the VM's agent reach this pool's
replicas" — for a replicated pool, any member agent.

## Data path (compute node)

QEMU needs one block device that fans out to N replicas:

```
guest ── virtio-blk ── QEMU
                        │  blockdev: vhost-user-blk (preferred) or nbd
                        ▼
             ┌──────────────────────────┐
             │  attachment (upstairs)    │   per attached volume
             └───────────┬──────────────┘
             writes → all N replicas, reads ← one
        ┌────────────────┼────────────────┐
        ▼                ▼                ▼
   region server    region server    region server   (downstairs)
   agent A          agent B          agent C
   ZFS dataset      ZFS dataset      ZFS dataset
```

- **Variant A:** the attachment process is our replicating client; region
  servers are our daemon over ZFS datasets.
- **Variant B:** region servers are DRBD on each agent (one resource per
  replica, backed by a ZFS zvol). The attachment layer collapses — DRBD is
  the replication; QEMU opens the resulting `/dev/drbdN` via `blockdev`. No
  custom data-path code.

Either way, QEMU integration reuses the existing `blockdev-add` hot-plug
path (`QEMUService.attachDisk`/`detachDisk`) — the disk handed to QEMU is
network-backed instead of a local file. This is a change to attach/detach,
not a new hypervisor driver.

## `StorageBackend` protocol split

The current protocol is single-node. Split it along the Crucible seam:

```swift
// Region lifecycle — every agent holding a replica ("downstairs")
protocol RegionBackend: Actor {
    func createRegion(volumeId:, sizeBytes:, format:) async throws -> RegionInfo
    func deleteRegion(volumeId:) async throws
    func snapshotRegion(volumeId:, snapshotId:) async throws -> String
    func regionInfo(volumeId:) async throws -> VolumeInfoResult
    // Variant A: serve(volumeId:)          — expose region over the wire
    // Variant B: drbdConfigure(volumeId:, peers:) — write .res, drbdadm up
}

// Attachment — the compute agent hosting the VM ("upstairs")
protocol VolumeAttachmentBackend: Actor {
    func attach(volume: VolumeTopology) async throws -> DiskAttachment
    func detach(volumeId:) async throws
}
```

`FileSystemStorageBackend` becomes the `local`-pool (single-replica)
implementation; a new `ZFSRegionBackend` (+ `DRBDAttachmentBackend` for
Variant B) implements `replicated`. Both register in the agent's driver
registry (`agent/Sources/StratoAgent/Agent.swift`) exactly like the
hypervisor drivers — one registration, no new switch sites.

## Orchestration — reuse the three existing seams

### Placement (scheduler)

`SchedulerService.selectAndReserveAgent` already picks one agent with Valkey
reservations. Generalize to **select-and-reserve N distinct agents** for a
replicated volume: the same `SchedulableAgent` / `ReservationAmounts`
machinery, invoked N times with an anti-affinity filter (no two replicas per
agent; later, rack/fault-domain awareness via a `SchedulableAgent` label).
The existing Valkey reservation pattern already prevents double-booking
across control-plane replicas, so this is an extension, not a rewrite. See
[`scheduler.md`](./scheduler.md).

### Storage desired state (reconciler)

The reconciler already sends agents an authoritative, generation-guarded
`DesiredStateMessage` and receives `ObservedStateReport`
(`shared/Sources/StratoShared/ReconciliationProtocol.swift`). Add a parallel
storage channel with the identical shape:

```swift
struct DesiredRegionState {          // mirrors DesiredVMState
    let volumeId: UUID
    let role: { replica, attachment }
    let topology: [ReplicaEndpoint]  // for attachment: the peer set
    let desired: { present, absent, snapshot(id) }
    let generation: Int64
}
```

The agent-side reconciler
(`agent/Sources/StratoAgentCore/Reconciliation.swift`) diffs observed vs
desired regions and converges on its per-volume serial lane, same as VMs.
Because syncs are level-triggered and generation-guarded, **replica repair
falls out for free**: when agent C dies, the control plane marks its replica
`faulted`, the scheduler picks a replacement agent D, and D's next sync says
"you hold a replica of volume X" → the reconciler provisions the dataset and
(Variant B) `drbdadm`'s it up; DRBD resyncs from the survivors. We describe
desired topology; convergence is the loop we already have.

### Async operation tracking

Region provisioning and resync are slow, so they ride the existing
`ResourceOperation` → 202-Accepted pattern (a new `resource_kind`). The
frontend polls to terminal state exactly as for VM operations.

## Live migration falls out

Once a volume isn't pinned to a node, migration is almost a compute-only
problem:

1. Scheduler picks target agent T (able to reach the volume's replicas —
   trivially true for a replicated pool).
2. Detach-prepare on the source; hand the same `VolumeTopology` to T's
   attachment backend so QEMU on T opens the same replicated device.
3. QEMU live migration streams RAM + device state (gate on the existing
   `supportsLiveMigration` capability).
4. Move the OVN port / `VMNetworkInterface` to T (NICs are already modeled
   as rows — see `overview.md` networking).
5. Reassign VM ownership in the agent manifest; the reconciler converges on
   both sides.

The storage doesn't move — only the attachment endpoint does.

## Phasing

Each phase is independently useful and shippable.

1. **Data model + pool abstraction** (`StoragePool`, `VolumeReplica`,
   decouple `hypervisorId`), with a `local` pool wrapping today's backend
   unchanged. Pure refactor, no behavior change — de-risks everything after.
2. **ZFS single-replica** replicated pool (RF=1) — proves region/dataset
   lifecycle and the `blockdev` plumbing without replication.
3. **Replication** — Variant B: DRBD region backend + N-agent placement +
   repair reconciliation.
4. **Pool-native snapshots** + off-node export to object storage
   (Garage/MinIO) — closes the backup gap.
5. **Live migration** — the compute-side orchestration above.

## Cost and non-goals

- This is a quarters-not-weeks effort; the `local` pool stays the default so
  nothing regresses while it is built.
- The replicated path is Linux/QEMU-only. macOS and Firecracker remain on
  the local pool.
- Object storage (images, snapshot export) is complementary but out of scope
  here; it is largely independent of the block-replication work.
- We deliberately do **not** build a distributed cluster daemon or adopt
  Ceph. Replication is either DRBD (recommended) or a purpose-built client;
  placement and repair live in the control plane we already have.
