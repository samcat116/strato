# Domain context

Ubiquitous language for Strato's control plane. Terms here are the names we
use in code, tests, docs, and review. Architecture-level maps live in
`docs/architecture/`; this file pins the vocabulary those maps assume.

## Tenancy

- **Project** — the unit every resource belongs to, and the node authorization
  hangs from. **Every create names its project**; there is no default and
  nothing infers one. An organization is provisioned with a first project so it
  is not empty, but that project is not privileged — it is the first row, and
  organizations accumulate more.

  "Default Project" is only an initial display name and UI convenience. It has
  no resolution semantics.

## Resource mutations

- **Resource mutation** — one durable, asynchronous lifecycle change to a VM,
  sandbox or volume (create / start / stop / restart / pause / resume / delete /
  resize / snapshot …). Mutation endpoints return **202 Accepted** with
  `{resource, targetGeneration, mutationId}`; the client refetches the resource
  and reads its **conditions**. The `resource_kind` discriminator
  (`OperationResourceKind`) keys the per-kind behavior — one enum, not a fork
  per resource.

- **Accept** — the atomic first half of a mutation, `ResourceMutation.accept`:
  reserve any caller idempotency key, lock the resource row, apply its
  desired-state (or spec) change, stamp the **convergence deadline**, append the
  **resource event**, and complete the key with the accepted identity, all in
  one transaction. There is deliberately no overlapping-mutation `409`:
  desired state is level-triggered, so two distinct writes leave the last one
  standing and the row lock is what serializes them.

- **Idempotency claim** — one short-lived `idempotency_keys` row that maps an
  authenticated actor plus opaque `Idempotency-Key` to the request digest and
  accepted resource/mutation identity. The reservation is the first write in
  the mutation transaction, so an in-flight duplicate waits at PostgreSQL's
  unique index before it can mutate; completion is the last write, so commit
  exposes the mutation and replay identity together and rollback exposes
  neither. Same key plus a different method, request target, or canonical JSON
  body is `422`. Claims expire after 24 hours and are swept; unlike the
  append-only resource event, they are a replay cache, not an audit trail.

- **Dispatch strategy** — how an accepted mutation reaches the agent:
  - *state sync* — the desired state is already written; ring the agent's
    doorbell (or degrade the resource now if it is unplaced/offline). Success
    arrives later, from the observed-state applier.
  - *placement* — background scheduling + placement + first sync (`create`).
    Degrades the resource on error; success is deferred to the applier.
  - *direct resolution* — resolve locally without agent teardown (the
    offline/unplaced delete; online deletes ride *state sync*).

- **Convergence deadline** — how long an accepted mutation has before it is
  declared timed out, stamped as `max(existing, now + budget(kind))` so a short
  mutation can never shorten a long one's runway. It replaced the operation
  row's `created_at` plus its per-kind budget; the budget figures themselves
  survive as `OperationResourceKind.completionBudgetSeconds(for:)`.

