# Control Plane Code Architecture

The control plane is a Swift 6 / Vapor 4 application under `control-plane/`
(SwiftPM package `strato`). It owns the API, the database (the only durable
truth), the scheduler, authorization, and the agent WebSocket. This page maps
the code for contributors; the system-level design lives in
[overview](./overview.md), [multi-replica](./multi-replica.md),
[scheduler](./scheduler.md), and [wire-protocol](./wire-protocol.md).

## Targets and layout

Two targets under `control-plane/Sources/`:

- **`App`** — the executable. Boot files at the top level
  (`entrypoint.swift`, `configure.swift`, `routes.swift`), then:

  | Directory | Contents |
  |---|---|
  | `Controllers/` | ~43 `RouteCollection` structs, one per resource area (`VMController`, `SandboxController`, ...); WebSocket endpoints suffixed `WebSocketController` |
  | `Models/` | ~65 Fluent models plus `…DTOs.swift` bundles |
  | `Migrations/` | ~154 `AsyncMigration`s, verb-named (`Create…`, `Add…To…`, `Backfill…`, `Drop…`) |
  | `Services/` | ~69 service files (actors/structs), plus `SCIM/` and `SPIFFE/` subdirectories |
  | `IAM/` | The authorization engine: `IAMAuthorizer`, the Cedar encoding (`Cedar/`), `RoleRegistry`/`RoleBindingService`, the guardrail store, `WhoCanService`, decision recording — see [iam](./iam.md) |
  | `Middleware/` | The request pipeline: auth, rate limiting, audit, authorization |
  | `OpenAPI/` | The OpenAPI-generated handler surface (issue #583): `ProjectsAPIService.swift` implements the project routes generated from `Sources/App/openapi.yaml` (scoped by the generator config's `filter`) |
  | `Extensions/` | `Request+…` per-object authz helpers, `Application+LazyService.swift` |
  | `Telemetry/` | Static metrics facade (`Telemetry.…`) |

- **`SPIREServerAPI`** — a small library holding the hand-written SPIRE
  gRPC client and its generated protobuf, kept separate so generated code
  stays out of `App`. It reaches the SPIRE server either in plaintext (the
  local admin socket, or a loopback TCP bridge in front of it — the compose
  topology) or over mTLS to the server's network TCP endpoint, presenting
  the control plane's own SVID fetched from the SPIFFE Workload API
  (`SPIFFE_ENDPOINT_SOCKET`; the Kubernetes topology, where the entry must
  carry `admin = true`).

Tests are swift-testing, split across four targets by domain —
`AppIdentityTests`, `AppIAMTests`, `AppResourceTests`, `AppPlatformTests` —
over a shared `AppTestSupport` fixture library. The split is a build-time
one: a module's `-emit-module` job is single-threaded and re-runs whenever any
file in it changes, so one 59k-line target cost ~9.8s on every test edit
against ~2.4s for the four targets in parallel. Keep them roughly balanced.

## Boot sequence

`configure.swift` is the single boot function; its ordering is load-bearing:

1. Instance identity (per-process `replicaID`) and the **background task
   registry** — registered first so nothing can spawn untracked work.
2. **Middleware chain** (outermost→innermost): request logging,
   `TracingMiddleware` (one server span per request) and `MetricsMiddleware`
   (RED metrics per route), security headers, sessions
   (+ `User.sessionAuthenticator()`), bearer API-key authenticator,
   `ServiceContextRestoringMiddleware` (re-binds the trace context the
   future-based session middleware severs, so downstream spans nest under
   the request span), rate limiting, audit, API-key scoping, user-security
   (SSF revocation enforcement), and `AuthorizationMiddleware` — the
   structurally default-deny authorization gate, which runs in every
   environment including tests.
3. **Coordination and sessions**: two Valkey-backed stores, configured
   separately because their failure contracts are opposites (issue #855).
   `ValkeyCoordinationStore` fails open — flushing it degrades convergence, not
   correctness — while losing session storage logs every user out. Coordination
   reads `VALKEY_*`; sessions read `SESSION_VALKEY_*` and fall back wholesale to
   the coordination endpoint when unset, so they share one client unless the
   endpoints differ. Startup fails hard if either is missing or unreachable.
   Under `.testing`: `InMemoryCoordinationStore` + Fluent sessions. Session keys
   carry an idle TTL (`SESSION_TTL_SECONDS`, default 7 days) that every read
   slides, and the driver skips the write-back when a request left the session
   data unchanged.
4. Secrets encryption, registry client, WebAuthn, Postgres (with TLS), then
   ~154 ordered migrations and `autoMigrate()`. Migrations run at startup;
   there is no separate migrate step.
5. Post-migration convergence: the Cedar policy set is compiled at its
   current version, stored secrets are re-encrypted, and `role_bindings` are
   backfilled from the relational mirrors (org members, project
   members/grants) — each runs every boot and no-ops when converged.
6. Scheduler registration (`app.useScheduler`), SPIRE configuration, OTel
   bootstrap, and lifecycle handlers (agent heartbeat monitor, hourly audit
   retention, SSF polling).

Services are exposed via lazy accessors
(`Extensions/Application+LazyService.swift`): `app.scheduler`,
`app.coordination`, `app.agentService`, etc.

## Key services

The important ones to know when navigating `Services/`:

- **`AgentService`** (actor) — the socket owner: agent registration,
  heartbeats, message correlation, the sync/report entry points, and all
  periodic sweeps. `WebSocketManager` (same file) tracks which sockets this
  replica holds.
- **`DesiredStateAssembler`** (`app.desiredStateAssembler`) — assembles the
  full authoritative `DesiredStateMessage` for one agent straight from
  Postgres (VM/sandbox specs, network scope, security groups, floating IPs,
  registry material, agent-update payload, per-VM instance metadata). Pure
  assembly; when to sync and which socket carries it stay with `AgentService`.
- **`ObservedStateApplier`** (`app.observedStateApplier`) — folds an agent's
  `ObservedStateReport` into the database: observed status/generation, the
  convergence transitions, deletion-by-absence, guest info, reservation release,
  and the teardown verdicts described below. The connection half (decode,
  ownership check, agent-row refresh, per-agent ordering) stays with
  `AgentService`.
- **`ResourceMutation`** — accepts one asynchronous lifecycle mutation on a
  VM, sandbox or volume: controllers name a transition and a dispatch strategy,
  and it applies the desired-state change, stamps the convergence deadline,
  appends the attribution event and hands off to the agent, all in one
  transaction. It reaches agents through the `AgentDispatch` seam
  (`agentIsOnline`, `syncDesiredState`), which `AgentService` implements and
  tests replace with a fake. (This is what `ResourceOperationCoordinator` was;
  the coordinator went with the operations table in STR-152.)
- **`CoordinationService`** (actor) — the Valkey layer: agent presence keys,
  singleton sweep locks, placement reservations, image-download grants, and the
  fleet-wide desired-state doorbell. See [multi-replica](./multi-replica.md).
- **`ReplicaMessageBridge`** (actor, `app.replicaBridge`) — the cross-replica
  seam over `CoordinationService`: the broadcast doorbell and the subscription
  lifecycle. Delegates acting on a doorbell back to `AgentService` via
  `ReplicaBridgeDelegate`. See [multi-replica](./multi-replica.md).
- **`SchedulerService`** (actor) — placement decisions; see
  [scheduler](./scheduler.md).
- **`IPAMService`** — control-plane IP allocation (IPv4/IPv6) from a
  `LogicalNetwork`'s subnets, plus floating (external) IPv4 addresses from
  `FloatingIPPool` ranges (issue #344).
- **`QuotaEnforcementService`** — reserve/release quota against project,
  folder, and org at VM/sandbox create/delete.
- **`VMSpecBuilder` / `SandboxSpecBuilder`** — assemble the
  hypervisor-neutral specs sent to agents.
- **`VolumeService`**, **`ImageFetchService`/`ImageValidationService`**,
  **`ImageObjectStore`** (where image bytes live — filesystem or S3-compatible,
  selected by `IMAGE_STORAGE_BACKEND`; see `storage.md`),
  **`RegistryClientService`** (OCI tag resolution + pull tokens for sandboxes).
- **`DNSZoneService` / `DNSZoneAssembler`** — zone CRUD and network
  attachment, plus the on-demand derived ∪ authored assembly of a zone's
  contents (never stored); see [dns](./dns.md).
- **`ConsoleSessionManager` / `SandboxExecSessionManager`** — bridge frontend
  WebSockets to the agent socket for consoles and sandbox exec.
  `ConsoleSessionManager` carries both of a VM's consoles: the serial console
  upgrades in one step (`GET /api/vms/:id/console`), while the graphics console
  (issue #566) is minted and attached in two — `POST /api/vms/:id/console/vnc`
  returns a single-use session, and `GET …/console/vnc/:sessionID/attach`
  upgrades it. The split exists for error reporting: a display can be
  unavailable because the VM was created headless (409), because its agent is
  too old to realize one, or because its socket is held by another replica
  (503), and each deserves a status code rather than an unexplained disconnect
  after the upgrade. Both directions of both consoles run through a serial
  pump, since a task-per-frame relay can transpose frames — merely ugly on a
  terminal, unrecoverable for RFB.
- Identity/compliance: `WebAuthnService`, `OIDCIdentityService`,
  `AuditService`, `SSFService`, the `SCIM/` handlers, and the `SPIFFE/`
  services (SPIRE identity validation and registration).
- Hierarchy/reporting: `OrganizationAccessService` (the org list filter used
  by list endpoints), `HierarchyTreeBuilder` and friends,
  `QuotaUsageService`/`QuotaComplianceService`, `ProjectStatsService`.
- **`HierarchyMaintenanceService`** — backs the system-admin-only
  `GET /api/hierarchy/validate` and `POST /api/hierarchy/repair`. The org tree
  is stored twice: as relational parent links and as the materialized `path` /
  `depth` each folder and project carries. The links are the source of truth
  (authorization walks them), so validation re-derives every path from them and
  reports the rows that disagree, plus parent cycles and missing parents;
  `repairOptions.rebuildPaths` rewrites what it found. Drift is otherwise
  invisible — a folder move that rewrote only descendant *folders* left the
  projects beneath naming an ancestor they no longer had (STR-114).

## Request lifecycle: `POST /api/vms`

The canonical mutation path (`Controllers/VMController.swift`):

1. **Middleware** authenticates (session or API key) and
   `AuthorizationMiddleware` — structurally default-deny; every route is
   classified public / login-only / resource-mapped / handler-checked, and
   an unclassified route fails boot — evaluates the method/path-derived
   check for `/api/vms` through the Cedar evaluator (public paths like
   `/health`, `/auth/*`, `/agent/ws`, and image download URLs —
   authenticated in-handler by agent SVID or user session — are
   allowlisted; system admins are allowed by a tier-1 policy inside the
   evaluator, not a bypass).
2. The handler validates the request: image must be `.ready` and readable,
   the user needs create rights on the project (checked via `req.can` /
   `req.authorize` against the evaluator; org membership alone is not
   enough), environment and network selections are checked.
3. **One transaction** (with constraint-failure retry for IPAM races):
   quota reservation → VM row → `setDesiredStatus(.shutdown)` (bumps
   `generation`) → the convergence deadline → NIC rows with IPAM-allocated
   addresses → a **`ResourceEvent`** row (the append-only attribution record)
   → the creator's role binding on the new VM (`RoleBindingService.grant` — an
   explicit, revocable grant, transactional with the resource it protects).
   The desired-state change, the event, and the grant commit atomically.
4. The handler returns **202 Accepted** with
   `{resource, targetGeneration, mutationId}`; the client refetches the VM
   until its `conditions` say it converged.
5. The rest happens off-request on `app.backgroundTasks`: scheduling,
   placement, and a desired-state sync to the chosen agent.

Lifecycle verbs (start/stop/pause/resume/delete) follow the same shape through
`ResourceMutation.accept(...)`, which then drives a dispatch strategy in the
background. For the state-sync strategy that is the `AgentDispatch` seam's
`syncDesiredState(agentId:)`: push directly if this replica holds the agent's
socket, otherwise publish a nudge to the replica that does. A lost nudge is
harmless but not instantly repaired: the periodic sync re-sends state to dirty
agents every minute, and the unconditional full-fleet resend that catches a
lost cross-replica nudge runs every ~10 minutes.

There is **no double-submit `409`** on these verbs (STR-147). Desired state is
level-triggered, so two overlapping writes leave the last one standing and the
agent converges on it — which is what a user pressing "stop" during a slow
start actually wants.

Overlap is *serialized*, not merely tolerated. A route handler loads its
resource before the request's transaction opens and later saves the whole row,
so `accept` starts by locking the row and re-reading the columns the
reconciliation loop owns (`ConvergingResource.adoptReconciliationState`).
Without that, the mutation's stale snapshot would be written back over whatever
committed in between: `observedGeneration` would go *backwards*, un-converging
a client that was already satisfied, a `hypervisorId` the scheduler had just
assigned would be nulled, and a racing mutation's generation bump would be
silently dropped while its `202` had promised that generation. Guest telemetry
(qga view, balloon stats, exit code) is deliberately left out of the refresh:
it is re-reported on every agent poll and heals itself. The resize path
recomputes its quota delta against the committed sizing under the same lock.

`PUT /api/vms/:id` is the same shape once it touches sizing (issue #568).
`cpu`/`memory` on a **running** VM are validated against the `maxCpu`/
`maxMemory` ceilings the VM was started with (`422` naming the restart
otherwise, including when its agent predates `supportsVMResize`), reserved
against quota as a *delta*, then written with a generation bump — desired
status unchanged, since a resize is a spec change, not a power-state change
— and answered `202` with the VM and its new target generation. On a
**stopped** VM the new
sizing (and the ceilings, which the next boot re-spawns from) is simply
persisted and answered `200`. Quota accounting always follows the *current*
sizing, never the ceiling: reserving to the maximum would strand capacity
the VM may never use, and the scheduler's placement figures are the same
current values.

The same endpoint carries `balloonTarget` (issue #567 phase 2), the memory an
operator will hold the guest to. It is deliberately *not* a quota movement:
ballooning reclaims opportunistically, the grant stays committed, and the
guest takes it all back the moment the target is cleared — so only the
generation bump is shared with a real resize. The
field is doubly optional on the wire: omitting it leaves the current target
alone, while an explicit `null` clears it. Bounds are `<= memory` (a balloon
can only take memory away; growing a guest is `memory`) and a 128 MiB floor,
the point where an over-aggressive target stops being reclaim and starts being
an OOM. A running VM whose agent predates `supportsBalloonTarget` is a `422`
with no restart remedy to offer, since the target only exists on a live guest.

**Mutations settle from observed state, not from the HTTP request.** The
answer lives on the resource, as a `conditions` block
(`Models/ResourceConditions.swift`, STR-142) — converged / targetGeneration /
observedGeneration / phase / degraded. Nothing stores it: `converged` is
`observedGeneration >= generation ∧ desiredStatus.isSatisfied(by: status) ∧
failedGeneration ≠ generation`, and `phase`/`degraded` read the
`convergence_phase` / `last_error` / `failed_generation` columns that
`ObservedStateApplier` mirrors from each report (clearing them when an attempt
finally succeeds). A client refetches the resource: done is `converged` at or
past its `targetGeneration`; failed is a `degraded` whose `sinceGeneration`
equals it.

That third clause is what makes the two answers **mutually exclusive**
(STR-191). Without it both could hold at once, because the agent advances its
applied generation per *work item* and plans more than one item per generation:
a boot converges and stamps the number, then the drift-correcting resize
planned at the same number fails. `converged` is derived *from* the assigned
`degraded` rather than alongside it, so the exclusion is structural.

The same derivation answers both readers. `conditions.converged` is what a
client polls and `isConverged` is what the reconciliation paths read — the
convergence webhook edge, the stuck sweep — and since STR-191 the second is
literally the first, supplied by one protocol extension
(`ConvergenceDerived`) over a per-family `desiredSatisfied`. They were six
`conditions` properties and four `isConverged` bodies before, with doc comments
asserting they could not disagree; they had already drifted. The one deliberate
exception is `Volume.bytesAtRest`, which `canSnapshot`/`canClone` read instead:
those verbs need "nothing is mid-write", not "the last change landed", and a
volume whose resize failed has nothing to clear its `failed_generation`.

**Both outcomes are transitions, and both commit in one transaction**
(`ResourceConvergence.recordSuccess` / `recordFailure`). The write that closes
a transition is also the write that stops it being detected again —
`convergence_deadline` going nil, or `failed_generation` reaching `generation`
— so it has to commit with the `operation.completed`/`operation.failed` outbox
row or not at all. Committing the guard alone would lose the event permanently,
since nothing re-enters; on the failure side it is worse, because
`resolveForStuckOperation` would never run and the unachieved intent would
replay on every sync with the user told nothing. That is also why
`ObservedStateApplier` defers its own row save into those calls rather than
committing the agent's mirrored `failed_generation` first.

**The stuck-convergence sweep** is the backstop. Every accepted mutation stamps
`convergence_deadline = max(existing, now + budget(kind))` — a *deadline*
rather than a `lastMutationKind`, so a reboot issued during a slow create can
never shorten the create's runway, and the sweep needs no kind lookup at all.
Past the deadline the resource is marked `degraded` and its unachieved intent
realigned with observed reality. Unlike the operation sweep it replaced, it
runs **lock-free on every replica**: the write is idempotent and convergent,
and clearing the deadline is a conditional `UPDATE` that exactly one pass wins,
so the completion webhook still fires once.

**Volumes run on the same flow** (STR-148, ADR 0001 stage 5). `Volume` is a
`ConvergingResource` and a `FinalizableResource` like `VM` and `Sandbox`, with
the same generation pair, `conditions` block, `convergence_deadline` and
finalizer list, so `ResourceMutation`, the stuck-convergence sweep and the
operations façade work on one without a new branch. Create/delete/attach/
detach/resize/clone all answer `202`; the six imperative agent messages behind
them are gone, and with them `VolumeService`'s await-response dispatch, its
per-verb RPC timeouts, and the status-and-timestamp sweep that used to guess
which transitional status had been abandoned.

Two volume-specific notes. `VolumeStatus` is now purely *observed* — the
control plane never writes `attaching`/`detaching`/`resizing`/`cloning`, and
`ObservedStateApplier` derives the status from what the agent reports about the
bytes and the attachment. And `resolveForStuckOperation` reverts a failed
*attachment* but deliberately not a failed *size*: an unachieved attach left in
place replays destructively on every later sync, while the control plane does
not know what size the agent actually realized, and a desired size larger than
reality is harmless to re-attempt under the agent's own attempt cap.

**Snapshot artifacts run on the same flow** (STR-150, ADR 0001 stage 8). All
three families — `VolumeSnapshot`, `VMSnapshot`, `SandboxSnapshot` — are
`ConvergingResource`s and `FinalizableResource`s with their own generation
pair, `conditions` block, deadline and finalizer list. Capture, delete and
export answer `202`; the seven imperative agent messages behind them are gone,
and with them the background RPC-and-verdict halves in all three controllers —
including the one that had to guess, after a lost response, whether a checkpoint
it could not see existed. `VMSnapshotService` and `SandboxSnapshotService`
survived that stage carrying restore alone, and were deleted outright in stage 9
when restore became a nonce (STR-151); nothing dispatches a snapshot verb now.

They stay three tables rather than one: three quota paths, three IAM node
types, and completion budgets that differ by an order of magnitude (a qcow2
overlay is seconds; a full-VM checkpoint is the guest's whole RAM at disk
speed). What they share is a shape, carried by `SnapshotArtifactResource` so
the assembler, the applier, the retention sweep and the finalizer reap are each
written once. `SnapshotArtifactMutation` is the accept side, and
`SnapshotRetentionSweep` the `ttlSecondsAfterFinished` answer durable artifact
objects need — see [storage](./storage.md#retention).

**No verb keeps an operation record any more.** The last three — VM reboot,
and VM/sandbox *restore* — converted in ADR stage 9 (STR-151). They held out
because they are genuinely *edges*: a reboot starts and ends `running`, and
"be at checkpoint C" stops being true the moment the guest resumes, so neither
has a desired status to express it. What converted them is the `kubectl rollout
restart` shape — an edge becomes a state once **how many times it was asked
for** is part of the state. `VM.requestReboot` and `requestRestore` bump a
monotonic nonce beside the ordinary generation; the agent applies it once
against a record it keeps in its own durable manifest, and the generation bump
carries the mutation through conditions, the stuck-convergence sweep and the
webhook with no branch of its own.

The gate moved with them. `WireProtocol.supportsEdgeNonces` refuses these three
endpoints with `409` when the owning agent predates wire v34 — not to protect
the payload (a count of requests cannot be misread when absent) but to protect
the request: with no imperative frame left, a pre-v34 agent would ignore the
field and report the bumped generation as converged, so the API would claim a
restart that never happened.

**The table itself is gone** (ADR stage 11, STR-152). With nothing constructing
a `ResourceOperation`, what remained — the model and its per-kind budgets,
`ResourceOperationCoordinator`, the cluster-singleton stuck-operation sweep and
its `lock:sweep:stuck_operations` lock, the transitional-status backstop, and
the generic pending-request apparatus in `AgentService` — was deleted along with
the cross-replica RPC bridge that carried the exchanges. The completion-budget
figures survive as `OperationResourceKind.completionBudgetSeconds(for:)`, read
once at accept time to stamp `convergence_deadline`. The one non-operation half
of the old sweep, releasing volumes left attached to a VM that no longer exists
(STR-129), moved to `sweepStrandedVolumeAttachments`.

**The operations API survives as a façade** (`Services/OperationFacade.swift`),
and is now nothing else. `GET /api/operations/:id` resolves the
`resource_events` row a mutation wrote and synthesizes the status from the
resource's conditions. A client written against the old contract keeps working;
nothing about the wire shape says which source answered, which is the point.

**Delete is the one mutation the resource cannot answer for.** Its success is
the resource ceasing to exist, and a polling client's `404` means deleted,
never-existed and not-authorized alike — a dangerous thing to build into a
client, since the failure mode is a UI reporting a successful delete for a
resource the caller simply cannot see. So the reap appends a *terminal*
`resource_events` row inside its claim transaction, and the façade answers
deletes off that positive record. The `mutationId` in the `202` is what a
client polls.

A delete's verdict is judged **only** by that evidence, never by the
resource's conditions — so a delete past its deadline reads `pending`, not
`failed`, however degraded the resource looks. A slow teardown (a large disk, a
finalizer participant waiting on a detach) is not a failed one, and the
alternative is telling a user their delete failed moments before the resource
disappears anyway. The deadline still degrades the *resource*, where an
operator can see why it is slow.

**Attribution outlives the resource** (ADR 0001 stage 2). Every mutation
appends a `resource_events` row in its own transaction: the acting principal (type *and* id, so it is not restricted to
users the way `resource_operations.user_id` is), the resource kind/id/name,
the mutation kind, the target generation, and the org/project it happened in.
Rows are never updated and never swept — there is no retention policy, because
an audit trail that admits edits is not one, and a `BEFORE UPDATE OR DELETE`
trigger enforces that rather than trusting every future caller. A `phase`
column splits the request from its outcome: `requested` on every row, and
`completed` on the one the finalizer reap appends for a delete.
`ResourceMutation.accept` covers every mutation except VM and sandbox
`create`, whose retrying transactions own their own inserts and so append
their own events.

**`DELETE` never removes a row; finalizers do** (STR-144, ADR 0001 stage 3).
A delete marks desired state `.absent` and stamps the resource's `finalizers`
list — the named cleanup participants its teardown owes (`agent.absent` for a
placed workload; nothing for one that never reached an agent). Each participant
clears its own token from wherever it actually runs, and
`ResourceFinalizerService.clear` reaps the row — external cleanup, IAM
bindings, the record, quota, placement reservation
(`FinalizableResource.reap`) — when the last token goes. The token is cleared
with a single `array_remove`, never a read-modify-write, so two participants on
two replicas cannot lose each other's update, and the reap claims the row
(`SELECT … FOR UPDATE`) inside its own transaction so exactly one of two racing
clears reports the removal. Clearing the token and reaping the row are two
commits: a crash in between leaves a terminating row with an empty list, which
the participant's next trigger reaps, since clearing an already-cleared token
still reaps an empty list. `agent.absent` re-triggers on every observed-state
report; the one-shot direct path and unattended expiry deletions have no such
trigger, so `sweepOrphanedTerminatingResources` (cluster-singleton, 60s budget)
is the universal backstop — and the reason a new participant does not have to
invent its own retry.

The only participant today is the observed-state applier's confirmation of
absence — the agent-confirmed tombstone dance, now expressed as one token among
a list. Offline or unplaced workloads take the direct path, which force-clears
`agent.absent` for the same reason it always deleted directly: a dead agent
must not make its workloads undeletable. That path reports back whether the row
is actually gone; when another participant still holds it, nothing terminal is
recorded, rather than telling the client a workload is deleted while its row is
standing. `ipam.release`, `dns.deregister`, and
`fip.release` are named in the ADR but **not stamped**: each is a database
cascade today (`vm_interface_addresses` CASCADE, zone contents derived on
demand and never stored, `floating_ips.interface_id` SET NULL), and a token for
work Postgres already does transactionally would trade an atomic cascade for an
eventually-consistent one. They become participants when they gain an effect
outside the row's transaction.

**Resource list endpoints page by default** (issue #700): every list (VMs,
sandboxes, volumes, networks, security groups, floating IPs/pools, agents,
enrollments, sites, users, images, snapshots, quotas) returns a
`PagedResponse` envelope — `items` plus `total`/`limit`/`offset` — with
`limit` defaulting to 50 and capped at 500 (`Extensions/ListPaging.swift`).
Handlers fetch the SQL-scoped rows with a deterministic sort (`createdAt` or
`name`, `id` tiebreak), run the batched authorization filter, and slice the
page from the filtered result — so `total` counts exactly the rows the caller
may read, at the cost of still materializing the scoped set server-side.
Pushing the slice into SQL requires authorization-aware query scoping and is
future work.

## The agent WebSocket (`/agent/ws`)

`Controllers/AgentWebSocketController.swift` + `Services/AgentService.swift`:

- 16 MiB max frame size (desired-state syncs carry every placement on the
  agent); frames arriving before auth completes are buffered (capped at
  4 MiB) and replayed once the agent is identified.
- **Hybrid post-quantum key exchange.** The Envoy listener terminating this
  socket prefers `X25519MLKEM768` (ML-KEM-768 + X25519). The control channel
  is the one surface with real "harvest now, decrypt later" exposure — an
  attacker who records handshakes today could decrypt them retroactively —
  so the key exchange is hardened even though the SVIDs authenticating it
  live only an hour. Agents offer the group by default from swift-nio-ssl
  2.37.1; it requires Envoy >= v1.39.0, and the curve list is configurable
  via `spire.envoy.tlsParams.ecdhCurves` in the Helm chart.
- **One auth path**: SPIFFE mTLS. The XFCC header is trusted only from the
  pod-local Envoy sidecar and the certificate is re-verified against the
  SPIRE trust bundle; the SVID's SPIFFE ID names the agent, and the `?name=`
  query parameter must match it. Site and organization scope come from the
  node's enrollment row rather than from any bearer credential — there is no
  token join, so an unattested agent simply cannot connect.
- **Agents are keyed by full SPIFFE ID, never by bare name.** The connection
  map, the Valkey presence key and console/exec session ownership all use
  `spiffe://<trust-domain>/agent/<name>` (`AgentIdentity.key`), and
  `agents`/`agent_enrollments` are unique on `(trust_domain, name)`. With one
  trust domain this is invisible; with a trust domain per organization
  ([per-org trust domains](#per-organization-trust-domains)) two tenants may
  each enroll an `agent-1`, and a name-keyed map would hand one org's socket
  the other's desired state. Bare names remain what logs and metric labels
  show.
- Message dispatch switches on the envelope type: registration, heartbeats,
  observed-state reports, console/exec/log frames (see
  [wire-protocol](./wire-protocol.md) for the catalog). There is no arm for
  `success`/`error`: nothing correlates them since STR-152, and the agent
  stopped sending them at the same change.
- **Sync assembly** (`DesiredStateAssembler.assemble`) reads the
  authoritative set straight from Postgres — VMs with volumes/NICs/image
  artifacts (download URLs are mTLS-authenticated relative paths, so nothing
  expires or gets re-signed), sandboxes with pull credentials, and the
  logical networks in the agent's assembly scope — into one
  `DesiredStateMessage`. Each VM also carries the `InstanceMetadata` its
  link-local metadata service serves (hostname, project/environment, the
  site/agent placement keys, per-NIC addressing, SSH keys, user data), built
  from rows the assembly already loaded and omitted for pre-v26 agents. It
  costs no extra query per VM by design: assembly runs for every agent on
  every sync, so a per-VM read here is a fleet-wide load multiplier.
- **Observed-state ingestion** chains per-agent tasks so reports apply in
  send order; `ObservedStateApplier.apply` updates observed
  status/generation, settles convergence (success or failure, with the
  completion webhook in the same transaction), and confirms deletions by
  absence from the report.
- **Authorizing a teardown** (STR-98). An agent that holds a workload no sync
  listed reports it rather than destroying it, and the applier decides once,
  recording the verdict in `agent_workload_claims`:
  - no record ⇒ `tombstoned`, at a generation above whatever the agent last
    applied. `DesiredStateAssembler` reads those rows back out as the sync's
    `tombstones`, so an authorized teardown is the only kind there is.
  - a record on this agent ⇒ `held`. The *sync* is the bug; teardown is
    refused permanently, logged at `error`, and counted
    (`strato_workload_teardowns_withheld_total`).
  - a record on another agent ⇒ `held` too, tagged with that agent's id. This
    is the node-re-enrolled case, and it is what
    `POST /api/agents/:id/actions/adopt-workloads` consumes: it re-points only
    workloads the target agent both reports holding and the source still
    owns, so a re-identified node's VMs move without anything being
    destroyed or invented.
  Claims retire themselves when the agent stops reporting the workload, or
  when its record comes back before the teardown converges.
- **Deleting a container of workloads refuses rather than cascading.**
  `vms.project_id` is `ON DELETE RESTRICT`, so neither `DELETE /api/projects/:id`
  nor `DELETE /api/organizations/:id` can hard-delete a live VM row by cascade —
  both pre-check and both map the database's refusal onto a 409. Deleting an
  organization whose projects still hold VMs or sandboxes used to succeed; it
  now returns 409 naming the projects that block it.

## Per-organization trust domains

Each organization is getting its own SPIFFE trust domain — and therefore its own
SPIRE server — federated with the platform trust domain that holds the control
plane's identities (umbrella issue #600). The trust boundary follows the org,
not the site, so a compromised CA blast-radiuses to one tenant and org deletion
becomes CA destruction.

**Currently shipped, and dormant behind `SPIRE_ORG_TRUST_DOMAINS_ENABLED`
(default off):**

- **`org_trust_domains`** (`Models/OrgTrustDomain.swift`) — one row per org:
  the immutable domain string (`org-<shortid>.<platform-td>`, derived once from
  the org UUID), a lifecycle `phase`, `generation`/`observed_generation`, the
  server/bundle/node addresses, the cached `org_bundle_pem`, federation
  checkpoints, and a `deleted_at` tombstone. The row deliberately carries **no
  foreign key** to `organizations` and is not Fluent-soft-deletable: a
  `deleting` row is the instruction to destroy the org's CA and must outlive —
  and stay findable after — the organization it names.
- **`SPIREService` holds a trust-domain-keyed bundle map, never a union.**
  `validateCertificate` reads the leaf's SPIFFE ID *first*, uses its trust
  domain to select that domain's roots, and verifies against those alone.
  Verifying against a union would let any org's CA mint an identity in any
  other org's domain, which is exactly what per-org domains exist to prevent.
  It returns a `ValidatedSPIFFEIdentity { identity, organizationID? }`, threaded
  through `AgentMTLSAuthenticator` to the agent WebSocket and the image /
  snapshot download routes.
- **Org resolution is a registry lookup that scopes a Cedar principal, never an
  authorization claim** (see [iam](./iam.md), issue #491). The trust domain says
  whose CA vouched for the identity; the decision is still Cedar's. At
  registration it only supplies the owning scope when the enrollment carries
  none, and refuses a node whose enrollment scope belongs to a different org
  than its CA.
- **Organization lifecycle hooks** (`Services/SPIFFE/OrgTrustDomainProvisioning.swift`)
  claim the domain inside the org-create transaction and mark it `deleting` inside
  the org-delete transaction. Only the claim is flag-gated; teardown is not, so
  an organization created with the flag on and deleted with it off still records
  the intent to destroy its CA rather than orphaning the row.

- **Enrollment resolves to the owning org's SPIRE instance**
  (`Services/SPIFFE/OrgSPIREClientRegistry.swift`, issue #615).
  `AgentController.createEnrollment` asks the registry which instance owns the
  enrollment scope's organization; a folder-scoped enrollment resolves to its
  root org, because a folder has no CA of its own. A ready domain (`active`
  *and* holding a cached bundle — the same gate `SPIREService` verifies
  against) provisions against that org's own server, with the workload entry
  carrying `federatesWith: [platform-td]` so the node's Workload API hands the
  agent the platform roots it needs to verify the control plane at all. The
  bootstrap command then names the org's node-attestation address and passes
  `--control-plane-spiffe-id` explicitly, since an org-domain agent cannot
  derive `spiffe://<platform-td>/control-plane` from its own domain.
  - Organizations whose domain is not ready yet fall back to the platform
    domain while `SPIRE_LEGACY_ENROLLMENTS` is not `false` (the default), which
    is what keeps enrollment working for every org the reconciler has yet to
    reach. Setting it to `false` makes "no new platform-domain agents"
    enforceable (phase 7).
  - **Deprovisioning resolves by trust domain, not by current organization.**
    The enrollment/agent row records the domain that was actually provisioned,
    while an agent's org can be reassigned afterwards — resolving a revocation
    by scope would aim at the wrong server, delete nothing, and report success.
    It also ignores the feature flag and accepts any phase: entries issued
    while the flag was on must stay revocable after it is switched off, and a
    domain being torn down is exactly when its entries most need removing.

Provisioning the SPIRE instances, establishing federation and caching bundles is
the reconciler's job and has not shipped yet (issue #614); until it does, no row
ever reaches `active`, so the enrollment path above always takes the platform
fallback.

## Background work

A single heartbeat-monitor loop in `AgentService` (30s tick, injectable for
tests) runs, per tick: stale-agent detection (60s threshold, skipped when a
live Valkey presence key exists), pub/sub subscription re-arming, the
periodic sync to this replica's agents (every other tick, revision-gated to
agents whose desired state changed since their last successful sync; every
20th tick — ~10 minutes — forces an unconditional full-fleet resend, the
backstop for a lost doorbell), and five sweeps — stuck convergence (STR-147),
stranded volume attachments (STR-129), orphaned terminating resources
(STR-144), expired sandboxes (TTL + retention reaping), and agent auto-update
rollout.

Most sweeps take singleton locks via `app.coordination.acquireSweepLock(...)`
(Valkey `SET NX EX`, 25s TTL, never explicitly released — the TTL expiring
is the release). Locking fails open: the sweeps are idempotent, so a
duplicate pass beats no pass.

The stuck-**convergence** sweep takes no lock at all (STR-147). Its verdict is
computed from the row and written idempotently, so replicas cannot disagree,
and the one non-idempotent effect — the completion webhook — is claimed by a
conditional `UPDATE` on the convergence deadline. That is the ADR 0001
multi-replica argument in miniature: coordination demoted from a correctness
dependency to a latency optimization.

Fire-and-forget work must go through `app.backgroundTasks.spawn { ... }`
(`Services/BackgroundTaskRegistry.swift`) — shutdown drains the registry so
in-flight DB writes finish before Fluent tears down its pools. This is also
what makes the test harness safe.

## Model and migration conventions

- Fluent models: `final class X: Model, @unchecked Sendable`, snake_case
  columns, UUID IDs.
- VM and Sandbox carry the reconciliation quartet: observed `status`,
  `desiredStatus`, `generation`, `observedGeneration`, with helpers
  `setDesiredStatus` (bumps generation), `isConverged`, and
  `revertDesiredToObserved()` (called when a mutation fails so unachieved
  intent doesn't replay). Alongside it they mirror the agent's reported
  convergence progress — `convergencePhase`, `lastError`, `failedGeneration`
  — which only `ObservedStateApplier` writes and only the `conditions`
  projection reads, plus `convergenceDeadline`, which only the mutation path
  writes and only the stuck-convergence sweep reads.
- `ResourceEvent` is foreign-key-free on *every* id it carries, since the audit
  row has to outlive both the resource it names and the principal that acted.
  It inherited the pattern from the retired `resource_operations` table, whose
  `resource_id` had to survive the row a delete removed for the same reason.
- Migrations target Postgres (raw-SQL backfills gated on `as? SQLDatabase`),
  and never query live models in a migration — snapshot the columns in a
  private model instead. Migration ordering in `configure.swift` matters when
  models select newly added columns.

## Testing

The suite runs against Postgres — the engine production uses — both
locally (any reachable server via `DATABASE_*` env vars) and in CI.

The harness (`Tests/AppTestSupport/TestUtilities.swift`) migrates **once per
test process into a template database, then clones per test** with
`CREATE DATABASE ... TEMPLATE ...`; each of the four test bundles is its own
process, so each builds its own pid-named template. `withApp { app in ... }`
boots via `configure()` against the pre-migrated clone and tears down with
`shutdownForTesting()`, which drops the clone.

The fixtures are `package` rather than `internal` because `AppTestSupport` is
a separate module: it `@testable import`s `App` and re-exports App's internal
types at package visibility, which is legal only within one package.
`BaseTestCase` is the exception — `package` classes cannot be subclassed
across modules — so it stays in `AppIdentityTests` with the suites that
inherit from it.

Authorization tests run through the **real** `AuthorizationMiddleware` and
the real Cedar evaluator against `role_bindings` rows the tests create —
there is no permissive mock in front of the decision path, so both allow and
deny paths are exercised exactly as in production. Sweeps are `internal` rather than
`private` specifically so tests can drive a pass directly, and the heartbeat
interval is injectable. `TestDataBuilder` creates users/orgs/projects/VMs/
sandboxes; migration up/down coverage lives in `MigrationRoundTripTests`.
