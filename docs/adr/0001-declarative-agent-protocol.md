# ADR 0001: A fully declarative agent protocol

- **Status**: Accepted
- **Progress**: stages 1 (conditions, STR-142), 2 (`resource_events`,
  STR-143), 3 (finalizers, STR-144), 4 (202 → `{resource, targetGeneration}`,
  STR-147), 5 (volumes declarative, STR-148), 6 (`agent_update` removal,
  STR-145), 8 (snapshots and checkpoints declarative, STR-150), and 10 (pull
  transport, STR-146) have landed; later stages pending.
- **Date**: 2026-08-02
- **Deciders**: Sam Schmitt
- **Scope**: control-plane ↔ agent protocol, `ResourceOperation` machinery,
  multi-replica coordination

## Summary

Converge every control-plane → agent interaction that acts on a durable
resource onto the existing level-triggered reconciliation loop, deliver
desired state by agent pull instead of control-plane push, project operation
progress as conditions on the resource itself, and generalize deletion into
finalizers. Imperative RPC survives only for live byte streams (console,
exec, logs). The `ResourceOperation` side-table, the generic request/response
apparatus in `AgentService`, and the cross-replica RPC forwarding in
`ReplicaMessageBridge` are all retired.

## Context

### What exists

Strato's core control loop is already declarative (issues #260, #261): the
database stores desired state, `DesiredStateAssembler` produces a full
authoritative `DesiredStateMessage` per agent, per-resource monotonic
`generation` counters guard against reordering, and the agent-side reconciler
diffs observed vs. desired and converges via per-VM serial lanes. Syncs are
level-triggered and safe to drop or replay; a periodic timer is the
correctness backstop.

But of the ~40 message types in `shared/Sources/StratoShared/`
(`WebSocketProtocol.swift` and friends), only two carry the reconciliation
loop. Roughly 19 are one-shot imperative RPCs — nine `volume_*`, the
VM checkpoint/restore/snapshot-delete trio, the sandbox snapshot quartet,
`vm_reboot`, `agent_update` — correlated by `requestId` and answered with
`success`/`error`. These drag in, on the control plane:

- **The pending-request apparatus** (`AgentService.swift` ~2452–2670):
  checked continuations, per-request timeout tasks, cancellation
  bookkeeping, `failPendingRequests(for:)` on disconnect, response
  correlation and ownership checks.
