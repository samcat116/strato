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
  | `Controllers/` | ~31 `RouteCollection` structs, one per resource area (`VMController`, `SandboxController`, ...); WebSocket endpoints suffixed `WebSocketController` |
  | `Models/` | ~39 Fluent models plus `…DTOs.swift` bundles |
  | `Migrations/` | ~87 `AsyncMigration`s, verb-named (`Create…`, `Add…To…`, `Backfill…`, `Drop…`) |
  | `Services/` | ~50 service types (actors/structs), plus `SCIM/` and `SPIFFE/` subdirectories |
  | `IAM/` | The authorization engine: `IAMAuthorizer`, the Cedar encoding (`Cedar/`), `RoleRegistry`/`RoleBindingService`, the guardrail store, `WhoCanService`, decision recording — see [iam](./iam.md) |
  | `Middleware/` | The request pipeline: auth, rate limiting, audit, authorization |
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

Tests are a single flat `Tests/AppTests/` target (~80 files, swift-testing).

## Boot sequence

`configure.swift` is the single boot function; its ordering is load-bearing:

1. Instance identity (per-process `replicaID`) and the **background task
   registry** — registered first so nothing can spawn untracked work.
2. **Middleware chain** (outermost→innermost): request logging, security
   headers, sessions (+ `User.sessionAuthenticator()`), bearer API-key
   authenticator, rate limiting, audit, API-key scoping, user-security
   (SSF revocation enforcement), and `AuthorizationMiddleware` — the
   structurally default-deny authorization gate, which runs in every
   environment including tests.
3. **Coordination**: Valkey (`ValkeyCoordinationStore` + Valkey-backed
   sessions) in real deployments — startup fails hard if it's missing;
   `InMemoryCoordinationStore` + Fluent sessions under `.testing`.
4. Secrets encryption, registry client, WebAuthn, Postgres (with TLS), then
   ~87 ordered migrations and `autoMigrate()`. Migrations run at startup;
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

- **`AgentService`** (actor) — the largest service: agent registration,
  heartbeats, desired-state sync assembly, observed-state ingestion, and all
  periodic sweeps. `WebSocketManager` (same file) tracks which sockets this
  replica holds.
- **`CoordinationService`** (actor) — the Valkey layer: agent presence keys,
  socket routing, singleton sweep locks, placement reservations, and
  replica pub/sub (nudges + RPC). See [multi-replica](./multi-replica.md).
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
- **`ConsoleSessionManager` / `SandboxExecSessionManager`** — bridge frontend
  WebSockets to the agent socket for consoles and sandbox exec.
- Identity/compliance: `WebAuthnService`, `OIDCIdentityService`,
  `AuditService`, `SSFService`, the `SCIM/` handlers, and the `SPIFFE/`
  services (SPIRE identity validation and registration).
- Hierarchy/reporting: `OrganizationAccessService` (the org list filter used
  by list endpoints), `HierarchyTreeBuilder` and friends,
  `QuotaUsageService`/`QuotaComplianceService`, `ProjectStatsService`.

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
   `generation`) → NIC rows with IPAM-allocated addresses → a
   **`ResourceOperation`** row (`pending`) → the creator's role binding on
   the new VM (`RoleBindingService.grant` — an explicit, revocable grant,
   transactional with the resource it protects). The desired-state change,
   the operation, and the grant commit atomically.
4. The handler returns **202 Accepted** with the operation; the client polls
   `/api/operations/:id`.
5. The rest happens off-request on `app.backgroundTasks`: scheduling,
   placement, and a desired-state sync to the chosen agent.

Lifecycle verbs (start/stop/pause/resume/delete) follow the same shape via
`ResourceOperation.begin(...)` — which also enforces a 409 double-submit
guard through a partial unique index on pending operations — followed by
`dispatchStateSync`: push directly if this replica holds the agent's socket,
otherwise publish a nudge to the replica that does. A lost nudge is harmless;
the ~60s periodic sync re-sends full state.