- **Resolve-after-failure** — realigning a resource with reality once a
  mutation failed: escalate a still-transitional (or never-created) resource to
  `.error`, then `revertDesiredToObserved` so an unachieved intent (e.g. a
  failed delete's `.absent`) does not linger and replay destructively on a
  later sync. Lives on the model as `resolveForStuckOperation(_:)`, called by
  `ResourceConvergence.recordFailure`.

- **Stuck-convergence sweep** — the backstop that marks a resource `degraded`
  once its convergence deadline passes unconverged. Deliberately **not** a
  cluster singleton: the write is idempotent and every replica computes the
  same verdict, and the one non-idempotent effect (the completion webhook) is
  claimed by a conditional `UPDATE` on the deadline column.

- **Resource event** — one append-only `resource_events` row describing a
  mutation: the **actor** that asked for it, the resource it acted on (kind,
  id, and name snapshot), the mutation kind, the **target generation**, and
  the org/project it happened in. Written in the mutation's own transaction,
  never updated, never swept, no retention — the immutability enforced by a
  trigger, not just by convention. It is the durable attribution record, and
  since STR-152 the only one.

- **Actor** — who performed a mutation, as a *principal type plus id*
  (`user` / `service_account` / `workload` / `system`). `system` is the control
  plane acting with no principal behind it — the sandbox expiry sweep — and is
  the one actor with no id, because it is not a row.

- **Operations façade** — `GET /api/operations/:id` and the per-resource
  history lists, synthesized on read from `resource_events` plus the resource's
  conditions (`OperationFacade`). Kept because a **delete**'s outcome is the one
  a resource cannot report about itself.

- **Creator reference** — `created_by_id` (`images.uploaded_by_id`): the
  convenience join a list view renders, *attribution rather than ownership*.
  Nullable and `ON DELETE SET NULL` everywhere (STR-297) — deleting a user
  nulls the reference and must never delete or block the resource it points
  at, because half the schema once said otherwise: a CASCADE here silently
  destroyed volumes, snapshots and images, and the reconciler then tombstoned
  the surviving bytes as strays. Durable attribution is the resource event,
  never this column. Two checked exceptions in `UserController.delete`, both
  `409`s naming a remedy: a SCIM token (its FK stays RESTRICT — a credential
  the creator is accountable for) and a volume still attached to a VM.

- **AgentDispatch** — the seam a mutation depends on to reach agents
  (`agentIsOnline`, `syncDesiredState`). Production adapter: `AgentService`.
  Test adapter: an in-memory fake, so the accept path is testable without an
  agent socket or an HTTP round-trip.

## Desired state

- **Desired state** vs **observed state** — the database holds each resource's
  desired power state (`running` / `shutdown` / `paused` / `absent`) alongside
  the status an agent last reported. API mutations move desired state; agents
  converge on it and report back. See `docs/architecture/overview.md`.
- **Generation** — a monotonic counter bumped on every desired-state change so
  agents treat a sync as newer than anything they have applied; syncs are
  level-triggered and safe to drop or replay.
- **Create strategy** — how a resource that does not exist on an agent yet gets
  its initial bytes, carried *on its desired entry* rather than as an operation:
  a sandbox's `restoreFrom`, a volume's `source` (blank / image / clone). Read
  only while the resource is absent, which is what makes a replayed sync unable
  to overwrite live data with a fresh copy.
- **Desired attachment** — which VM a volume should be presented to, and in
  which slot. A *field* of the volume's desired entry, not a status: modelling
  it as a status would make "present, but the attach failed" unrepresentable.
  The agent keeps a durable record of what it realized, so an attachment
  survives a guest power cycle and an agent restart.
- **Conditions** — the `conditions` block VM, sandbox and volume API responses
  carry:
  *converged* / *targetGeneration* / *observedGeneration* / *phase* /
  *degraded*. Derived on read, never stored, and never written by a mutation —
  it restates the reconciliation loop's own state, and refetching a resource
  until `converged` is how a client follows a mutation. *Converged* and
  *degraded* are mutually exclusive at the target generation, so a client
  always has exactly one verdict.
- **Degraded** — the last convergence attempt that failed (its error and the
  generation that produced it), carried until something converges. Deliberately
  independent of `targetGeneration`: a degraded condition naming an older
  generation is a failure a newer mutation is already retrying, and it stands
  alongside a converged resource. Naming the *current* generation is the other
  case: that is the verdict, and `converged` is false beside it.

## Deletion

- **Terminating** — a resource whose `DELETE` has been accepted: desired state
  is `.absent` and the row is still there. `DELETE` never removes a row.

- **Finalizer** — one named cleanup participant a terminating resource still
  owes, held as a token in its `finalizers` list (`ResourceFinalizer`, e.g.
  `agent.absent`). Stamped in the same write that marks the resource absent.
  A token this replica does not recognize holds the row exactly like one it
  does — the replica that owns it will clear it.

- **Participant** — the code that clears one token, from wherever it actually
  runs. Every participant is **idempotent** (its trigger repeats), **crash-safe**
  (a crash mid-cleanup leaves the token stamped and the step is retried), and
  **independently retryable** (no participant depends on another's order). The
  first and currently only one is the observed-state applier's confirmation of
  absence, which clears `agent.absent`.

- **Reap** — removing the row and everything that goes with it (external
  cleanup, IAM bindings, quota, placement reservation) once the last finalizer
  clears. `ResourceFinalizerService.clear` is the single entry point;
  `FinalizableResource.reap` is the per-kind teardown, which claims the row so
  exactly one of two racing clears reports the removal.

- **Orphaned terminating resource** — a terminating row whose finalizers all
  cleared but whose removal never happened (a crash or drain between the two
  commits). `sweepOrphanedTerminatingResources` is the cluster-singleton
  backstop that reaps them, so no participant has to invent its own retry.

- **Unrecognized / held workload** — a workload an agent holds that its last
  sync did not list (STR-98). Omission is not destructive: the agent *holds*
  it and reports it, and the control plane records one
  `AgentWorkloadClaim` disposition — `held` when a row exists (the omitting
  sync is what is wrong, never the workload; the claim stays as evidence an
  operator or the re-point endpoint acts on), or `tombstoned` when none does.

- **Tombstone** — the explicit teardown authorization for a workload the
  control plane has no row for: a `tombstoned` claim becomes a
  `DesiredWorkloadTombstone` in the next sync, carrying a generation that
  must outrank whatever the agent last applied. Only a tombstone (or an
  ordinary `.absent` entry) tears down; a blast-radius guard bounds how much
  of a host one sync's tombstones may remove.

## Cross-replica coordination

- **Replica** — one control-plane process. Each generates a fresh `replicaID`
  at startup; an agent's WebSocket lives on exactly one replica at a time.
- **Doorbell** — a contentless "this agent's desired state changed" broadcast on
  the one fleet-wide `agent:doorbell` channel (STR-146). Every replica hears it
  and asks itself whether it can act — it holds that agent's parked poll, or its
  socket — and at most one can. A latency optimization only: the agent's own
  unconditional re-fetch is the backstop, so a lost doorbell is always safe, and
  over-ringing is free.
- **ReplicaMessageBridge** — the module (`app.replicaBridge`) that owns the
  cross-replica doorbell, socket route, one-way delivery, and subscription
  lifecycle over `CoordinationService`. The TTL-bound
  `agent:{name}:replica` route locates the replica holding an agent socket for
  interactive guest execution and recorded command delivery.
- **ReplicaBridgeDelegate** — the narrow seam the bridge depends on for the one
  operation that requires local state: turning a doorbell into a local
  desired-state sync. Production adapter: `AgentService`. Test adapter: an
  in-memory fake, so the bridge is testable through its own interface without a
  real agent socket.

## Volume attachment

- **Attachment** — the **desired attachment** as it is stored: `vm_id`,
  `device_name`, `boot_order`, `readonly` and `attached_agent_id` on `volumes`.
  Not five independent columns — `VolumeAttachmentService` is the only thing
  that moves them, and it moves them together, generation included. The
  database enforces the shape: unique `(vm_id, device_name)` and
  `(vm_id, boot_order)` per VM, an attached row must name its device, and
  `vm_id` is `ON DELETE RESTRICT`.

- **Claim / release** — the two transitions. A claim is one transaction under a
  per-VM advisory lock (the `IPAMService` idiom), so generating the next free
  `disk<N>` cannot race another attach; a release clears every column. Both
  bump the generation, which is what makes them reach the agent at all — and
  neither writes `status`, which is only ever what the agent last observed.
  Deleting a VM releases its volumes inside the delete transaction: the volume
  outlives the VM.

- **Device name** — the volume's stable label within its VM (`VolumeDeviceName`
  in `StratoShared`, validated at the API boundary). It is a *label*, not an
  identifier: the agent names the QEMU device after the **volume id**
  (`QEMUDiskIdentity`), so nothing resolves a disk by device name.

## Snapshots

- **Volume snapshot** — a **disk-only** point-in-time copy of one volume, an
  external qcow2 overlay backed by the volume. Owned by the storage layer, taken
  only on a *detached* volume, and unrelated to guest memory.

- **Checkpoint** (a.k.a. **VM snapshot**) — guest **RAM + device state + disks**
  captured together, so a restore brings the machine back mid-process. Stored as
  a qcow2 *internal* snapshot inside the VM's own disks, tagged
  `strato-<snapshotId>`, and therefore pinned to the agent that took it.
  Recorded as a `vm_snapshots` row; `size` counts only the machine state, since
  the disks it lives inside are already charged under the VM.

  "Snapshot" alone is ambiguous between the two — say which, or say
  "checkpoint" when you mean memory is included.

- **Snapshot artifact** — the umbrella noun for all three families (volume
  snapshot, VM checkpoint, sandbox snapshot) as *desired state* (ADR 0001
  stage 8, STR-150). An artifact is a durable noun with an identity, a parent,
  and a host, which an agent enumerates, diffs and converges on. Capture and
  delete are desired state, and each family is a `ConvergingResource` and
  `FinalizableResource`. Restore is represented by an **edge nonce**.

- **Capture strategy** — how an artifact that does not exist yet gets taken
  (`DesiredSnapshotCapture`): a sandbox's resume/stop mode, a volume's
  attached-VM refusal hint. A *create strategy* in the `restoreFrom` /
  `DesiredVolumeSource` sense, read only while the artifact is absent from the
  host — which is what makes it safe for a level-triggered sync to carry an
  instruction that pauses a live guest.

- **Export** — that an artifact should *also* exist in the control plane's
  object store. A **placement fact**, not a verb: the desired entry carries the
  upload slots, the agent converges by streaming to them, and the byte transfer
  beneath stays a transport concern. Withdrawing one is the control plane's own
  bookkeeping, never a teardown the agent performs.

- **Retention** — an artifact's absolute `expires_at`, resolved at creation
  from a per-request `ttlSeconds` or the fleet default. Swept by a
  cluster-singleton pass that issues the same delete an operator would,
  attributed to the `system` actor. Absolute rather than relative, because a
  TTL re-evaluated against "now" drifts with every restart.

- **Edge nonce** — a monotonic count of how many times a verb with no durable
  state delta was requested (`DesiredVMState.rebootGeneration`,
  `DesiredVMState.restore`, `DesiredSandboxState.restore`). It is separate from
  the resource generation because replaying an edge is a second disruption.

- **Applied-nonce record** — the edges the agent has consumed for a workload,
  stored durably in `VMManifestStore`. No record is not zero: the desired
  nonces are **adopted** without execution so registration cannot replay old
  disruptive actions.

- **Superseded** — a reboot edge consumed without execution because a later
  stop or a boot made it moot. Restore edges are never superseded; they remain
  deferred until the workload is next wanted running.

## Identity

- **Instance identity** — the SPIFFE ID a VM is registered under,
  `spiffe://<trust-domain>/vm/<vm-id>` with the id lowercased (STR-55). One
  `workload_registrations` row per VM (`kind = workload`, linked by `vm_id`),
  written in the VM's create transaction and cascade-deleted with it, and
  published to the guest through the instance metadata service. The row stores no
  label: an operator-facing name for it is the VM's current one, read through
  `vm_id` rather than copied and left to decay. It **names** the
  VM as an IAM principal; it grants nothing — a registration with no role
  bindings authenticates and authorizes nothing, which is why every VM has one
  rather than it being opt-in. Revocable only by deleting the row, and that is
  one-way: nothing re-creates it.

- **Trust domain** — the authority half of a SPIFFE ID. The **platform** trust
  domain (`SPIRE_TRUST_DOMAIN`, default `strato.local`) owns the control plane
  and every agent; an **organization** trust domain (`org-<16 hex>.<platform>`,
  an `org_trust_domains` row) owns that org's guests once per-org trust domains
  are enabled and its SPIRE instance is `active` with a cached bundle. Falling
  back to the platform domain is **degraded**, not equivalent — it cross-signs
  tenants under one root. A guest's domain is chosen once, when its registration
  is written, and the URI never moves.

## Networking

- **Network ACL (NACL)** — optional, ordered **network-scoped** allow/deny
  policy attached to a logical switch. Its intent is stateless: ingress and
  egress rules are authored independently, lower rule numbers win, and each
  direction defaults to deny. For a new flow, an ACL allow only passes the
  packet onward to the applicable NIC security groups; it is not an override.

- **Security group** — stateful, **NIC-scoped** allow policy attached through
  OVN port groups. A NIC may join several groups; their `allow-related` rules
  collectively admit a connection and the site-wide managed-port group supplies
  the default drop. Security groups are not ordered tenant deny lists.

- **OVN established-flow boundary** — once a security-group `allow-related`
  verdict tracks a connection, OVN does not re-evaluate that established return
  traffic through a switch ACL. Network ACL policy remains stateless in its own
  rule construction, but this backend cannot provide AWS-exact independent
  return-path filtering for an already established security-group flow.

- **Chassis service foot** — the per-network pair of things every hypervisor
  builds for a link-local service its guests use: one OVN `localport` on the
  network's logical switch (authored by the site's topology authority) and one
  local termination of it (built by every agent running a NIC on that network).
  Two services have one each. **Instance metadata** terminates in a network
  namespace, `strato-md-<network-uuid>`, because source-IP attribution is its
  security model. The **resolver** terminates in the **host** namespace, because
  it has to forward and that namespace has no egress.

