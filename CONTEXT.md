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
  - *deletion* — nudge the agent when online (row removed once its report
    confirms absence), else remove the record directly.

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
- **Cross-replica RPC** — the correlated request/reply forwarding for the two
  exchanges that are *actions, not states* (volume operations, VM reboot) and
  so cannot ride the level-triggered sync. When the serving replica lacks the
  socket, the exchange is forwarded to the holder and the verdict returns on
  the requester's reply channel.
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