- **`ResourceOperation`** (issue #412): a side-table of async operations with
  per-kind completion budgets, a cluster-singleton stuck-operation sweep,
  per-resource-kind stuck-resolution paths, and deliberate FK-lessness so
  delete operations survive row removal. Operation rows are also the current
  home of user attribution (`user_id`), on which JWT-SVID mutation
  attribution (STR-15) depends, and the transaction in which webhooks (#559)
  are enqueued.
- **Cross-replica RPC forwarding** (`ReplicaMessageBridge`): an imperative
  action on replica A for an agent socketed to replica B travels over the
  `replica:{id}:rpc` / `rpc-replies` pub/sub channels — a correlated
  request/response spanning two processes and Valkey, with timeout state
  held on both ends.
- **Socket routing** (`agent:{name}:replica` keys) so any replica can find
  the one replica capable of reaching a given agent, plus targeted
  **sync nudges** (`replica:{id}:nudges`) so mutations reach the
  socket-holding replica for payload assembly and push.

Each of these is load-bearing for correctness today, and each has real
failure modes we have already paid for: stale routing keys after failover
(the `.ownReplica`-with-no-local-socket branch in `routeDesiredStateSync`),
sweep-vs-verdict races mediated by `completeIfPending`, orphaned in-flight
exchanges when a replica dies uncleanly, and the recurring CI teardown
crashes whose frames sit in exactly these seams.

### The false dichotomy

The comment atop `VMSnapshotMessages.swift` states the current design
assumption: a checkpoint "is an *action* rather than a state, so it cannot
ride the level-triggered desired-state sync." This is true of the verb and
false of the result. "Checkpoint this VM" is an action; "checkpoint C exists
for VM V" is a state — a durable artifact with an identity that an agent can
diff and converge on. The same holds for volumes, volume snapshots, clones,
and sandbox snapshots.

Kubernetes faced every one of these cases and settled a consistent taxonomy:

| Need | Kubernetes answer | Mechanism |
| --- | --- | --- |
| Live byte streams | Openly imperative subresources (`pods/exec`, `attach`, `log`) | Connection upgrade, nothing in etcd; **uniform authz/audit**, non-uniform transport |
| Restart-shaped edges | Encode the edge as a nonce in the spec | `kubectl rollout restart` = patch `restartedAt` annotation |
| One-shot work with durable results | Make the request a durable object | `Job`, `CertificateSigningRequest` (+ TTL controllers for retention) |
| Deletion with cleanup | Finalizers | `deletionTimestamp` + `metadata.finalizers`; row outlives the DELETE |
| Operation progress | `status.conditions` on the resource | No operations side-table exists |

The decision rule that falls out: **does the interaction have a durable noun
on the other side?** If yes, it is state and belongs in the reconcile loop.
If it is a live stream tied to a human session, it stays RPC. If it is a
read, it is observed state.

## Decision

### 1. The durable-noun rule governs the protocol

Every message that creates, mutates, or destroys a durable resource moves
into the desired-state sync. Streams stay imperative. Reads fold into
observed state. Concretely:

| Messages | Disposition |
| --- | --- |
| `volume_create/delete/attach/detach/resize` | Desired volume entries (exists, size, attachment) in the sync |
| `volume_clone` | A create *strategy* on the desired entry — the `DesiredSandboxState.restoreFrom` pattern (issue #427), not an operation |
| `volume_snapshot`, `volume_snapshot_delete`, `vm_checkpoint`, `vm_snapshot_delete`, `sandbox_snapshot_create/_delete` | Desired artifact entries; captured sizes/metadata return via observed state (**landed**, STR-150) |
| `sandbox_snapshot_export` | A placement fact ("snapshot S exists on agent B"); the byte transfer beneath remains a transport concern (**landed**, STR-150) |
| `agent_update` (imperative form) | Deleted; `DesiredAgentUpdate` (issue #434) already exists and is the proof this migration works |
| `vm_reboot`, `vm_restore`, `sandbox_restore` | Edge-as-nonce: a monotonic `rebootGeneration` (and restore analog) on the desired entry; the agent persists last-applied in its manifest and acts when desired > applied |
| `volume_info` | Deleted; the fields join the observed report |
| `console_*`, `sandbox_exec_*`, `vm_log`, `sandbox_log` | **Stay imperative, permanently.** Live byte pipes with a human on the end; the uniformity that matters is Cedar authorization and addressing, not transport |

The nonce counters must be durable on the agent (`VMManifestStore`);
a manifest-less re-registration must not replay reboots.

### 2. Desired state is pulled, not pushed

The agent fetches its desired state via long-poll HTTP GET against **any**
control-plane replica, over the same Envoy SVID-mTLS listener that already
carries artifact downloads (`MTLSArtifactDownloader`, issue #493). The
endpoint scopes by SVID identity exactly as the image-download route does.

- **Doorbells are contentless and broadcast.** A mutation publishes "agent X
  changed" on a single channel; every replica checks whether it holds X's
  parked poll, at most one does, the rest no-op. No routing directory, no
  targeted delivery. A lost doorbell costs one poll interval.
- **The agent re-fetches unconditionally on a slow timer**, doorbell or not.
  Over-ringing is free; under-ringing costs latency, never correctness.
- **Version numbers are an optimization only.** The response carries an ETag
  for `304 Not Modified`. It must never gate *whether* the agent fetches —
  the periodic unconditional fetch is the invariant; the validator is a
  bandwidth saving.

  *Amended in implementation (STR-146):* this originally proposed reusing the
  in-process `desiredStateRevisions` counter as the ETag. That does not
  survive multi-replica, which is the deployment this decision exists to make
  boring. Counters are per-process and start at zero, so a poll landing on a
  replica other than the one that served the previous poll either collides —
  a wrong `304`, the exact stranding this bullet forbids — or misses on every
  request, returning a full payload each time so the agent re-polls
  immediately and the fleet degenerates into a continuous assembly loop.
  Scoping the ETag `replicaID:revision` fixes only the first.

  The implementation uses a **SHA-256 digest of the assembled payload**
  (`DesiredStateDigest`), with per-assembly noise normalized out (correlation
  ids, the timestamp, freshly minted registry tokens, re-resolved artifact
  URLs). It is replica-independent, and — unlike a counter that has to be
  bumped by hand at every mutation site across the wide assembly scope (own
  VMs, volumes, site-peer networks, security-group closures, floating IPs,
  rollout targets) — it has **no missed-bump failure mode at all**, because it
  is derived from the bytes actually assembled. The normalization list is a
  subtraction from the full payload rather than a hand-built projection, so a
  field added to the wire protocol participates automatically: forgetting to
  update it produces a spurious `200` (harmless), never a wrong `304`.
- **Side effects move to the pull.** Assembly currently records
  image-download grants (issue #562) and mints registry credentials fresh
  per sync. These stay at response-assembly time on the serving replica —
  never cached — so credentials are always fresh.

  *Amended in implementation (STR-146):* "a grant is never recorded for a sync
  that was not delivered" is not achievable and, on inspection, not needed. A
  conditional poll must assemble to compute its digest, so a poll that ends in
  `304` has recorded grants for a payload it then discards — routinely, not
  just in the re-poll race. That is safe, and the argument is specific rather
  than inherited: `grantImageDownload` is a fixed-TTL `SETEX` of
  `imggrant:agent:{agentId}:image:{imageId}` — purely **additive**, and scoped
  to the placement the assembly just read. Re-recording it for an agent that
  *currently* holds the placement is exactly right; that agent may still be
  mid-pull, and the grant existing to cover in-flight downloads is why it has
  a 30-minute grace TTL in the first place. Registry credentials are absorbed
  by `RegistryCredentialCache`, so a discarded assembly re-mints nothing.

  This does not resurrect the rejected cache-the-payload alternative, which
  fails for a different reason: it would grant against a *stale* placement and
  serve *stale* credentials. Over-recording within the current placement is a
  widening bounded by that placement; caching is a widening bounded by nothing.
  If grants ever become scoped-and-narrowing rather than additive, this
  reasoning has to be revisited — `ImageDownloadScopingTests` pins it.

The WebSocket remains for streams (console, exec, log forwarding) and as the
observed-state/heartbeat channel initially; migrating observed state to POST
is a possible follow-up, not part of this decision.

### 3. Operation progress lives on the resource

Resources already carry `generation`, `observedGeneration`,
`convergencePhase`, `lastError`, and `failedGeneration`. Operation
completion is already derived from them
(`ObservedStateApplier`: succeeded ⇔ `observedGeneration >= generation` ∧
desired satisfied; failed ⇔ `failedGeneration == generation`). We stop
maintaining that derivation by hand in a side-table:

- API resources expose a **conditions block** (converged / targetGeneration
  / observedGeneration / phase / degraded), computed in the DTO from
  existing columns.
- Mutation endpoints keep returning **202**, with body
  `{resource, targetGeneration}`. Clients poll the resource, not an
  operation.
- The stuck-operation sweep becomes a **stuck-convergence sweep** that flips
  `degraded` when `generation − observedGeneration` is outstanding past
  budget. Marking degraded is idempotent and commutative, so the sweep can
  run lock-free on every replica; only the webhook enqueue needs
  transition-detection inside its transaction.
- Per-operation-kind budgets (create 600s vs. reboot 120s) lose their
  natural home; the resource records `lastMutationKind`/`lastMutationAt` to
  preserve differentiated budgets.

### 4. Deletion generalizes to finalizers

The agent-confirmed tombstone dance already exists (`DesiredVMStatus.absent`;
row removal only after the agent's full report omits the resource). It is
hardcoded to one participant. We generalize:

- Resources gain a `finalizers` list (e.g. `agent.absent`, `ipam.release`,
  `dns.deregister`, `fip.release`).
- `DELETE` marks desired `absent` and stamps the list; each cleanup step —
  today inline and ordered by hope in the delete path — removes its own
  token idempotently from wherever it actually runs; the row is removed when
  the list empties.
- Because the row now provably outlives the delete, the original reason
  `ResourceOperation` has no FK to its resource disappears — which is what
  makes the side-table finally removable.

### 5. Attribution and events get a durable home

`resource_operations.user_id` is currently the only mutation-attribution
record and blocks JWT-SVID mutations (STR-15). Operation completion is
currently the webhook (#559) enqueue point. Both must survive the table:

- An **append-only `resource_events` table**: written at mutation time
  (who, what, kind, target generation), never updated, never swept. This is
  the audit trail and the STR-15 attribution point.
- **Webhook enqueue moves to the conditions transition** detected in
  `ObservedStateApplier`, in the same transaction that applies the observed
  report — the same guarantee as `completeIfPending`, one fewer table.

### 6. `ResourceOperation` is retired via a façade

The operations API remains as a compatibility façade synthesizing responses
from conditions + `resource_events` until clients migrate; the table, the
coordinator, the sweep, and the per-kind verdict paths are deleted when only
façade reads remain.

## Consequences

### Removed or demoted

- **The generic RPC apparatus** in `AgentService` (~300 lines of
  continuation lifecycle, timeout races, disconnect cleanup) — the highest
  defect-density seam in the control plane. Console/exec keep their own
  session managers; nothing else calls it.
- **`ResourceOperationCoordinator` (304), `ResourceOperation` (372),
  `OperationController` (57), `sweepStuckOperations` +
  stuck-resource resolution (~220)**, plus the `completeIfPending` call
  sites threaded through `ObservedStateApplier`. Net of the replacements
  (conditions projection, `resource_events`, stuck-convergence sweep),
  roughly −600 lines and — more importantly — the sweep-vs-verdict race
  class and the cluster-singleton sweep lock.
- **`replica:{id}:rpc` / `rpc-replies`** — deleted entirely; there is no
  cross-replica request state because there are no cross-replica requests.
- **`agent:{name}:replica` routing keys and targeted nudges** — deleted
  with the pull transport; `ReplicaMessageBridge` shrinks to (or past) a
  broadcast doorbell.
- **~19 wire message types**, each with struct, `MessageType` case, envelope
  arm, agent-side dispatch, and version gate. `success`/`error` correlation
  goes with them.
- **Thin RPC-wrapper services** (`VMSnapshotService`,
  `SandboxSnapshotService`, the dispatch half of `VolumeService`): logic
  moves into assembler entries and agent reconciler lanes, which already
  have retry, per-resource serialization, and crash recovery via the
  manifest — properties the imperative handlers uniquely lack today.
- **Frontend**: one resource lifecycle instead of two; "refetch until
  converged" replaces operation polling.

Rough total: 2,500–3,000 net lines across control plane, agent, and shared,
concentrated in the seams that have produced our worst races and flakes.

### Multi-replica becomes boring

This is the strategic payoff. Today multi-replica correctness depends on a
directory (routing keys) staying fresh and on request/response state
surviving process boundaries; coordination is load-bearing. After:

- **Every replica is equivalent for every request.** Mutations are Postgres
  writes anywhere; no broker/socket-holder distinction, no affinity
  pressure on load balancing.
- **Replica death is a non-event.** No process holds durable-intent state in
  memory; kill −9 costs reconnection latency. Rolling restarts and
  autoscaling stop being carefully drained events.
- **Valkey-down degrades uniformly.** Today imperative ops genuinely fail
  when Valkey is down and the socket is elsewhere; after, every path is a
  Postgres write and Valkey loss means convergence latency rises to the
  poll interval, full stop.
- **What legitimately remains coordinated**: scheduler placement
  reservations (`resv:*` — real distributed mutual exclusion), presence
  keys (refreshable by the long-poll itself), a few expiry/rollout sweep
  locks. Coordination is demoted from correctness dependency to latency
  optimization.

### Costs and risks

- **Absent-then-confirm for every new declarative resource.** Volumes,
  snapshots, and checkpoints each need tombstone semantics; historically
  this is where reconciliation bugs live. Finalizers make it uniform but
  the per-resource work is real.
- **Retention.** Durable snapshot/checkpoint objects need TTL/GC answers
  (the `Job.ttlSecondsAfterFinished` lesson) that fire-and-forget RPCs never
  raised. *Answered in stage 8* — absolute `expires_at` plus a
  cluster-singleton sweep; see the stage note below.
- **Payload growth.** The sync gains volumes/snapshots/checkpoints; the
  observed report gains their full-list counterparts. The `304`/ETag fast
  path and (later) observed-state deltas are the mitigations; on dense
  hosts this is the metric to watch.
- **Wire-protocol migration.** Each conversion needs a version bump and a
  dual-mode window (control plane sends both / accepts both) per the
  established `WireProtocol.supports*` pattern. The imperative paths cannot
  be deleted until the fleet floor passes each gate.
- **Nonce durability.** Reboot/restore counters must survive agent restarts
  in the manifest store, or re-registration replays edges.
- **Budget fidelity.** Kind-differentiated stuck budgets now depend on
  `lastMutationKind` being maintained; a conservative single budget is the
  fallback if that proves fiddly.
- **Coupling.** The side-table shrinks exactly as fast as RPCs convert, and
  not faster; restore verdicts complete off responses until stage 9 lands. Sequencing below is chosen so every stage is
  independently shippable and valuable.

## Migration plan

Each stage ships alone, behind the standard wire-version gates where the
agent is involved.

1. **Conditions block** in VM/sandbox DTOs — pure projection of existing
   columns; frontend starts preferring it.
2. **`resource_events`** append-only audit; mutations dual-write. Unblocks
   STR-15 attribution independently.
3. **Finalizers column** + agent-absence as first participant; then move
   IPAM / DNS / floating-IP cleanup in one at a time.
4. **202 → `{resource, targetGeneration}`**; operations API becomes a
   façade.
5. **Volumes declarative** (6 messages) — the clearest durable noun, the
   biggest single win; retires its operation kinds and `VolumeService`'s
   await-response path.

   *Amended in implementation (STR-148):* this stage shipped as a **hard
   cutover** rather than the dual-mode window the costs section below
   anticipates. The six messages are deleted outright at wire v31, and
   `supportsVolumeSync` gates *placement*: a volume is never scheduled onto an
   agent that cannot converge it. The dual-mode alternative — keeping the
   imperative path alive per-agent behind the 202 — was rejected because it
   would have preserved every hand-rolled status revert this stage exists to
   delete, for the duration of a fleet upgrade. The cost is that volumes
   already sitting on a pre-v31 agent freeze until it is upgraded; deleting one
   still works, because the delete path force-clears the agent-absence
   finalizer for an agent that cannot confirm.

   The conversion also required a fix outside its own scope. An image-backed
   VM's spawn path treated `VMSpec.volumes` as a *fallback* it never reached,
   and `respawn` rebuilds a guest from the configuration captured at create
   time — so a hot-plugged disk silently vanished at the next power cycle while
   the control plane still called the volume attached. "Attachment is desired
   state" cannot converge over that, so the agent now keeps a durable
   attachment record and merges it into the spawn configuration.
6. **Drop imperative `agent_update`** (one caller; declarative path exists).
7. **`volume_info` → observed report.**
8. **Snapshots and checkpoints as desired artifacts** (retention design
   included).

   *Amended in implementation (STR-150):* this stage shipped as a **hard
   cutover**, following stage 5's precedent rather than the dual-mode window
   the costs section anticipates — and for a sharper version of its reason.
   Keeping the imperative path alive per-agent would have preserved the
   RPC-and-verdict background halves this stage exists to delete, including the
   one that had to *guess*, after a lost response, whether a checkpoint it could
   not see existed. `volume_snapshot`, `volume_snapshot_delete`,
   `vm_checkpoint`, `vm_snapshot_delete`, `sandbox_snapshot_create`,
   `sandbox_snapshot_delete` and `sandbox_snapshot_export` are deleted outright
   at wire v32.

   Where the gate sits differs from stage 5, because an artifact has no
   placement decision to gate: it inherits its parent's host. `supportsSnapshotSync`
   therefore gates **capture admission** — `POST .../snapshots` against a
   pre-v32 agent is refused with `409`, exactly as the pre-v22/v9 capability
   preflights already did, one floor higher. Artifacts already sitting on such
   an agent freeze until it is upgraded; deleting one still works, because the
   delete path force-clears the agent-absence finalizer for an agent that cannot
   confirm.

   Three shapes are worth recording, because each answers a question the issue
   raised rather than a detail of the code:

   * **The three families share one desired/observed pair**, kind-tagged, rather
     than three. A volume snapshot, a VM checkpoint and a sandbox snapshot
     differ only in which backend captures them and what metadata comes back;
     identity, the generation guard, the absent-then-confirm dance and the
     export placement fact are the same shape three times over. They stay three
     *tables* — three quota paths, three IAM node types, three very different
     completion budgets — and share behavior through a protocol.
   * **A capture is a create strategy** (`DesiredSnapshotCapture`), read only
     while the artifact is absent from the host. That is the whole safety
     property: without it, a level-triggered entry carrying "pause this guest
     and copy its RAM" would re-checkpoint a running VM on every replayed sync,
     over the point in time the user is holding. Checkpoint-and-stop writes both
     halves — the capture mode on the artifact, the lasting intent on the
     sandbox's own desired status — because the first alone would last exactly
     until the next level-triggered pass.
   * **The captured metadata moving onto the observed report is not relocation.**
     An RPC reply is delivered once, so both old paths had to treat a dropped
     socket as a protocol error and mark a checkpoint that in fact existed
     `.error`. A report is re-sent on every heartbeat, so the same facts arrive
     again until the control plane has them.

   **Retention** is answered by an absolute `expires_at` per artifact, resolved
   at creation from a per-request `ttlSeconds` or the fleet default
   (`SNAPSHOT_DEFAULT_TTL_SECONDS`, unset — so an upgrade changes nothing until
   an operator opts in), swept by a cluster-singleton pass that issues the same
   delete an operator would, attributed to the `system` actor. Absolute rather
   than relative, because a TTL re-evaluated against "now" on each pass drifts
   with every restart and an artifact whose expiry keeps moving never expires.
   Count-based retention ("keep the last N per parent") is deliberately *not*
   implemented: it needs a per-parent ordering a delete has to re-evaluate
   transactionally, and the interesting failure — a snapshot deleted out from
   under a fork that depends on it — is one the lineage guard already refuses.
   Time is enough to bound the leak; count can be layered on without changing
   the artifact model.

   The agent keeps a **durable record** of what it captured
   (`SnapshotRecordStore`), for the reason `VMManifestStore` exists: a
   Firecracker checkpoint's fork-layout version and CPU template are not
   recoverable from its files at all, and a qcow2 internal snapshot's footprint
   costs a subprocess per artifact per report. It inherits the same caveat — an
   artifact deleted out of band reports present until something tries to use it —
   which is affordable because every backend's deletion is idempotent.
9. **Reboot/restore nonces** (3 messages).
10. **Pull transport + broadcast doorbell**; delete targeted nudges and the
    four-way sync-routing branch. The `agent:{name}:replica` routing key
    itself moves to stage 11: imperative RPC still reads it to forward an
    exchange to the socket holder and to fail fast when nobody holds it, and
    a broadcast can express neither a reply nor an immediate "offline".
11. **Delete** `ResourceOperation`, its coordinator, sweep, and the pending-
    request apparatus when only façade reads and stream RPCs remain.

Stages 1–4 are safe even if the program stops there. Stage 10 can move
earlier if multi-replica pain justifies it; it only requires stage 5–9
*conversions* for the full bridge deletion, not for its own value.

## Alternatives considered

- **Keep push, add a version doorbell on the WebSocket.** Keeps the entire
  routing directory and targeted-nudge machinery; only shrinks payloads.
  Rejected as the weak form of the change.
- **Make the version counter load-bearing** (agent fetches only when told
  the version changed). Rejected: a missed bump anywhere in the wide
  assembly scope silently strands an agent — strictly worse than today's
  backstop. Versions are `304` fast paths only.
- **Cache assembled payloads in Valkey.** Rejected: assembly has write
  side effects (grants) and mints fresh credentials; caching serves stale
  credentials and records grants for undelivered syncs.
- **Convert streams too** ("a console session should exist"). Rejected as a
  category error: session lifetime is a browser tab, not cluster intent,
  and per-keystroke state has no business in Postgres. Kubernetes ships
  five streaming subresources unapologetically; the uniformity worth having
  is authorization, which Cedar already provides.
- **Keep `ResourceOperation` alongside conditions.** Rejected: it is a
  hand-maintained materialized view of `observedGeneration >= generation`,
  and its remaining jobs (attribution, webhook tx, budgets, mutex) all have
  cheaper homes — see Decision 5. The "operation already pending" mutex is
  deliberately dropped where level-triggering makes overlapping writes
  safe, retained only where genuinely needed (e.g. resize-during-create).

## References

- Issues #260/#261 (reconciliation loop), #412 (`ResourceOperation`
  generalization), #427 (`restoreFrom` create-strategy pattern), #434
  (`DesiredAgentUpdate`), #493/#562 (SVID-mTLS artifact downloads and
  grants), #559 (webhooks), #564 (checkpoints), #855 (session store split);
  STR-15 (JWT-SVID attribution).
- `docs/architecture/wire-protocol.md`, `docs/architecture/multi-replica.md`
  — both require updates as stages land.
- Kubernetes precedents: streaming subresources, `rollout restart`
  annotation nonce, `Job`/CSR durable-request objects, finalizers,
  `status.conditions`, non-persisted subresources (`TokenRequest`,
  `eviction`).