- **Service ULA space** — `fd00:ec2::/32`, the IPv6 range every link-local
  service address is drawn from: instance metadata at `fd00:ec2::254`, and every
  network's resolver from `fd00:ec2:1::/48`. Reserved *against tenants*, which is
  the whole point of naming it: unlike its v4 counterpart it is ordinary ULA
  space, indistinguishable from what a network's own subnet is drawn from, so a
  tenant subnet overlapping it would inherit the service carve-outs — ACLs no
  security-group rule can override — pointed at tenant addresses. A subnet an
  operator types is rejected; a generated one is nudged clear. Networks that
  predate the reservation are named in a warning at every control-plane
  startup until an operator renumbers them.

- **Resolver** — the DNS server a network's guests are pointed at, answering on
  a link-local pair of the network's own derived from its `resolver_index`. One
  CoreDNS process per *hypervisor*, with a server block per network. It serves
  the zones attached to each network in full — including the CNAME/TXT/SRV
  records the OVN `DNS` table cannot express — and **forwards** everything else
  through the hypervisor's own egress, which is what lets a guest on a network
  with no external access resolve a public name. Enabling it is a **site-wide**
  decision, not a per-host one: guests are pointed at the address by one DHCP row
  while the process answering runs per host, so one host that cannot serve one
  withholds the feature from every network in its site.

