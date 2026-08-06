# ADR 0002: Ceph/RBD for distributed block storage

- **Status**: Accepted
- **Date**: 2026-08-05
- **Deciders**: Sam Schmitt
- **Scope**: agent-side storage backend, volume placement, per-site cluster
  deployment
- **Supersedes**: the ZFS + DRBD design; that design previously occupied
  [`docs/architecture/distributed-storage.md`](../architecture/distributed-storage.md),
  which now carries the Ceph design instead.
- **Builds on**: [ADR 0001](./0001-declarative-agent-protocol.md) — storage
  daemon roles and volume lifecycle are expressed as desired state under the
  durable-noun rule, not as imperative RPCs or `ResourceOperation` rows.
  ADR 0001 is now `Accepted` (early stages have landed), so that dependency
  is settled: everything here is sequenced against its migration plan, and
  cluster progress gets a conditions/`resource_events` home rather than an
  operations-table one.
- **Affects**: STR-9 (roadmap umbrella), STR-10, STR-11, STR-12, STR-13,
  STR-31

## Summary

Replace the per-volume DRBD mirror with a Ceph cluster per `Site`, using RBD
as the volume data path and cephadm for deployment. Volumes stop being
pinned to an agent, which is the precondition for live migration and for
stateful workloads on managed Kubernetes. Agents split into Ceph *clients*
and cluster *members*, so pointing a site at an existing external cluster
ships before any orchestration exists. The `local` pool remains the default
and stays supported indefinitely; sites below roughly three nodes with real
disks keep it permanently.

## Context

