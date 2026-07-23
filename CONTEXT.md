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
