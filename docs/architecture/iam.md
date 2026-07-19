# IAM: Cedar-based Authorization

**Status:** design accepted (2026-07-16), implementation starting. This document is
the decision record for replacing SpiceDB with an embedded [Cedar](https://www.cedarpolicy.com/)
policy engine and filling the IAM gaps around it. Where something is marked
**INVARIANT**, it is load-bearing: violating it breaks properties the rest of the
design depends on.

For the current (pre-migration) SpiceDB implementation, see the AuthZ section of
[overview](./overview.md); this document describes the target state and the path
to it.

## Why we are replacing SpiceDB

Strato's authorization model is **hierarchical and attribute-hungry, not
relational**. Access derives from walking *up* a shallow tree (resource →
project → folder → org). There is no user-to-user sharing graph and no
arbitrary resource-to-resource reference graph — the Zanzibar use case SpiceDB
is built for is one we don't have.

The concrete failures that motivated the decision were found in the deployed
`spicedb/schema.zed`:

1. **Nested-OU admins did not inherit downward.** `inherited_admin =
   parent->manage_organization + parent->inherited_admin` never includes the
   parent OU's direct `admin` relation, so an admin of a parent OU had no
   rights over child OUs or the projects beneath them.
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
- **`forbid` semantics** with a fixed evaluation rule (below). The current
  SpiceDB schema is 100% additive; there is no way to express a ceiling.

### What we give up, and how we cover it

- **Reverse queries.** Cedar doesn't hold our data, so it can't answer "what
  can Alice see?" We answer it ourselves from the bindings table plus the
  resource tree — ordinary SQL against tables we own. This stays cheap only
  while the one-parent invariant holds.
- **A second stateful store.** We stop operating one. Postgres becomes the
  only source of truth for authorization data, which also makes grants
  transactional with the resources they protect — something the current
  SpiceDB dual-write cannot offer — and deletes the reconciliation services
  that exist to repair drift between the stores.

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
  SpiceDB schema is never populated and dies with the migration.)
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

### The write-time ceiling check

Before accepting a tier-3 binding, run the symcc analysis: does the resulting
policy set permit anything the guardrail set forbids? If so, reject the write
naming the specific guardrail:

```
403 GuardrailViolation
  guardrail: folder/engineering/no-prod-for-contractors
  set_by:    alice@acme (org admin)
  reason:    grants editor on resources tagged "prod"
             to principals in group "contractors"
```

Denying at eval time is correct but produces a mystery; denying at write time
produces an explanation. This is the reason an analyzable policy language was
chosen. Eval-time enforcement remains as well (attributes can change after the
binding exists). The analysis runs only on binding/guardrail writes — rare and
latency-tolerant — never on the request path.

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
asymmetry is intentional.) Verify the implication-nesting direction with symcc
subsumption checks; it is easy to get backwards.

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

SpiceDB is a stateful network service; Cedar is a library. The migration
inverts the data flow:

- **Postgres is the only authorization store** (bindings, roles, guardrails,
  the resource tree). Consistent with the multi-replica model where Postgres
  is the sole source of truth.
- Each control-plane replica compiles the policy set once and holds it in
  memory. **The policy set is versioned**; the version appears in every
  decision log entry. Policy-store writes invalidate replicas via the existing
  Valkey nudge pattern, backstopped by periodic re-read. Bindings themselves
  are read per-request from Postgres, so grant/revoke needs no invalidation —
  a revoke is effective on the next request on every replica.
- **The entity-slice loader** is the security-critical component: one shared
  function that gathers, per check, the resource's ancestor chain, the
  principal's group memberships, the applicable bindings along the chain, and
  referenced attributes, and hands them to Cedar. Cedar only knows what it is
  given — a missing edge is an authorization bug. It gets the heaviest test
  investment in the system.
- The Swift↔Cedar binding wraps the `cedar-policy` crate's FFI module
  (JSON-in/JSON-out) from Rust; there is no official Swift binding.

### Required APIs (day one of the new system, not v2)

1. **`can-i`** — hypothetical checks, `POST /api/authorization/check`. **Shipped.**
2. **`who-can`** — the reverse index, `POST /api/authorization/who-can`. **Shipped.**
3. **Policy simulator** — evaluate a proposed change against recorded
   historical decisions before applying.
4. **Decision logs** — every authz decision with the reason, the policy
   version, and the tier that produced it. Distinct from the mutation audit
   log; this is what makes guardrail denials debuggable.

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

Until cutover the two forms of `can-i` answer from different stores, which is
a deliberate consequence of SpiceDB still being authoritative: the
caller-scoped form goes to SpiceDB (what actually gates requests, so
`permission` is a SpiceDB permission name), while the arbitrary-principal form
goes to the bindings table so it agrees with `who-can` (so `permission` is an
IAM action name). Phase 5 collapses both onto the evaluator and the two
vocabularies become one.

### Enforcement path

Authorization becomes **structurally default-deny** at the middleware with an
explicit public-route allowlist — replacing today's arrangement where only
`/api/vms` and `/api/sandboxes` are middleware-guarded and everything else
relies on per-handler checks. The system-admin bypass is re-expressed as a
tier-1 platform policy so it flows through the evaluator and appears in
decision logs instead of skipping authorization entirely.

## Migration plan

Phases; each lands independently:

1. **Bindings groundwork (engine-independent).** Bindings table + role
   registry in Postgres, dual-written alongside SpiceDB tuples (SpiceDB
   remains authoritative). Backfill from the existing Postgres mirrors plus a
   one-time SpiceDB relationship export — resource-level
   `owner`/`viewer`/`editor` tuples exist **only** in SpiceDB and must be
   exported before any cutover. Ships `who-can` and `expires_at` early.
2. **Guardrail store + policy versioning.** Forbid-only by construction;
   versioned policy sets.
3. **Cedar integration.** Swift binding (separate track), Cedar schema (entity
   types, action groups, binding templates), entity-slice loader, compiled
   policy-set cache with Valkey invalidation.
4. **Shadow evaluation + decision logs.** Every check runs through both
   engines; mismatches are logged with both verdicts and burned down against
   this document's semantics. The decision-log infrastructure is built here.
5. **Cutover.** Flip `req.can` and the middleware to Cedar; default-deny
   middleware; admin bypass through the evaluator; creator bindings at create.
6. **Deletion.** Remove tuple writes, the SpiceDB reconciliation services,
   `SpiceDBService`, `schema.zed`; drop SpiceDB from compose/helm/CI.
   Keep a read-only rollback window first.
7. **Payoff features.** symcc write-time guardrail check (`403
   GuardrailViolation` naming the guardrail), policy simulator, workload
   registry/principals, service accounts.

The **folder rename** (OU → folder) happens in two steps: UI/docs copy
anytime; the API/database/entity rename lands with the Cedar schema rather
than churning SpiceDB types mid-flight.

## Explicitly rejected

| Anti-pattern | Where it comes from |
|---|---|
| Primitive roles that auto-absorb all new permissions | GCP basic roles |
| A separate policy language for org-level ceilings | AWS SCPs |
| Silent `AccessDenied` with no indication a ceiling caused it | AWS |
| A bypass control plane that skips the evaluator | Azure storage keys, AWS root; our current system-admin bypass |
| Roles or claims carried in identity tokens / SVIDs | — |
| Additive-only evaluation with deny bolted on later | GCP; our current SpiceDB schema |
| Nested projects; multi-parent resources | — |
| Free-form customer-authored Cedar | — |
| Silent eventual consistency on grant/revoke | — |