**Operations complete from observed state, not from the HTTP request**: when
an agent's `ObservedStateReport` shows the VM's observed status/generation
caught up to desired, `completeIfPending` marks the row terminal. The
stuck-operation sweep is the backstop, failing operations past their per-kind
budget (`OperationResourceKind.completionBudgetSeconds` in
`Models/ResourceOperation.swift` — e.g. VM create 600s, boot 180s). Reboot is
the one imperative exception: it awaits a correlated agent response.

## The agent WebSocket (`/agent/ws`)

`Controllers/AgentWebSocketController.swift` + `Services/AgentService.swift`:

- 16 MiB max frame size (desired-state syncs carry every placement on the
  agent); frames arriving before auth completes are buffered (capped at
  4 MiB) and replayed once the agent is identified.
- **One auth path**: SPIFFE mTLS. The XFCC header is trusted only from the
  pod-local Envoy sidecar and the certificate is re-verified against the
  SPIRE trust bundle; the SVID's SPIFFE ID names the agent, and the `?name=`
  query parameter must match it. Site and organization scope come from the
  node's enrollment row rather than from any bearer credential — there is no
  token join, so an unattested agent simply cannot connect.
- Message dispatch switches on the envelope type: registration, heartbeats,
  correlated success/error responses, status updates, observed-state
  reports, console/exec/log frames (see [wire-protocol](./wire-protocol.md)
  for the catalog).
- **Sync assembly** (`assembleDesiredState`) reads the authoritative set
  straight from Postgres — VMs with volumes/NICs/image artifacts (download
  URLs are mTLS-authenticated relative paths, so nothing expires or gets
  re-signed), sandboxes with pull credentials, and the
  logical networks in the agent's assembly scope — into one
  `DesiredStateMessage`.
- **Observed-state ingestion** chains per-agent tasks so reports apply in
  send order, updates observed status/generation, completes satisfied
  operations, and confirms deletions by absence from the report.

## Background work

A single heartbeat-monitor loop in `AgentService` (30s tick, injectable for
tests) runs, per tick: stale-agent detection (60s threshold, skipped when a
live Valkey presence key exists), pub/sub subscription re-arming, the
periodic full sync to this replica's agents (every other tick), and three
sweeps — stuck operations, expired sandboxes (TTL + retention reaping), and
agent auto-update rollout.

Sweeps take singleton locks via `app.coordination.acquireSweepLock(...)`
(Valkey `SET NX EX`, 25s TTL, never explicitly released — the TTL expiring
is the release). Locking fails open: the sweeps are idempotent, so a
duplicate pass beats no pass.

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
  `revertDesiredToObserved()` (called when an operation fails so unachieved
  intent doesn't replay).
- `ResourceOperation` has a plain `resource_id` column, deliberately **not**
  a foreign key, so delete operations survive the resource row's removal.
- Migrations target Postgres (raw-SQL backfills gated on `as? SQLDatabase`),
  and never query live models in a migration — snapshot the columns in a
  private model instead. Migration ordering in `configure.swift` matters when
  models select newly added columns.

## Testing

`Tests/AppTests` runs against Postgres — the engine production uses — both
locally (any reachable server via `DATABASE_*` env vars) and in CI.

The harness (`TestUtilities.swift`) migrates **once per process into a
template database, then clones per test** with
`CREATE DATABASE ... TEMPLATE ...`. `withApp { app in ... }` (from
`BaseTestCase`) boots via `configure()` against the pre-migrated clone and
tears down with `shutdownForTesting()`, which drops the clone.

Authorization tests run through the **real** `AuthorizationMiddleware` and
the real Cedar evaluator against `role_bindings` rows the tests create —
there is no permissive mock in front of the decision path, so both allow and
deny paths are exercised exactly as in production. Sweeps are `internal` rather than
`private` specifically so tests can drive a pass directly, and the heartbeat
interval is injectable. `TestDataBuilder` creates users/orgs/projects/VMs/
sandboxes; migration up/down coverage lives in `MigrationRoundTripTests`.
