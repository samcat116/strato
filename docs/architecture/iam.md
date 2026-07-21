# IAM: Cedar-based Authorization

**Status:** design accepted 2026-07-16; migration complete. Phases 1–6 have
shipped: the embedded [Cedar](https://www.cedarpolicy.com/) evaluator is the
authoritative — and only — authorization engine, and SpiceDB is deleted
(#483). This document is the decision record for that replacement and for the
IAM design around it. Where something is marked **INVARIANT**, it is
load-bearing: violating it breaks properties the rest of the design depends
on.

The shipped system is summarized in the AuthZ section of
[overview](./overview.md); this document records why it is shaped the way it
is and the migration that produced it.

## Why we replaced SpiceDB

Strato's authorization model is **hierarchical and attribute-hungry, not
relational**. Access derives from walking *up* a shallow tree (resource →
project → folder → org). There is no user-to-user sharing graph and no
arbitrary resource-to-resource reference graph — the Zanzibar use case SpiceDB
is built for is one we don't have.

The concrete failures that motivated the decision were found in the
then-deployed SpiceDB schema (`spicedb/schema.zed`, deleted with #483):

1. **Nested-folder admins did not inherit downward.** `inherited_admin =
   parent->manage_organization + parent->inherited_admin` never includes the
   parent folder's direct `admin` relation, so an admin of a parent folder had
   no rights over child folders or the projects beneath them. (In the
   SpiceDB schema the folder type was named `organizational_unit`.)
2. **Every org member could view every project**, via `inherited_member`
   chaining through `view_organization = admin + member`.

Both are hand-rolled recursion bugs. In Cedar, hierarchy inheritance is a
language primitive (`in` is reflexive and transitive on both principal and
resource), so neither bug is expressible.

Cedar additionally gives us what SpiceDB structurally cannot:

- **Decidable, statically analyzable policies.** The guardrail mechanism below
  depends on answering "does policy set A permit anything policy set B
  forbids?" offline. The open-source
  [`cedar-policy-symcc`](https://crates.io/crates/cedar-policy-symcc) crate
  compiles policy sets to SMT and decides subsumption/equivalence, with the
  compiler formally verified in Lean.
- **A formally verified evaluator**, differentially fuzzed against the spec.
- **`forbid` semantics** with a fixed evaluation rule (below). Our SpiceDB
  schema was 100% additive; there was no way to express a ceiling.

### What we give up, and how we cover it

- **Reverse queries.** Cedar doesn't hold our data, so it can't answer "what
  can Alice see?" We answer it ourselves from the bindings table plus the
  resource tree — ordinary SQL against tables we own. This stays cheap only
  while the one-parent invariant holds.
- **A second stateful store.** We stopped operating one. Postgres is now the
  only source of truth for authorization data, which also makes grants
  transactional with the resources they protect — something the SpiceDB
  dual-write could not offer — and the reconciliation services that existed
  to repair drift between the stores are deleted.

## The shape

```
Org
 └── Folder  (nests arbitrarily; formerly "organizational unit")
      └── Project  (leaf container — never contains another Project)
           ├── VM / Sandbox
           ├── Network
           ├── Volume
           ├── Image
           └── Snapshot  (references its Volume by attribute, not as a parent)
```

- **INVARIANT: one parent per resource.** No DAG, no multi-parent inheritance.
  This keeps "who can reach X" a tree walk and keeps reverse queries cheap.
- **INVARIANT: Folders nest; Projects do not.** A Project is the unit of
  resource containment, quota, and (eventually) billing.
- **Org, Folder, and Project are themselves resources.** Permissions to
  manipulate them (`project:create`, `iam:setPolicy`, `project:transfer`) flow
  through the same evaluator as `vm:start`. There is no separate
  org-management policy system.
- Legal parentage is declared in a resource-type registry and enforced at
  write time by the API server. A violation is `400 InvalidArgument`, not
  `403` — structural illegality is a type error, not an authorization outcome.
  (The current write-time validation in `Project.validate()` /
  `ResourceQuota.validate()` already behaves this way.)
- **`environment` is an attribute on resources, not a container.** It has no
  inheritance of its own. (The vestigial `environment` object type in the
  SpiceDB schema was never populated and died with the migration.)
- Agents and Sites remain org/folder-scoped resources, as today.

**Evaluation rule — never add a clause:**

```
explicit forbid  >  explicit permit  >  default deny
```

## The three tiers

Every rule belongs to exactly one tier. The tier determines which store it
lives in and who may write it — not which language it's written in. One
language, one evaluator.

| Tier | What | Authored by | Enforced |
|---|---|---|---|
| **0 — Structure** | Legal parentage, resource types | Us (schema) | Write time → `400` |
| **1 — Platform policy** | Non-negotiable `forbid`s | Us | Eval; immutable to customers |
| **2 — Guardrails** | Ceilings on what tier 3 can grant | Org/folder admins | Eval **and** write-time check |
| **3 — Grants** | Role bindings + conditions | Customers | Eval |

## Guardrails (tier 2)

- **INVARIANT: guardrails are `forbid`-only.** A guardrail can never grant.
  Enforce structurally: the guardrail store rejects any `permit` at write
  time, not by convention.
- **The default ceiling is fully permissive.** Ceilings only subtract, so
  every new action we ship is automatically covered by existing guardrails.
- Guardrails attach to tree nodes and inherit downward. All ceilings in the
  ancestry chain apply — they **intersect**; never "nearest wins."
- Both principal-side and resource-side ceilings are the same mechanism —
  which side of the `forbid` is constrained.

### The store (shipped)

`iam_guardrails` (`GuardrailStore`, `POST/GET/PATCH/DELETE /api/iam/guardrails`).
As with bindings, customers assemble a guardrail from a fixed vocabulary rather
than authoring policy text:

| Field | Vocabulary |
|---|---|
| attach node | `organization`, `organizational_unit`, `project` — containers only |
| actions | exact registry actions, `service:*`, or `*` (empty ⇒ `*`) |
| principal match | `any`, `user`, `group`, `external_to_organization` |
| resource match | `any`, `environment` |

Notes on the shape, each of which is load-bearing:

- **Forbid-only is enforced three times over**: `GuardrailEffect` has one case,
  so a permit is not constructible in Swift; the store rejects a
  `permit`-shaped request with `400` rather than ignoring the field; and the
  table carries a `CHECK (effect = 'forbid')` on Postgres for anything reaching
  it another way. The invariant is not re-checked downstream, so it has to hold
  at the boundary.
- **Wildcards exist because ceilings must cover actions we have not shipped.**
  A `vm:*` ceiling written today still holds when `vm:migrate` lands. Exact
  action names are validated against the role registry: a ceiling that silently
  protects nothing because of a typo is this store's worst failure mode.
- **`external_to_organization` is what makes cross-org access ceilable** —
  bindings may name a principal from another org by design, and `forbid` is the
  only thing that can take that back. This is why the resource-side shape ships
  in v1.
- **Attach points are containers only.** A ceiling exists to cover what is
  beneath it; on a leaf it would be an ordinary per-resource rule wearing
  tier 2's clothes.
- **An unconditional ceiling over `iam:setPolicy` is refused.** It would outlaw
  its own removal on its own subtree. The rule keys on whether the action
  patterns *match* `iam:setPolicy`, not on the literal `*`: `iam:*` and a bare
  `iam:setPolicy` bolt the same door. Conditioned ceilings over `iam:setPolicy`
  stay legal and useful ("contractors may not set policy here") — someone
  outside the condition can still undo them. Refusing is not a view about
  strict policy — it is refusing to let one write lock an org out
  irrecoverably.
- Guardrails can be **disabled** without being deleted. Ceilings get switched
  off to unblock an incident far more often than they get removed, and the row
  is the record of what was in force.

Evaluation (`GuardrailStore.forbidding`) returns *every* ceiling in the way,
not the first: otherwise removing one guardrail looks like it will unblock a
request the next one still blocks. What shipped in phase 2 was the store and
these semantics; since cutover, guardrails compile into the evaluator's
policy set (#480) and sit on the enforcement path of every request.

### The write-time ceiling check (shipped, #484)

Before accepting a tier-3 binding, run the symcc analysis: does the grant it
creates reach anything a guardrail forbids? If so, reject the write naming the
specific guardrail:

```
403 GuardrailViolation
  guardrail: organization/Acme/no-prod-for-contractors
  set_by:    alice@acme (organization admin)
  reason:    grants editor on project resources tagged "prod"
             to principals in group "contractors"
```

Denying at eval time is correct but produces a mystery; denying at write time
produces an explanation. This is the reason an analyzable policy language was
chosen. Eval-time enforcement remains as well (attributes can change after the
binding exists). The analysis runs only on binding/guardrail writes — rare and
latency-tolerant — never on the request path.

**What is asked, and of whom.** Bindings are not policies here — they arrive as
`context.grants` (see the Cedar encoding below) — so `GuardrailWriteCheck`
first writes the proposed binding as the `permit` it amounts to, then asks
symcc whether that permit and the guardrail (re-emitted as a `permit` from the
same clause builders, so the two renderings cannot drift) can both allow one
request. Non-disjoint means a breach, and the counterexample is a concrete
request that would be granted and forbidden at once.

The question is split deliberately:

- **The principal side is resolved from the database**, not symbolically.
  Group and org membership are facts; a solver told nothing about them assumes
  every principal *might* be in every group and refuses grants no ceiling
  touches. A group binding is checked against the group *and* its members,
  because that is how the ceiling reaches them at evaluation time.
- **The action side is resolved from the registry**, which is finite —
  paying a solver for an answer already in `IAMRoleRegistry` would be waste.
- **What is left is genuinely open, and is what symcc decides**: can a resource
  exist beneath *both* the binding's node and the ceiling's attach node,
  carrying the attributes the ceiling matches on? That question does not depend
  on which overlapping action is asked about, only on the resource type, so the
  enumeration is one query per reachable resource type per candidate guardrail
  — complete, not sampled.

**Fail closed.** `IAM_SYMCC_SOLVER_PATH` (or `cvc5` on `PATH`) names the SMT
solver; the control-plane image ships one. With no solver, gated binding writes
return `503` rather than being accepted unchecked. Readiness deliberately does
*not* depend on it: a solver outage should fail the writes it guards, not cycle
every replica, and eval-time enforcement is untouched throughout.

**Two carve-outs**, both at the call sites:

- **Creator bindings** on resource create are not gated. The create was already
  authorized through the evaluator, guardrails included, and a solver round
  trip on every resource create is exactly the request-path cost this design
  rules out.
- **Provisioning** (OIDC claim sync, SCIM, invite redemption, bootstrap) is not
  gated. It runs at sign-in, and failing closed there would make an SMT solver
  a hard dependency of authentication.

**Guardrail writes are accepted, not refused.** Subtracting from existing
grants is precisely a ceiling's job, and one that could not be imposed until
every grant beneath it had been cleaned up first would be useless during the
incident it was written for. The write returns the bindings it now shadows, and
logs each one.

The same machinery proves the role-nesting invariant in CI
(`RoleNestingSubsumptionTests`): `check_implies` over the compiled role
policies, in both directions, so `viewer ⊂ operator ⊂ editor ⊂ admin` is
verified rather than assumed.

## Grants (tier 3)

### The bindings table is the policy store

Customers write role bindings through a template plus a fixed condition
vocabulary (`mfa`, `ip_range`, `expires_at`, `tags`/`environment`) — never
free-form Cedar text.

```
(principal_type, principal_id, role, node_type, node_id,
 condition, expires_at, created_by, created_at)
```

- Principals: users, groups, and later workloads/service accounts.
- Nodes: any tree node — Org, Folder, Project, or an **individual resource**.
  Resource-level bindings exist from day one.
- Many-to-many. The one-parent rule constrains *resources*, never principals.
- **Every binding has a nullable `expires_at`.** TTL is a property of the
  grant primitive.
- Bindings are written in the same database transaction as the resources they
  protect.

### Roles are global action groups

Every API operation is a named Cedar `Action` (`vm:start`, `volume:attach`,
`project:transfer`, `iam:setPolicy`, …). A **role is a named, curated action
group**; roles nest so each implies the ones below:

```
viewer   ⊂  operator  ⊂  editor  ⊂  admin
```

| Role | Contains (illustrative) |
|---|---|
| `viewer` | all `*:read`, `*:list`, `image:download` |
| `operator` | viewer + `vm:start/stop/restart/pause/resume`, `sandbox:exec` |
| `editor` | operator + `*:create/update/delete`, `volume:attach/snapshot/…`, `vm:viewConsole` |
| `admin` | editor + `iam:setPolicy`, `project:transfer`, `quota:manage`, `group:manage`, `folder:create`, `agent:manage` |

Roles are **global** (one set across all resource types), not per-service;
narrow per-type roles can be added later if needed. This is deliberately not
GCP's basic-roles mistake: membership is a curated, reviewable schema change —
new actions join roles by explicit decision, never by default. (Ceilings are
the opposite: subtractive and automatically covering, per tier 2. The
asymmetry is intentional.) The implication-nesting direction is verified with
symcc subsumption checks in CI (`RoleNestingSubsumptionTests`, #484); it is
easy to get backwards.

Today's environment roles (`environment_manager`, deployer, approver) become
**conditioned bindings** (e.g. `editor` on a project where
`resource.environment == "staging"`), consistent with
environment-as-attribute.

### Membership and visibility

- **Bare org membership grants `org:read` and `project:create` — nothing
  else.** Org members do not implicitly see any project; all project access is
  via explicit bindings. (This deliberately reverses current behavior.)
- **Creating a resource writes an ordinary binding for the creator** in the
  same transaction — visible, listable, revocable. There is no implicit,
  un-revocable `owner` relation living on the resource. This also fixes
  today's quirk where a member-created project had no administrator besides
  org admins. An offboarding sweep revokes a departing user's bindings.

### Cross-org access

Cross-org access is allowed **only via explicit bindings**: a binding's
principal may live in another org. Because `forbid` always wins and cannot be
permitted through, there is no blanket platform forbid on cross-org access;
instead:

- Writing a binding for an external principal requires a dedicated permission
  on the resource side (`iam:grantExternal`-shaped) and is loud in audit and
  UI.
- The **resource-side guardrail shape ships in v1** so orgs can ceiling it
  themselves ("nothing in this subtree is reachable by external principals").
- The entity-slice loader, `who-can`, and the offboarding sweep must all
  handle principals outside the resource's org.

## Identity

**INVARIANT: identity names the principal. It never carries authorization.**
Authentication (WebAuthn/passkeys, OIDC, sessions) establishes *who*; what
they may do is looked up in stores we can mutate in milliseconds. These parts
of the current system are unchanged by the migration:

- WebAuthn/session identity, session-epoch revocation, and the SSF/CAEP
  receiver (revocation effective on the next request).
- SCIM- and OIDC-claim-driven group/role sync is **blessed as provisioning**:
  claims mutate persistent membership/bindings at login time and are evaluated
  from the store per-request — the token itself is never a standing grant.
- API keys are unchanged for now (deferred; revisit toward short-lived
  credentials later).

Future work (post-migration): a workload registry making customer workloads
first-class principals — the SPIFFE ID is a **lookup key** into the registry,
never parsed for claims — and service accounts as resources with an
impersonation permission.

## Architecture: the evaluator is in-process

SpiceDB was a stateful network service; Cedar is a library. The migration
inverted the data flow:

- **Postgres is the only authorization store** (bindings, roles, guardrails,
  the resource tree). Consistent with the multi-replica model where Postgres
  is the sole source of truth.
- Each control-plane replica compiles the policy set once and holds it in
  memory. **The policy set is versioned**; the version appears in every
  decision log entry. Policy-store writes invalidate replicas via the existing
  Valkey nudge pattern, backstopped by periodic re-read. Bindings themselves
  are read per-request from Postgres, so grant/revoke needs no invalidation —
  a revoke is effective on the next request on every replica.

  **Versioning (shipped).** `iam_policy_set_versions` is an append-only log:
  every change to the platform policy, the guardrails, or the role registry
  appends a row carrying a monotonic `version`, the reason, and who made it.
  Allocation is `max + 1` under a uniqueness constraint, so two replicas
  bumping concurrently get two versions rather than one lost update. Version
  and change commit in the same transaction — a change without its bump leaves
  every replica serving a stale policy set with nothing to tell them
  otherwise. `PolicySetVersionCache` holds each replica's view and is the seam
  the compiled set hangs off (#480); it refreshes on the `policy-set:version`
  broadcast (a broadcast, unlike the `replica:{id}:*` channels — a policy
  change concerns every replica) and on a 30s re-read that bounds how long a
  lost message can leave a replica stale. Role *bindings* deliberately bump
  nothing, per the paragraph above.
- **The entity-slice loader** is the security-critical component: one shared
  function that gathers, per check, the resource's ancestor chain, the
  principal's group memberships, the applicable bindings along the chain, and
  referenced attributes, and hands them to Cedar. Cedar only knows what it is
  given — a missing edge is an authorization bug. It gets the heaviest test
  investment in the system.
- The Swift↔Cedar binding wraps the `cedar-policy` crate's FFI module
  (JSON-in/JSON-out) from Rust; there is no official Swift binding.

### The Cedar encoding (shipped with #480)

The schema, the static policies, the loader, and the compiled-set cache are in
`Sources/App/IAM/Cedar/`. The choices that matter:

- **The schema is generated from the role registry** (`CedarSchemaBuilder`),
  never hand-maintained: entity types (one per `IAMNodeType`, with the OU →
  `Folder` rename already in the Cedar vocabulary), the per-operation action
  inventory, and the condition vocabulary as the request `Context` (`mfa`,
  `sourceIP`; `expires_at` is enforced when bindings are read, and
  `environment` matches the resource).
- **Roles are nested action groups, lower-inside-higher**: `vm:read` is a
  member of `role:viewer`, and `role:viewer` of `role:operator`, up the chain
  — so `action in Action::"role:admin"` transitively reaches everything while
  `role:viewer` reaches only the viewer set. The direction is the easy thing
  to get backwards; `CedarSchemaTests` proves every action's group closure
  equals `IAMRoleRegistry.roles(granting:)`, which over a finite inventory is
  the subsumption check in full.
- **Per-service action groups** (`svc:vm`, …) are the compilation target for
  `service:*` guardrail patterns, so a service ceiling covers actions shipped
  after it was written.
- **Bindings enter as request data, not policies.** The entity-slice loader
  (`EntitySliceLoader`) flattens the principal's active, unconditioned
  bindings along the ancestor chain into `context.grants` (per-role user and
  group sets); the static role policies test membership in those sets. This is
  what keeps grant/revoke free of cache invalidation. Conditioned bindings are
  skipped and counted, never flattened — flattening one would widen it.
- **Guardrails compile to `forbid` policies** (`CedarPolicyAssembler`), one
  per row, id `guardrail-<row id>` so a denial names its ceiling. The attach
  node becomes `resource in <node>` over the chain's parent edges;
  `external_to_organization` compiles against the attach node's resolved org.
  The compiler can emit forbids and nothing else.
- **`CedarPolicySetCache`** holds the per-replica compiled set, reconciled on
  every `PolicySetVersionCache` refresh — the Valkey broadcast and the 30s
  re-read both funnel through it, so the cache adds no invalidation machinery.
  The hook is **level-triggered** (rebuild whenever the cached set's version
  differs from the observed one, an integer comparison when in sync): the
  version cache advances before listeners run, so an edge-triggered listener
  whose rebuild failed would wait for the *next* policy write. A failed
  rebuild keeps the previous set — stale converges within one tick, empty
  would deny everything or drop ceilings.
- **The engine itself sits behind `CedarEngine`.** Since #481 the engine is
  real: [samcat116/swift-cedar](https://github.com/samcat116/swift-cedar)
  wraps the `cedar-policy` crate via UniFFI and ships prebuilt binaries for
  Linux and Apple, so `SwiftCedarEngine` parses and strictly validates the
  schema and policy set at compile time (a set that fails validation keeps the
  previous one, per the cache's stale-beats-broken rule) and evaluates checks
  through the formally verified evaluator. Policies are parsed individually
  with their assembler-assigned ids (`role-editor`, `guardrail-<id>`, …) —
  Cedar's set parser would assign positional ids and decisions could never
  name what decided. The (role × action) enumeration that was verified against
  the crate out-of-band in phase 3 now runs in-repo through the actual engine
  (`SwiftCedarEngineTests`).

### Required APIs (day one of the new system, not v2)

1. **`can-i`** — hypothetical checks, `POST /api/authorization/check`. **Shipped.**
2. **`who-can`** — the reverse index, `POST /api/authorization/who-can`. **Shipped.**
3. **Policy simulator** — evaluate a proposed change against recorded
   historical decisions before applying.
4. **Decision logs** — every authz decision with the reason, the policy
   version, and the tier that produced it. Distinct from the mutation audit
   log; this is what makes guardrail denials debuggable. **Shipped** (#481) —
   see "Decision logs" below.

`who-can` answers from `role_bindings` plus the resource tree — an ancestor
walk (`IAMResourceTree`) and a group expansion — never from the policy engine.
A reverse query against an evaluator means enumerating every principal and
checking each; against tables we own it is a bounded set of indexed reads.
This is what the one-parent invariant buys.

Because not every grant is a binding, each answer carries the reason it was
included — `binding` (with the role, the node it was granted on, and the group
it was inherited through), `orgMembership` (the two membership-derived
actions), or `systemAdmin`. A principal appears once per distinct grant, since
revoking access means revoking all of them. Principals from other orgs are
reported, not filtered: cross-org access is exactly what most needs to be
visible.

Reading who holds access is itself administrative — both endpoints require
admin over the resource or a container above it.

Since cutover the caller-scoped form of `can-i` answers from the evaluator —
exactly what gates requests, guardrails included, with no admin fast path
(a forbid can deny an admin, so short-circuiting to "true" could lie). It
accepts IAM action names, plus legacy (SpiceDB-era) permission names
translated the same way `req.can` translates, until clients finish migrating. The
arbitrary-principal form still answers from the bindings table so it agrees
with `who-can`.

### Decision logs (shipped with #481; the reverse shadow retired with #483)

Before cutover, SpiceDB gated requests and Cedar shadowed it. Cutover (#482)
reversed the direction: **Cedar gates requests inline** (`IAMAuthorizer`),
and every decision lands in `iam_decision_logs` with the deciding policy
ids, the policy-set version, and the tier. Through the rollback window —
while SpiceDB remained deployed — each check with a SpiceDB-vocabulary
equivalent also asked SpiceDB in a background task and recorded both
verdicts, so the mismatch surface kept watching for regressions. That
reverse shadow ended when #483 deleted SpiceDB (its kill switch,
`IAM_SHADOW_EVAL_ENABLED`, went with it); the decision log stays, recording
the Cedar verdict alone. The `spicedb_permission`/`spicedb_decision` columns
— and the `spicedbPermission`/`spicedbDecision` API fields — keep their
historical names for compatibility: the former carries the
legacy-vocabulary question as asked at the check site, the latter is always
`none` on rows written after the removal. The pieces that matter:

- **Coverage is total by construction.** Every check `IAMAuthorizer`
  evaluates — the middleware's route-mapped checks, `req.can`, and the
  Cedar-native form — is recorded off the request path in a background task.
  `IAM_DECISION_LOG_ENABLED` controls whether rows are written at all; it
  defaults on everywhere except `.testing`, where hundreds of unrelated
  controller tests run against per-test SQLite files and a background insert
  per check would contend for the single writer lock (the IAM suites that
  assert on rows opt in).
- **The vocabulary bridge is explicit, audited, and load-bearing.**
  `IAMActionTranslator` maps each legacy-vocabulary check (`read` on
  `virtual_machine`, `manage_project` on `project`, …) to the IAM action
  naming the act being gated (`vm:read`, `project:update`). A check with no
  faithful mapping **fails closed** — denied, logged, and recorded as
  `untranslated` — because an unmapped pair is a check site nobody mapped,
  not an allowance; a mapping is only emitted if the action exists in the
  registry and is schema-applicable to the node. The legacy vocabulary
  outlived SpiceDB itself: `req.can` still speaks it so the ~55 handler call
  sites need not churn, and converting them to IAM action names is the
  remaining cleanup.
- **Decision rows record why, not just what**: the determining policy ids
  (which is why the engine compiles policies under their assembler ids), the
  derived tier (`platform` / `guardrail` / `grant` / `default-deny`), the
  policy-set version, the containing org, and the count of conditioned
  bindings the slice deliberately skipped. Cedar-side failures are verdicts of
  their own (`skipped`, `error`) — a replica that never compiled its set shows
  up as a wall of `skipped` rows, not silence.
- **`GET /api/iam/decision-logs`** (system-admin only) and `/summary`, which
  buckets decisions by permission, action, verdict, and tier over a bounded
  window (`?sinceHours`, default 24 — the log takes a row per check, so an
  unbounded `GROUP BY` would scan the whole retention window), are how the
  log is read. During the rollback window this is where the mismatch
  burn-down ran (`?mismatchesOnly=true`); the three *expected* mismatch
  classes — org members losing implicit project visibility, nested-folder
  admin inheritance being fixed, and conditioned bindings (which the entity
  slice deliberately does not flatten, surfacing as a non-zero
  `skipped_conditioned_bindings`) — confirmed the target semantics rather
  than refuting them.
- Rows are append-only, FK-free (decisions outlive what they describe), and
  pruned by a retention sweep (`IAM_DECISION_LOG_RETENTION_DAYS`, default 30,
  cluster-singleton via the coordination sweep lock). The sweep is armed even
  when recording is switched off, so the kill switch stops new rows without
  stranding the ones already written.
- **Recording is bounded, not free.** Recording is off the request path but
  not off the connection pool: each record holds a connection for its insert,
  against a Fluent pool that defaults to one connection per event loop.
  `IAMRecordingGate` caps concurrent recordings
  (`IAM_DECISION_LOG_MAX_CONCURRENCY`, default 4) and the queue behind them
  (`IAM_DECISION_LOG_MAX_QUEUE_DEPTH`, default 512); overflow is shed and
  counted rather than queued without limit, so a saturated gate is a number
  rather than a latency regression in the request path.

Since cutover the system-admin bypass is gone from the middleware and
`req.can`: admins are allowed by the `platform-system-admin` policy inside the
evaluator, so their decisions appear in the log (`AuditMiddleware` derives its
admin-bypass marker from the determining policy ids) and tier-2 guardrail
forbids bind them like everyone else. The controller-local admin
*object-check* skips that briefly survived the cutover are gone too, so every
per-object decision — admin or not — flows through the evaluator, and the
middleware's handler-evaluated assertion covers all users. What legitimately
remains admin-conditional in controllers:

- **Query-level list widenings** (the "list twins" of `platform-system-admin`):
  list endpoints skip per-row checks for admins at query level. Same rule the
  evaluator would apply per row, expressed as a filter.
- **Admin-only platform surfaces** (hierarchy validate/repair, audit events,
  decision logs, workload identity, scopeless quota/pool/enrollment rows,
  agent org reassignment, explicit agent-artifact overrides): these gate
  through `req.requireSystemAdmin()` — or a plain admin guard on read-only
  routes — which can only deny, never widen.
- **Business-rule admin exemptions** that gate no evaluator check, e.g.
  destructive agent actions fall back to admin-only while foreign-org
  workloads live on the agent (`requireNoForeignWorkloads`).

### Pre-cutover audit of handler-level allows (gate on phase 5)

Default-deny silently starts denying any allow decision that lives as code in
a handler rather than as a tuple, binding, or policy. A full-controller sweep
(2026-07-20) found and dispositioned every such decision; each is either
re-expressed where the evaluator can see it or consciously kept with a test
pinning it. This inventory is the input to the cutover middleware's allowlist.

**Already expressed as tier-1 policy or bindings data** (nothing to do at
cutover beyond flipping enforcement):

- System admin → `platform-system-admin`; bare org membership →
  `org-membership`; project-less network read → `platform-open-network-read`
  (its list twin: `listNetworks` ORs project-less networks into every result
  at query level — same rule, expressed as a filter).
- Resource-level `owner`/`editor`/`viewer` tuples → per-create dual-writes
  plus the boot export, whose type list covers every owner-bearing type
  including `floating_ip` and `sandbox_snapshot`.

**Re-expressed through the authorization path during the audit** (previously
inline `UserOrganization` reads — allow decisions invisible to shadow
evaluation):

- Org member management, org show/update/delete/switch, and the member list
  (`OrganizationController`) now authorize via `OrganizationAccessService`;
  `manage_members` maps to `org:update`, `view_organization` to `org:read`.
- OIDC provider management (`OIDCController`) authorizes via `req.can` with
  its own error messages. Managing a provider is org administration — it maps
  to `org:update` rather than growing an `oidc:*` action family.

**Identity-plane, deliberately outside the IAM tree** (login + row scoping;
the default-deny allowlist keeps these login-only):

- `/api/api-keys` — self-scoped by construction (phase-0 decision: API keys
  unchanged for now); another user's key is a 404. Pinned by
  `APIKeyOwnershipTests`.
- `/api/users/:id` — self-or-system-admin. Pinned by `UserControllerTests`.
- `/api/operations/:id` — falls back to "initiator may read" when the
  operation's resource is gone (delete operations outlive their resource);
  non-initiators get 404. Pinned by `VMOperationTests`.

**Defensive denies added by the audit:**

- A `ResourceQuota` with no scope FK (corrupt data — every create path sets
  exactly one) previously fell through the scope-dispatch chains and was
  readable and mutable by any authenticated user; it now requires system
  admin. Pinned by `ResourceQuotaTests`.
- The SCIM data plane (`/organizations/*/scim/v2`) authenticates an
  org-scoped bearer token in-handler with no `User` in `request.auth`; it
  needs its explicit middleware carve-out preserved by the cutover allowlist,
  like `/ssf/events/` and the agent mTLS endpoints.

### Enforcement path (shipped with #482)

Authorization is **structurally default-deny** at `AuthorizationMiddleware`:
every registered route must fall into exactly one class — **public** (the
explicit allowlist: login, health, the agent mTLS surfaces, the SCIM data
plane), **loginOnly** (identity-plane surfaces whose authorization is row
scoping by construction: API keys, users, operations, OAuth sessions, the
can-i/who-can endpoints), **resource-mapped** (`/api/vms`, `/api/sandboxes` —
the middleware itself evaluates the method/path-derived check), or
**handlerChecked** (authorized in the handler through the evaluator). A path
matching no class is denied, and `assertAllRoutesClassified` fails *boot* if
a route is registered without one, in every environment — adding an endpoint
forces a classification decision, and the whole test suite enforces it.

For handler-checked routes the middleware also asserts, after the handler
runs, that a successful **mutating** request actually evaluated a decision
(`req.can`, the evaluator, or an explicit `req.requireSystemAdmin()` /
`req.markRowScopedAuthorization()` declaration) — a hard 500 under
`.testing`, an error log in production. Reads are not asserted: list
endpoints legitimately evaluate nothing when their row scoping matches no
rows.

The system-admin bypass is re-expressed as the `platform-system-admin` tier-1
policy, so it flows through the evaluator and appears in decision logs
instead of skipping authorization entirely — which also means guardrail
forbids bind system admins. (Decision-log coverage of admin activity is near
but not total: the deliberately admin-only surfaces gate via
`req.requireSystemAdmin()`, which flags the audit trail but writes no
decision row.)

Two enforcement details worth naming:

- **A truncated ancestor chain fails closed.** A chain that does not reach an
  organization (an orphaned intermediate node, a scopeless legacy site)
  under-grants harmlessly for tier 3, but is fail-*open* for tier-2
  guardrails: a `forbid (… resource in Organization::"X")` silently stops
  matching below the break while an in-chain binding still permits. The
  evaluator denies such checks outright, loudly, before evaluation — system
  admins included; repair goes through the admin-only hierarchy
  validate/repair surface. The two rootless-by-design shapes — the
  organization itself and a global network (no project, no site) — evaluate
  normally.
- **Unmatched paths return 403, not 404**: a request outside every route
  class is denied by the middleware before Vapor's router can 404 it. A
  deliberate default-deny consequence (and mild enumeration hardening).

## Migration plan

Phases; each landed independently:

1. **Bindings groundwork (engine-independent).** Bindings table + role
   registry in Postgres, dual-written alongside SpiceDB tuples (SpiceDB
   remained authoritative). Backfill from the existing Postgres mirrors plus
   a one-time SpiceDB relationship export — resource-level
   `owner`/`viewer`/`editor` tuples existed **only** in SpiceDB and had to
   be exported before any cutover. Shipped `who-can` and `expires_at` early.
2. **Guardrail store + policy versioning.** Forbid-only by construction;
   versioned policy sets. **Shipped** — see "The store" under Guardrails and
   "Versioning" above. Guardrails are stored and evaluable but not yet on the
   enforcement path, which arrives with the evaluator.
3. **Cedar integration.** Swift binding (separate track), Cedar schema (entity
   types, action groups, binding templates), entity-slice loader, compiled
   policy-set cache with Valkey invalidation. **Shipped** — see "The Cedar
   encoding" above.
4. **Shadow evaluation + decision logs.** Every check ran through both
   engines; mismatches were logged with both verdicts and burned down against
   this document's semantics. The decision-log infrastructure was built here.
   **Shipped** (#481, including the real engine behind `CedarEngine`) — see
   "Decision logs" above. The burn-down itself was the gate on phase 5, not
   part of this phase.
5. **Cutover.** Flip `req.can` and the middleware to Cedar; default-deny
   middleware; admin bypass through the evaluator; creator bindings at create.
   **Shipped** (#482) — see "Enforcement path" above. During the rollback
   window SpiceDB kept receiving writes and answered the background reverse
   shadow, the regression watch for the cutover. The cutover release also
   exported the resource-level `owner`/`editor`/`viewer` tuples into
   `role_bindings` at boot — which is why the upgrade constraint below
   exists.
6. **Deletion.** **Done** (#483). Tuple writes, the reverse shadow (and its
   `IAM_SHADOW_EVAL_ENABLED` switch), the SpiceDB reconciliation services,
   `SpiceDBService`, and `schema.zed` are gone; compose/helm/CI no longer
   run SpiceDB. The decision log keeps its own knobs
   (`IAM_DECISION_LOG_ENABLED` / `IAM_DECISION_LOG_RETENTION_DAYS` /
   `IAM_DECISION_LOG_MAX_CONCURRENCY` / `IAM_DECISION_LOG_MAX_QUEUE_DEPTH`),
   and the decision-log API keeps the historical
   `spicedbPermission`/`spicedbDecision` field names for compatibility
   (`spicedbDecision` is always `none` on new rows).

   **Upgrade constraint:** a deployment must pass through the phase-5
   cutover release — whose boot-time backfill exported the resource-level
   `owner`/`editor`/`viewer` tuples from SpiceDB into `role_bindings` —
   before upgrading past #483. Releases after #483 no longer carry the
   SpiceDB export, so skipping the cutover release would silently drop
   resource-level grants that existed only in SpiceDB.
7. **Payoff features.** The symcc write-time guardrail check (`403
   GuardrailViolation` naming the guardrail) **shipped** — see "The write-time
   ceiling check" above. Still ahead: policy simulator, workload
   registry/principals, service accounts.

The **folder rename** (OU → folder) happens in two steps: UI/docs copy
anytime; the API/database rename is still pending (the Cedar vocabulary
already says `Folder`) — it was deliberately kept out of the migration
rather than churning the authorization types mid-flight.

## Explicitly rejected

| Anti-pattern | Where it comes from |
|---|---|
| Primitive roles that auto-absorb all new permissions | GCP basic roles |
| A separate policy language for org-level ceilings | AWS SCPs |
| Silent `AccessDenied` with no indication a ceiling caused it | AWS |
| A bypass control plane that skips the evaluator | Azure storage keys, AWS root; our former system-admin bypass |
| Roles or claims carried in identity tokens / SVIDs | — |
| Additive-only evaluation with deny bolted on later | GCP; our former SpiceDB schema |
| Nested projects; multi-parent resources | — |
| Free-form customer-authored Cedar | — |
| Silent eventual consistency on grant/revoke | — |
