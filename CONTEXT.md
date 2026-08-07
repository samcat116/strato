# Domain context

Ubiquitous language for Strato's control plane. Terms here are the names we
use in code, tests, docs, and review. Architecture-level maps live in
`docs/architecture/`; this file pins the vocabulary those maps assume.

## Resource operations

- **Resource operation** — one durable, asynchronous lifecycle mutation of a
  VM or sandbox (create / start / stop / restart / pause / resume / delete /
  resize / snapshot …), recorded as a `ResourceOperation` row. Mutation
  endpoints return **202 Accepted** with the row; the client polls it to a
  terminal state. The `resource_kind` discriminator (`virtual_machine` |
  `sandbox`) keys the per-kind behavior — one enum, not a fork per resource.

- **Begin** — the atomic first half of an operation: insert the `pending` row
  and apply the resource's desired-state (or spec) change in **one**
  transaction, rejecting a second concurrent mutation with **409 Conflict**
  (the double-submit guard). `ResourceOperation.begin` is the deep primitive;
  every operation kind, including `create`, goes through it.

- **Dispatch strategy** — how an operation reaches the agent after `begin`:
  - *state sync* — the desired state is already written; nudge the owning
    agent (or fail the operation if it is unplaced/offline). The success
    verdict arrives later, from the observed-state applier.
  - *awaiting response* — a correlated imperative command the agent answers
    after it runs (VM reboot: "an action, not a state", so it cannot ride the
    level-triggered sync). The verdict is recorded immediately.
  - *placement* — background scheduling + placement + first sync (`create`).
    Records a failure verdict on error; success is deferred to the applier.
  - *direct resolution* — resolve the operation locally without agent
    teardown (the offline/unplaced delete; online deletes ride *state sync*):
    run the removal work, recording the verdict only if the work reports it
    finished — otherwise the row stays `pending` for whoever still owes
    cleanup, with the stuck-operation sweep as the backstop.

- **Verdict** — the terminal outcome recorded on the operation row
  (`succeeded` / `failed`). `recordVerdict` is the single choke point for the
  **controller and sweep** verdict paths: it marks the row terminal *iff still
  pending* (so the agent-response path and the stuck-operation sweep cannot
  overwrite each other) and, on failure, runs resolve-after-verdict. (The
  observed-state applier records its own success/convergence-failure verdicts
  inline, because its failure resolution is convergence-specific.)

- **Resolve-after-verdict** — realigning a resource with reality once its
  operation failed: escalate a still-transitional (or never-created) resource
  to `.error`, then `revertDesiredToObserved` so an unachieved intent (e.g. a
  failed delete's `.absent`) does not linger and replay destructively on a
  later sync. Lives on the model as `resolveForStuckOperation(_:)`, shared by
  `recordVerdict` and the sweep.

- **Stuck-operation sweep** — the cluster-singleton backstop that fails any
  operation still `pending` past its per-kind completion budget (control-plane
  restart, lost agent) and resolves the resource it left in flight.

- **ResourceOperationCoordinator** — the deep module that owns the operation
  lifecycle end to end: `begin` → dispatch (by strategy) → `recordVerdict`.
  Both controllers and the sweep drive operations through its small interface
  instead of re-spelling the begin/dispatch/verdict sequence per handler.

- **Resource event** — one append-only `resource_events` row describing a
  mutation: the **actor** that asked for it, the resource it acted on (kind,
  id, and name snapshot), the mutation kind, the **target generation**, and
  the org/project it happened in. Written in the mutation's own transaction,
  never updated, never swept, no retention — the immutability enforced by a
  trigger, not just by convention. It is the durable attribution record;
  `resource_operations.user_id` is the transitional one, and mutations
  dual-write both until the operations table retires (ADR 0001).

- **Actor** — who performed a mutation, as a *principal type plus id*
  (`user` / `service_account` / `workload` / `system`) rather than the plain
  user id an operation row carries. `system` is the control plane acting with
  no principal behind it — the sandbox expiry sweep — and is the one actor
  with no id, because it is not a row.

- **AgentDispatch** — the seam the coordinator depends on to reach agents
  (`agentIsOnline`, `syncDesiredState`, `performOperationAwaitingResponse`).
  Production adapter: `AgentService`. Test adapter: an in-memory fake, so the
  lifecycle is testable through the coordinator's interface without an agent
  socket or an HTTP round-trip.

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
  it restates the reconciliation loop's own state, so refetching a resource
  until `converged` is the alternative to polling its **resource operation**.
- **Degraded** — the last convergence attempt that failed (its error and the
  generation that produced it), carried until something converges. Deliberately
  independent of `targetGeneration`: a degraded condition naming an older
  generation is a failure a newer mutation is already retrying.

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
- **Socket route** — the `agent:{name}:replica` key naming the replica that
  holds an agent's socket. Recorded on accept and refreshed by every heartbeat;
  a crashed replica's claim expires by TTL.
- **Nudge** — a fire-and-forget "your agent's desired state changed" message a
  mutating replica sends to the socket-holding replica so it pushes a fresh
  sync. A latency optimization only — the periodic sync is the backstop, so a
  lost nudge is always safe.
- **Cross-replica RPC** — the correlated request/reply forwarding for the
  exchanges that are *actions, not states* (VM reboot, VM restore, sandbox
  restore) and so cannot ride the level-triggered sync. A volume's own lifecycle
  left this list in STR-148 and every snapshot artifact's in STR-150; what
  remains is the restores, which convert to nonces in STR-151. When the serving
  replica lacks the socket, the exchange is forwarded to the holder and the
  verdict returns on the requester's reply channel.
- **ReplicaMessageBridge** — the deep module (`app.replicaBridge`) that owns
  the whole cross-replica seam: route recording, the local-vs-forward routing
  decision, nudge fan-out, RPC forwarding, and the subscription lifecycle. It
  composes `CoordinationService` (the Valkey / in-memory `CoordinationStore`
  adapters).
- **ReplicaBridgeDelegate** — the narrow seam the bridge depends on for the two
  operations that require the local socket: running a forwarded exchange over a
  held socket, and turning a nudge into a local desired-state sync. Production
  adapter: `AgentService`. Test adapter: an in-memory fake, so the bridge is
  testable through its own interface without a real agent socket.

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
  and a host, which an agent enumerates, diffs and converges on: capture and
  delete are desired state, and each family is its own `ConvergingResource` and
  `FinalizableResource`. What is *not* a state is a **restore** — "this VM
  should be at checkpoint C" cannot be re-converged on, because the guest
  starts writing the moment it resumes — so restore stays an imperative
  operation until STR-151 makes it a nonce.

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