- **Resolver index** — the single fleet-wide integer a network is allocated, from
  which both of its resolver addresses and its host routing-table id are derived.
  Fleet-wide rather than per host because a network's index cannot depend on
  where its VMs are placed; sequential rather than hashed because ~65k addresses
  collide under hashing at a few hundred networks. Never moved once assigned —
  moving one would strand every DHCP lease that carries it.

- **Upstream forwarder** — where a network's resolver sends the names it does
  not serve itself. This is what `LogicalNetwork.dnsServers` means on a network
  with the resolver enabled; with it disabled the same list is what guests are
  told directly. One field, two readings, and which applies is
  `resolverEnabled`. An empty list is not a fallback to anything: internal names
  resolve and everything else is refused.

- **Search domain** — what a guest appends to an unqualified name, delivered as
  the DHCP `domain_name`/`domain_search` option or as cloud-init's
  `nameservers.search`, and stored as `LogicalNetwork.domainName`. Guest-side
  config, which is the whole point: no resolver can supply one, so pointing a
  guest at the resolver that answers `alpha.corp.internal` still leaves `alpha`
  unresolvable until this is set.

  It **follows the primary zone while the operator has not claimed it** (STR-201)
  — promotion sets it, re-pointing or renaming the zone moves it, demotion
  clears it — and stops following the moment someone sets a value of their own.
  `primaryDNSZone` already means "the zone this network's VMs register into", and
  "and resolve through" is the same intent; making the operator say it twice is
  what left a correctly realized zone inert.