Volumes are files on one agent's local disk. A volume cannot outlive its
agent, cannot be reached from another agent, and takes every snapshot with
it when the node dies. That single assumption blocks live migration (#353),
durable snapshots (#352), and credible stateful workloads on managed
Kubernetes (#626).

The original design (issue #347, phases #348–#353) took its shape from
Oxide's Crucible: ZFS stays local to each node and replication is done by a
client writing to N independent per-node block servers, with DRBD supplying
the actual replication and resync. It explicitly ruled out "a distributed
cluster daemon" and named Ceph as a non-goal. Phase 1 (#349) shipped — the
`StoragePool` / `VolumeReplica` data model that decouples a volume from a
single agent — and nothing after it was built.

The reason to revisit is that DRBD's replication topology is **per-volume
and static**. Each volume is a fixed N-node mirror chosen at create time,
and that has consequences that do not improve with implementation effort:

- **Capacity is trapped in node sets.** Free space on node D is unusable by
  a volume whose replicas are on A/B/C, so the fleet fills unevenly and the
  effective capacity is the worst-placed subset, not the sum.
- **Adding a node does nothing for existing data.** New capacity only helps
  volumes created after it joins; there is no rebalance short of moving
  whole volumes.
- **Repair granularity is the whole volume.** Replacing a replica resyncs
  every byte of it from a survivor, at volume granularity, onto one target
  node — so recovery time scales with the largest volume and concentrates
  load on single peers.
- **Heterogeneous fleets are awkward.** Anti-affinity placement over nodes
  of differing disk sizes needs a bin-packer in our scheduler that we would
  have to write, tune, and keep correct across repair.

The peer-count ceiling that prompted the review is real but secondary; the
per-volume topology is the part that does not scale. LINSTOR would have
inherited the same model, so changing orchestrators would not have helped.

Ceph inverts this: placement is a property of the **cluster**, computed by
CRUSH over placement groups, so capacity is pooled, rebalance is
incremental and parallel across all peers, and repair is per-object rather
than per-volume. The control plane stops making placement decisions it is
not well-positioned to make.

## Decision

**Adopt Ceph as the distributed block storage backend, one cluster per
site, with RBD as the volume data path and cephadm as the deployment
mechanism.**

Specifically:

1. **One Ceph cluster per `Site`.** A site is already the OVN blast radius
   and the group of agents sharing a routable underlay; that is the correct
   boundary for a storage fault domain too. Clusters do not span sites.
2. **RBD images are volumes.** A volume in a Ceph pool is an RBD image;
   QEMU opens it with the native `rbd` block driver, and Firecracker maps it
   with krbd. There is no per-agent copy and no host path.
3. **cephadm deploys and manages the cluster.** One agent per site is
   designated the **storage controller** and runs `cephadm bootstrap`; the
   control plane drives the cluster by rendering declarative `ceph orch`
   service specs and applying them through that agent. Strato's reconciler
   sits above cephadm's, which is itself level-triggered and idempotent.
4. **The `local` pool remains the default** and stays supported
   indefinitely. Ceph is opt-in per site.
5. **`StoragePool` gains a `ceph` mode, and loses its unimplemented ones.**
   The phase-1 model survives, but the fields that only ever described the
   DRBD design go with it: mode becomes `{ local, ceph }`, the `replicated`
   case and the `zfs` backing are removed, and `VolumeReplica` narrows to
   `local` pools because a Ceph volume has no per-copy placement for Strato
   to track. Leaving `replicated` in place would leave a selectable mode
   whose reachability rule is true for Ceph and false for anything that
   exists.
6. **Bring-your-own-Ceph is a first-class configuration**, not a
   compatibility afterthought: pointing a site's pool at an existing
   external cluster uses the same client path as an orchestrated one.
7. **Tenant isolation is a cephx design decision made up front, not
   later.** One pool and one `client.strato` identity per site would give
   every client agent a key that reads and writes every volume in the site,
   across every project and organization. RBD namespaces with per-project
   cephx users (`profile rbd namespace=…`) are the mitigation, and the
   namespace is fixed when an image is created — so deferring this means
   migrating every image later. See "What this costs".
8. **Storage controller and network controller are designated
   independently, and may be the same agent.** On a single- or dual-node
   site they inevitably will be. They are separate designations because
   their eligibility bars differ (OVN authorship vs cephadm plus a
   container runtime), and where a site has two eligible members they
   should prefer different nodes, since co-location concentrates two
   admin-grade credentials on one host.

## Consequences

### What this buys

- Capacity pools across a site; adding a node rebalances existing data.
- Repair is per-object, parallel across all surviving OSDs, and does not
  concentrate on one replacement peer.
- **Volumes stop being agent-pinned within a site**, which is the single
  precondition for live migration (#353) and for the good answer in the
  Kubernetes CSI driver (#626).
- Snapshots become instant and work on *attached* images, so the
  detached-only restriction (#747) can lift for Ceph pools; clone becomes a
  COW clone from a protected snapshot instead of a `qemu-img convert`; and
  `rbd export-diff` gives incremental off-node backup (#352).
- Boot disks can be COW clones of a base image, removing the per-agent
  image copy from VM create on Ceph pools.
- Firecracker is included via krbd rather than excluded, as it was under
  the DRBD design.
- RGW and CephFS become available later at no additional deployment cost —
  RGW can back `ImageObjectStore`'s existing `s3` mode directly.

### What this costs

- **We are now operating a Ceph cluster on the user's behalf**, including
  upgrades, near-full handling, rebalance storms, and OSD replacement. This
  is a permanent operational surface, not a one-time build.
- **A practical floor of three nodes with real disks per site**, plus the
  memory (roughly 4 GiB per OSD) and network (10 GbE strongly preferred)
  that Ceph expects. Small and single-node sites stay on the `local` pool
  permanently — this is a real product boundary, not a temporary gap.
- **cephadm requires root SSH between agents in a site.** The bootstrap
  host's mgr reaches the others; agents distribute the generated `ceph.pub`
  among themselves. This keeps Strato's property that the control plane
  needs no inbound reachability into a site, but it does add an intra-site
  trust path and a key to manage.
- **Agents need a container runtime and root.** cephadm runs every daemon
  as a podman/docker container under systemd.
- **The storage controller holds the cluster admin keyring**, making it a
  higher-value target than an ordinary hypervisor node.
- Ceph's cephx is a second authentication system alongside SPIFFE/SPIRE.
  They do not federate; keyrings are secrets the control plane distributes.
  Strato has **no secret-reference indirection today** — the closest
  comparable secret, `OIDCProvider.clientSecret`, is a plain column — so
  "the control plane stores a reference, never the key" is a property that
  has to be built, not one that can be assumed.
- **A per-agent key widens the blast radius of a compromised node.** Today
  an agent can reach only the volumes it physically hosts. With one pool
  and one cephx identity per site, any client agent's key reads and writes
  *every volume in that site*, across projects and organizations — a
  strictly worse position than the design replaces. RBD namespaces plus
  per-project cephx users (`profile rbd namespace=…`) close it, and because
  an image's namespace is fixed at create time, this has to be decided
  before the first volume is created rather than retrofitted.
- **Volume I/O moves onto the underlay, and that traffic is outside
  SPIFFE's coverage.** Today it never leaves the host. Ceph's msgr2
  `secure` mode (and separating the public from the cluster network) is the
  answer, and it is far cheaper to turn on at bootstrap than to retrofit
  onto a running cluster.
- **Quota and actual consumption stop tracking each other in both
  directions.** `QuotaUsageAggregator` sums *provisioned* volume, snapshot,
  and checkpoint bytes, and `QuotaEnforcementService` admits creates
  against that total. RBD clones consume only their own writes, so a
  project can be at quota while using almost nothing; conversely Ceph's
  near-full is a cluster-wide property cutting across every project in the
  site, so a site can be unable to accept writes while every project is
  under quota.

### What we give up from the DRBD design

In-kernel simplicity with no extra daemons, and a replicated path that
works at two nodes. Both were genuine advantages of the previous design and
neither survives this decision.

## Alternatives considered

- **DRBD (the previous decision), and LINSTOR as an orchestrator for it** —
  rejected for the per-volume static topology described above, which
  LINSTOR shares.
- **Build the Crucible-style replicating client (Variant A of the old
  design)** — rejected before and still rejected: quorum writes, crash
  consistency, and live repair of a stale replica are the hardest
  correctness problems in the system, and owning them buys nothing over
  adopting a mature implementation.
- **Longhorn** — Kubernetes-only; Strato agents are not Kubernetes nodes.
- **Mayastor / SPDK-based stacks** — closer to Crucible's model, with the
  same per-volume topology limitation and a much smaller operational track
  record than Ceph.
- **NFS or a single shared ZFS box** — the volume stops being agent-pinned,
  which would unblock migration, but the storage server becomes the single
  point of failure the whole exercise exists to remove.

## Scope boundaries

- **Cross-site replication (RBD mirroring) is out of scope** for this
  roadmap. It is the natural DR follow-up and should be decided separately.
- **macOS agents stay on the `local` pool.** Ceph clients are Linux-only in
  practice, and macOS agents are already dev/test-only for networking.
- Object storage as a product (RGW, CephFS) is enabled by this decision but
  not part of it.
