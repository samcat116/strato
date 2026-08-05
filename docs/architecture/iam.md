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
           └── Snapshot  (volume, sandbox, or full-VM checkpoint; references
                          its subject by attribute, not as a parent)
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
| **2 — Guardrails** | Ceilings on what tier 3 can grant | Org/folder admins | Eval; explained at write time |
| **3 — Grants** | Role bindings (+ conditions, not yet implemented) | Customers | Eval |

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
A guardrail is assembled from a fixed matcher vocabulary — the builder — or,
since #610, written directly as a Cedar `forbid`:

| Field | Vocabulary |
|---|---|
| attach node | `organization`, `organizational_unit`, `project` — containers only |
| actions | exact registry actions, `service:*`, or `*` (empty ⇒ `*`) |
| principal match | `any`, `user`, `group`, `external_to_organization` |
| resource match | `any`, `environment` |

**`cedar_text` is the compiled source of truth (#610).** Guardrails join roles
and authored policies on the same model: a write sends **either** the matchers
(the server assembles the forbid) **or** a hand-written `cedarText` — both at
once is a `400`, the same XOR roles enforce for `actions`/`cedarText`. Either
way the stored `cedar_text` is what the policy-set cache compiles verbatim under
`guardrail-<id>`, so what is stored, shown, and enforced is one string. An
`authored` flag records which input produced the row; on an authored row the
matcher columns are inert placeholders and the Cedar text is the whole story. A
hand-authored forbid is held to the guardrail shape — forbid-only, resource
scope contained inside the attach node (the same containment `PolicyStore` gives
an authored policy, but the target is the attach node), and not self-locking —
and compiled against the live schema at write time, so Cedar's own errors are a
`400`, not a row the cache drops at boot (`GuardrailText`). Rows written before
the migration carry a null `cedar_text`; the cache regenerates those from the
matchers, so a ceiling is never missing merely because the column is unfilled.

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
  irrecoverably. For an **authored** guardrail the check is structural and
  deliberately conservative — it fires only on the clearest self-lock
  (unconstrained principal, no conditions, an action scope that could reach
  `iam:setPolicy`). A cleverly conditioned authored forbid can still fence out
  policy administration, but a guardrail is managed by admins of its attach node
  *or any container above it*, so a lower one is always removable from above;
  only one at the org root is truly stuck.
- Guardrails can be **disabled** without being deleted. Ceilings get switched
  off to unblock an incident far more often than they get removed, and the row
  is the record of what was in force.

Evaluation (`GuardrailStore.forbidding`) returns *every* ceiling in the way,
not the first: otherwise removing one guardrail looks like it will unblock a
request the next one still blocks. What shipped in phase 2 was the store and
these semantics; since cutover, guardrails compile into the evaluator's
policy set (#480) and sit on the enforcement path of every request.

### The write-time ceiling report (shipped, #484)

On a tier-3 binding write, run the symcc analysis: which guardrails narrow the
grant it creates? Every one of them comes back with the response, naming the
guardrail, who set it, and what it takes back:

```
201 Created
{ "ceilings": [{
    "guardrail":        "organization/Acme/no-prod-for-contractors",
    "setBy":            "alice@acme (organization admin)",
    "explanation":      "grants editor on project resources tagged \"prod\"
                         to principals in group \"contractors\"",
    "ceilingedActions": ["vm:create", "vm:delete", "vm:update"]
}] }
```

Denying at eval time is correct but produces a mystery; explaining at write
time is what an analyzable policy language buys. Eval-time enforcement is what
*enforces* — the write-time pass only reports. The analysis runs only on
binding/guardrail writes — rare and latency-tolerant — never on the request
path.

**It reports; it does not refuse (STR-110, #864).** It refused until STR-110,
and the two rules disagreed: the evaluator subtracts the ceilinged actions and
leaves the rest of the grant working, while the write-time check rejected the
whole binding over a single overlap. Since roles are broad action groups, one
`forbid vm:stop` on an organization made `operator`, `editor` and `admin`
ungrantable everywhere beneath it — an identical binding was legal to *hold*
and illegal to *create*, and an admin adding a narrow ceiling silently lost the
ability to onboard anyone above `viewer`. Ceilings only subtract, at both ends;
the information the analysis produces is worth surfacing, not worth blocking on.

**What is asked, and of whom.** Bindings are not policies here — they arrive as
`context.grants` (see the Cedar encoding below) — so `GuardrailWriteReport`
first writes the proposed binding as the `permit` it amounts to, then asks
symcc whether that permit and the guardrail (re-emitted as a `permit` — the
solver-facing projection of `GuardrailRendering`, which carries the same
action and resource clauses as the compiled forbid by construction) can both
allow one request. Non-disjoint means the ceiling narrows the grant, and the
counterexample is a concrete request that would be granted and forbidden at
once.

The question is split deliberately:

- **The principal side is resolved from the database**, not symbolically.
  Group and org membership are facts; a solver told nothing about them assumes
  every principal *might* be in every group and reports ceilings that touch
  nothing. A group binding is checked against the group *and* its members,
  because that is how the ceiling reaches them at evaluation time.
- **The action side is resolved from the registry**, which is finite —
  paying a solver for an answer already in `IAMRoleRegistry` would be waste.
- **What is left is genuinely open, and is what symcc decides**: can a resource
  exist beneath *both* the binding's node and the ceiling's attach node,
  carrying the attributes the ceiling matches on? That question does not depend
  on which overlapping action is asked about, only on the resource type, so the
  enumeration is one query per reachable resource type per candidate guardrail
  — complete, not sampled.

**Matcher ceilings only (#610).** The write-time report runs against
matcher-built guardrails. An authored guardrail's principal side is free-form
Cedar this analysis cannot resolve against the database, and resolving it
symbolically would make the solver invent memberships it was never told about
(the very thing the principal-side split above exists to avoid) — so rather
than name a ceiling on a guess, authored ceilings rely on eval-time
enforcement, which is exact and always in force. The trade-off is that an authored ceiling gives no *write-time*
explanation; the eval-time denial still names it. `who-can`, whose queries are
concrete, reflects authored ceilings exactly without a solver — see below.

**Best effort.** `IAM_SYMCC_SOLVER_PATH` (or `cvc5` on `PATH`) names the SMT
solver; the control-plane image ships one. With no solver, a write is accepted
with an empty `ceilings` list and the failure logged: the report is an
explanation, and enforcement never depended on it. (It failed *closed* while it
still refused writes — with nothing being refused there is nothing to fail
closed about.) Readiness deliberately does not depend on it either: a solver
outage should cost explanations, not cycle every replica.

**Two carve-outs**, both at the call sites — neither runs the analysis at all:

- **Creator bindings** on resource create. The create was already authorized
  through the evaluator, guardrails included, and a solver round trip on every
  resource create is exactly the request-path cost this design rules out.
- **Provisioning** (OIDC claim sync, SCIM, invite redemption, bootstrap). It
  runs at sign-in, where there is no one to read the explanation and no
  response body to carry it.

**Both directions are accepted, and each reports the other.** Subtracting from
existing grants is precisely a ceiling's job, and a ceiling that could not be
imposed until every grant beneath it had been cleaned up first would be useless
during the incident it was written for — so a guardrail write returns the
bindings it now shadows (`shadowedBindings`). A binding write returns the
ceilings that narrow it (`ceilings`). Same relation, both directions, and each
write is logged with what it changed.

The same machinery proves the role-nesting invariant in CI
(`RoleNestingSubsumptionTests`): `check_implies` over the compiled role
policies, in both directions, so `viewer ⊂ operator ⊂ editor ⊂ admin` is
verified rather than assumed.

## Grants (tier 3)

### The bindings table is the policy store

Customers write role bindings through a template plus a fixed condition
vocabulary (`mfa`, `ip_range`, `expires_at`, `tags`/`environment`) — never
free-form Cedar text. Of that vocabulary **only `expires_at` is implemented**;
see "Conditions are not implemented yet" below.

```
(principal_type, principal_id, role, node_type, node_id,
 condition, expires_at, created_by, created_at)
```

- Principals: users, groups, service accounts, and registered workloads
  (issue #491). The machine principal types hold nothing by membership — no
  groups, no orgs — so every grant they have is an explicit, listable binding,
  and an external-principal guardrail always covers them.
- Nodes: any tree node — Org, Folder, Project, or an **individual resource**.
  Resource-level bindings exist from day one.
- Many-to-many. The one-parent rule constrains *resources*, never principals.
- **Which nodes have a write surface.** Org grants go through the org members
  API, project grants through the project members/groups APIs, and folder
  grants through `/api/organizations/{orgID}/ous/{ouID}/members` and
  `…/groups` (STR-109) — the endpoint that makes "this team administers
  everything under `engineering`" expressible as one grant instead of an
  org-wide role or a copy per project. Resource-level bindings are still
  written only by the creator-binding path; there is no customer-facing
  endpoint to author or revoke one individually.
- **Every binding has a nullable `expires_at`.** TTL is a property of the
  grant primitive, and it is enforced — expiry is applied at *read* time by
  `QueryBuilder<RoleBinding>.active()`, on every path that *decides* from
  bindings, rather than by a sweep. The write and sweep paths deliberately do
  not filter: `grant` must find an expired row to refresh rather than duplicate
  it, and revoking one must still delete it.
- Bindings are written in the same database transaction as the resources they
  protect — **and removed in it**. The table carries no foreign key to the node
  it names (an id there may be a resource the database never joins against), so
  nothing reclaims a binding whose node is gone: each delete path revokes its
  own node's bindings, including the child nodes that cascade with the row —
  `RoleBindingService.revokeAll(nodeType:nodeID:)`, or `ResourceBindingCleanup`
  for VMs and sandboxes, whose snapshots go with them. A path that forgets
  leaks rows permanently (STR-112). It is also why **node ids are never
  reused**: with UUIDv4 they cannot be, and an orphaned binding on a recycled
  id would silently start granting again.

### Conditions are not implemented yet (STR-108)

The `condition` column exists so the vocabulary above needs no schema change,
but **nothing compiles a condition into the Cedar `when` clause**. The entity
slice therefore *skips* any binding carrying one — flattening it as if it were
unconditional would turn a restricted grant into an open one — so a conditioned
binding grants nothing at all.

That is fail-closed, and it stays as defence in depth. What was missing was any
signal at the write boundary: a conditioned row referenced a live role, was
unexpired, sat on the right node, and was indistinguishable from a working
grant in every members/bindings listing while conferring no access. So the
schema now refuses it — `CHECK (condition IS NULL)`, installed by
`RejectConditionedRoleBindings`, which also deletes any pre-existing
conditioned row (they granted nothing, so no access changes) and logs the
count. No API ever exposed the field; direct SQL was the only way in.

Environment- and MFA-shaped restrictions are expressible today, just one tier
up: a custom role's advanced `cedarText` may carry arbitrary `when` clauses
(see "Roles are rows"), and guardrails can fence an environment from above.
Binding-level conditions become real work the day someone compiles them —
until then the constraint is what keeps the gap from looking like a feature.

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

A few actions are deliberately in **no** seeded role: `project:create` (bare
org membership grants it), the identity-plane `user:*` set and
`agent:updateArtifact` (reached through the tier-1 policies), and in-guest
execution — see below.

Roles are **global** (one set across all resource types), not per-service;
narrow per-type roles can be added later if needed. This is deliberately not
GCP's basic-roles mistake: membership is a curated, reviewable schema change —
new actions join roles by explicit decision, never by default. (Ceilings are
the opposite: subtractive and automatically covering, per tier 2. The
asymmetry is intentional.) The implication-nesting direction is verified with
symcc subsumption checks in CI (`RoleNestingSubsumptionTests`, #484); it is
easy to get backwards.

Today's environment roles (`environment_manager`, deployer, approver) are
expressed as an environment-scoped restriction rather than a role per
environment, consistent with environment-as-attribute. The intended end state
is a **conditioned binding** (e.g. `editor` on a project where
`resource.environment == "staging"`); until conditions are implemented
(STR-108, above) the same restriction is written as a custom role whose
advanced `cedarText` carries the `when` clause, bound normally.

### In-guest execution is never in a default role (#804)

Running a command inside a VM's guest is two actions, `vm:exec` (interactive
session) and `vm:runCommand` (non-interactive, output captured), and **no
seeded role carries either**. They are reachable only through a custom role
somebody wrote on purpose, or through the tier-1 `platform-system-admin`
policy.

Both are root-on-VM. That is not the shape of `vm:start`, and folding them into
`editor` — or even `admin` — would mean a binding written at the org for one
reason silently conferring a shell on every VM in every project beneath it,
including projects created long afterwards. An org admin can still reach exec;
they hold `iam:setPolicy` and can author the role. The difference is that they
have to do it, and the binding row is then a listable answer to "who has a
shell on this fleet, and who gave it to them". That is the substance of
"granted explicitly rather than inherited", without a second inheritance rule
that would apply to one action and confuse every reader of the other hundred.

The split between the two is about **attribution, not privilege**.
`vm:runCommand` is not a lesser `vm:exec` — a one-shot `sh -c` is a shell. What
differs is what the platform can say afterwards: a non-interactive run carries
its command in the request body and its output in a stored operation record, so
each invocation is a discrete, attributable row, while an interactive session
is a byte stream the control plane never parses. Two actions let an
organization say "automation may run recorded commands here, humans may not
hold unrecorded shells"; one action cannot express that. Both ride the `vm`
service group, so an existing `vm:*` ceiling covers them with no edit.

Sandboxes keep a single `sandbox:exec` (in `operator`), and the asymmetry is
intended: a sandbox is an ephemeral, project-scoped unit of compute that exists
to be executed in, and its whole lifetime is the blast radius. A VM is a
durable machine holding durable data.

**Both route shapes derive the verb.** `AuthorizationMiddleware` maps a
method and path to a permission for the two resource-mapped prefixes, and its
defaults are weaker than in-guest execution: an unlisted POST subpath falls
back to `update`, an unlisted GET to `read`. That matters because the two
halves arrive in different shapes — the interactive attach is a WebSocket
*upgrade*, so a GET (`…/exec/:sessionID/attach`, generalizing the sandbox
route), while the recorded run is a POST under `…/actions/run`. So the verb
list is consulted for GET as well as POST, and an `/actions/<verb>` subpath is
read one segment deeper. Without the first, an exec WebSocket would be gated on
`vm:read` — a *viewer* permission; without the second, on `vm:update`. Neither
backstop would have complained: the verb list never fired on a GET, and the
`assertHandlerEvaluated` check returns early for GET and for
`.switchingProtocols`. A GET whose subpath is not a registered verb (`/status`,
`/operations`, `/console`, snapshot listing) still reads.

### Roles are rows, defaults included (shipped with #604/#605)

The four roles above are not a Swift enum: they are rows in `iam_roles`,
seeded with fixed well-known ids and reconciled from the code registry at boot
(`RoleRegistrySync`). Custom roles are ordinary rows alongside them. One
machinery, so a custom role compiles, binds, and shows up in `who-can` exactly
the way `admin` does.

A row's `cedar_text` is the source of truth for what it grants — compiled into
the policy set verbatim under the id `role-<row uuid>` — and its `actions`
column is *derived* from that text on every write, never sent by the client.
The derivation parses the policy and reads its action scope off Cedar's EST
(`CedarPolicyInspector`), so a role cannot say one thing to the evaluator and
another to the catalog or the editor.

**Ownership scopes a role.** `owner_type` is `platform` (the seeded defaults,
with a zero-UUID sentinel owner), `organization`, or `project`. A role is
bindable on its owner and everything beneath it, and nowhere else — the same
containment the ancestor chain already gives bindings and ceilings. Deleting
an org or project removes the roles it owns.

**The role API** (`/api/iam/roles`, issue #605) is admin-gated on the owner
(`iam:readPolicy` / `iam:setPolicy`), the same gate guardrails use. A write
takes **either** an action list — the server generates the canonical permit —
**or** hand-written `cedarText` for the cases an action list cannot express
(`resource.environment == "staging"`, an MFA condition). Advanced text is held
to the role shape, and only that shape:

- **permit-only** — a `forbid` here would be a ceiling invisible to the
  guardrail API;
- **unconstrained principal scope** — bindings decide who holds a role;
- **enumerable action scope** (`action in [...]`, all from the registry) — an
  action list that silently grew with the next release is exactly what the
  curated registry exists to prevent;
- **its own grants fields, both of them** — the permit must be gated on this
  role's bindings and no other role's, or it would grant to everyone.

Everything else is left alone, and the candidate is compiled against the
schema the store *would* have once the row exists, so Cedar's own errors
surface as a `400` at the write instead of as a role that silently grants
nothing after the next boot. `POST /api/iam/roles/validate` runs the same
preparation without saving (the editor's compile button), and
`GET /api/iam/actions` publishes the action vocabulary — grouped by service,
with each action's applicable resource types and the default roles carrying
it — so the picker can never offer something the write path would reject.

Seeded roles are immutable through the API (`403`): they are reconciled from
the code registry, and an edit would be reverted at the next boot. A role with
live bindings cannot be deleted (`409` with the count) — dropping it would
silently revoke whatever those bindings grant, with nothing in the bindings
list to show it happened.

### Authored policies (shipped with #606)

Where a role is a permit whose principal side is decided by its bindings, an
**authored policy** is freeform Cedar an org or project admin writes directly:
a permit or a forbid, any principal, any conditions, stored in `iam_policies`
(`PolicyStore`, `POST/GET/PATCH/DELETE /api/iam/policies`). It compiles into
the policy set verbatim under the id `policy-<row uuid>`, beside the role
permits and guardrail forbids, and its `effect` column is *derived* from the
text (`CedarAuthoredPolicyInspector` reads it off the EST) rather than sent by
the client. Decision logs attribute an authored policy to the `policy` tier on
either side of a verdict — an authored forbid that denied, or an authored
permit that allowed — though a guardrail forbid still outranks it in
attribution.

**Containment is the one structural rule (v1).** The policy's resource scope
must name a concrete entity — `resource == X` or `resource in X` — that sits
inside the owner's subtree: the named resource's ancestor chain has to include
the owner node. So a project admin can hand out (or fence off) access within
their project and nowhere else, and an unscoped `resource` — which would reach
every resource of a type across every org — is refused. The principal scope is
unrestricted; who a grant reaches is the admin's call within their subtree,
cross-org included. This applies equally to forbids. The candidate is compiled
at write time against the live schema, so Cedar's own errors surface as a `400`
instead of the row being dropped at the next boot; formal (symcc-based)
containment analysis is #484's follow-up. `POST /api/iam/policies/validate`
runs the same preparation without saving. Deleting an org or project removes
the policies it owns.

Because a reverse lookup cannot invert an authored **permit**'s principal scope
or conditions, `who-can` reports those **best-effort**: a `policies` section
lists every enabled permit whose resource scope is on the queried node's chain
and whose action scope could cover the action (matched off the EST), and an
`authoredPolicyCaveat` flag warns that `principals` is not the whole answer
wherever such a permit is in force — someone the list does not name may also be
able to act.

**Ceilings are reflected exactly (#610).** A `who-can` query fixes the action
and the node, so a *forbid* — a guardrail or an authored forbid policy — is
concrete and needs no solver: `who-can` decides through `IAMDecisionEngine`
for each granted principal it enumerates (a non-recording pass, so the
reverse lookup does not flood the decision log) and marks the ones a ceiling
neutralises `ceilinged`, alongside a `ceilings` section naming what
constrains the resource. `WhoCanService.can` returns the same engine's
verdict outright, so it agrees with the enforcer by construction. This is why authored *forbids* left
the best-effort caveat above — only permits, which widen access, remain
un-invertible. Marking rather than filtering is deliberate: an admin auditing
"who can reach this?" needs to see both a ceilinged grant and a live one. This
is what #484 unblocked for guardrails — the symbolic machinery is for the
subtree-quantified write-time report; the concrete reverse lookup only needed the
compiled set. Guardrail DTOs also carry their `cedar_text` so the UI can show
the Cedar a ceiling compiles to.

### Membership and visibility

- **Bare org membership grants `org:read` and `project:create` — nothing
  else.** Org members do not implicitly see any project; all project access is
  via explicit bindings. (This deliberately reverses current behavior.)
- **Creating a resource writes an ordinary binding for the creator** in the
  same transaction — visible, listable, revocable. There is no implicit,
  un-revocable `owner` relation living on the resource. This also fixes
  today's quirk where a member-created project had no administrator besides
  org admins. An offboarding sweep revokes a departing user's bindings.

### Cross-org access (shipped, #485)

Cross-org access is allowed **only via explicit bindings**: a binding's
principal may live in another org. Because `forbid` always wins and cannot be
permitted through, there is no blanket platform forbid on cross-org access;
the controls are these (`CrossOrgBindingGate`):

- **Writing a binding for an external principal requires `iam:grantExternal`
  on the resource side**, evaluated like everything else — the admin role
  carries it by default, custom roles can withhold it, and a guardrail can
  ceiling it away. "External" means a user with no membership in the node's
  root org, or a group owned by another org; the root resolves through the
  same ancestor walk the entity slice uses, and a node whose chain reaches no
  org has nothing to be external to.
- **Cross-org grants are loud.** A successful external grant (and the revoke
  that ends one) is recorded with a distinct audit event
  (`iam.cross_org_grant` / `iam.cross_org_revoke`) alongside the generic
  `api.request` record, and every listing surface marks external principals
  rather than filtering them: the members and group-grants APIs carry an
  `external` flag (rendered as a prominent badge in the UI), `who-can`
  carries `principalExternalToOrg`.
- The **resource-side guardrail shape shipped in v1** so orgs can ceiling it
  themselves ("nothing in this subtree is reachable by external principals" —
  the `external_to_organization` principal match).
- The entity-slice loader and `who-can` handle external principals by
  construction (the chain's org is never a principal filter). The
  **offboarding sweeps** are external-aware in both directions
  (`OffboardingSweep`, `RoleBindingService.revokeAll(principal…)`): leaving
  an org revokes everything held *inside that org's subtree* — not just the
  org node, since a leftover project binding would silently keep working as
  ungated cross-org access — while deliberately leaving the user's bindings
  in other orgs alone (those are the other orgs' explicit grants); deleting a
  user or group sweeps its bindings across **all** orgs, never assuming they
  live only in the principal's own.

Creator bindings are the one deliberate exception to the write-time gate: a
resource created by an external principal (who necessarily already holds an
explicitly gated grant) gets its creator binding without a second
`iam:grantExternal` check — the grant that let them in was the loud, gated
one.

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
- API keys are unchanged. The short-lived-credential successor path is
  JWT-SVIDs (below), which sits alongside them rather than replacing them.

### Credential scopes are a parallel gate, to be folded in (STR-115)

API keys and CLI sessions carry a `scopes` array (`read`/`write`/`admin`)
enforced by `APIKeyScopeMiddleware` entirely outside the evaluator, with the
required scope derived from the HTTP method alone. That is this section's
invariant violated in-tree: a scoped credential is identity carrying
authorization. The consequences are concrete: `admin` is never *required* by
anything (safe methods need `read`, everything else `write`), so `read`+`write`
is full account power; a default CLI login asks for and receives `read write`;
guardrails cannot ceiling what a credential may do; and none of the canonical
narrowing use cases (a CI token for one project, a monitoring key that reads
VMs but not images) is expressible.

**Decided direction** (STR-115 is the implementation): a credential is issued
*on behalf of* a principal and optionally carries a **restriction** in the
existing action/role vocabulary — a role id, an action list, or a node scope —
and enforcement moves into the evaluator so the effective permission is
`bindings ∩ restriction`, recorded in `iam_decision_logs` with tier
attribution like every other decision. Guardrails then cover credentials for
free. The current scopes become a compatibility shim (`read` → the viewer
action set; `write`/`admin` → unrestricted) so existing keys keep working;
the bespoke three-value enum takes on no new consumers.

Until then, the one repair already made (STR-116): a scope refusal writes a
`scope_denied` row to `iam_decision_logs` naming the principal, the credential
(`api_key`/`cli_session` + id), and the missing scope — previously it was the
only authorization denial that left no decision row at all.

### The workload registry (issue #491)

SPIFFE identities become principals by **registration**, never by parsing.
The `workload_registrations` table maps each SPIFFE URI — a **lookup key**,
never parsed for claims — to what it names:

- **`agent`** — a hypervisor-node agent, by name. The agent mTLS surfaces
  (`AgentMTLSAuthenticator.resolveAgent`) resolve the verified URI through
  the registry: a first-seen agent identity is validated against the
  trust-domain/path rules and then registered; a URI registered to a
  different principal is rejected even with a valid agent path.
- **`service_account`** — a workload authenticating as a `ServiceAccount`, a
  project-scoped resource (`serviceaccount:*` actions, including
  `serviceaccount:impersonate` in the admin role) that is also a Cedar
  principal. Its project role is an ordinary guardrail-checked binding
  (`PUT /api/service-accounts/{id}/project-role`).
- **`workload`** — a directly registered customer workload; the registration
  row itself is the principal (`principal_type = workload`). Registered by
  system administrators (`/api/workload-registrations`), granted per-project
  via `/api/projects/{id}/workload-grants/{registrationID}`.

In the Cedar schema, `Workload` and `ServiceAccount` are principal types
alongside `User`: every role carries four `Grants` sets (users, groups,
service accounts, workloads) and role permits are `is`-guarded per principal
type. The membership-shaped platform policies (`platform-system-admin`,
`org-membership`) are `principal is User`-scoped — machine principals hold
only what bindings give them.

### JWT-SVIDs as programmatic credentials (issue #495)

Registered workloads present a **JWT-SVID** as a bearer token to authenticate
on the HTTP API — the request-path authentication of machine principals the
registry could describe but nothing could exercise. Unlike an X.509 SVID it
survives hops that cannot carry a client certificate (load balancers,
TLS-terminating ingress), which is what makes it usable from CI and
automation; that same bearer property is why its reach is narrow by
construction:

- **Verification** (`JWTSVIDVerification`, `JWTSVIDAuthorityStore`): the
  signature must chain to the trust domain's *current* JWT authorities, read
  from the SPIRE server's bundle API and cached for
  `SPIFFE_JWT_BUNDLE_REFRESH_INTERVAL`. There is no background refresh task:
  the cached set expires and the next request re-fetches it, and a token
  naming a `kid` we do not hold forces an immediate re-fetch (rate-limited),
  which is how key rotation is picked up without a restart. Concurrent
  fetches collapse onto one in-flight request, so a cold cache under load
  dials SPIRE once rather than once per request. Only asymmetric algorithms
  are accepted; an HMAC "signature" would be forgeable by anyone holding the
  public JWKS.
- **Audience**: the token must name this control plane (`SPIFFE_JWT_AUDIENCE`,
  default `spiffe://<trust-domain>/control-plane`). A token minted for another
  relying party is rejected even though its signature is good.
- **Identity, not authorization**: the verified `sub` is a lookup key into
  `workload_registrations` and nothing else. A valid SVID for an unregistered
  identity authenticates as **nobody** (401); a registered one becomes an
  ordinary Cedar principal whose access is whatever its role bindings say.
  No claim in the token grants anything.
- **Agents are refused**: an identity resolving to `kind = agent` cannot be
  used as an API credential (403). Agents authenticate the transport with
  mTLS and are not Cedar request principals; accepting a bearer token for one
  would create an API principal out of an identity minted on every hypervisor
  node.

The request path generalized with it: `Request.actingPrincipal` is the seam,
and `req.can` / `req.authorize` / `req.canFilter` and the default-deny
middleware all ask for it rather than for a `User`. The evaluator itself
needed no change — it has taken a typed `IAMPrincipal` since #491.

Two surfaces stay user-only, and say so with a 403 rather than a confusing
401: the **self-scoped identity plane** (`/api/api-keys`, `/api/users/me`,
`/api/oauth` — "my keys" has no referent for a service account) and
**`requireSystemAdmin()`**, since system administrator is a property of a user
record. A machine principal's organization scope, for the collection-level
"are you anyone in this org" checks, comes from where it was registered — a
service account's project's organization, or a workload registration's
organization — never from membership, which machine principals do not have.

**Reads today, mutations still user-only.** Listing and reading VMs and
sandboxes (and every handler that authorizes purely through the evaluator)
works for a machine principal. The async-mutation endpoints do not:
`resource_operations.user_id` is a non-null *user* id that names the
initiator, and operation visibility falls back to "the initiator may read it"
once the resource row is gone. A machine principal has no user id to put
there, so those handlers refuse with a 403 naming the reason rather than
recording a misleading initiator. Widening them needs a principal-typed
initiator column (`principal_type` alongside `user_id`) plus the matching
change to the initiator-fallback check — a schema change deliberately kept
out of this one.

Off by default (`SPIFFE_JWT_SVID_AUTH_ENABLED`): it widens the credential
surface from mTLS-only to bearer tokens accepted, which is an operator's
decision. Requires `SPIRE_ENABLED` and `SPIRE_SERVER_API_ADDRESS`. Identities
in **per-org trust domains** are not accepted yet — the control plane only
holds the platform domain's JWT authorities — so those workloads continue on
X.509 mTLS.

On the agent side, `WorkloadAPISPIFFEClient` implements the full JWT-SVID
profile (`FetchJWTSVID` / `FetchJWTBundles` / `ValidateJWTSVID`); the
file-based SVID source refuses all three rather than pretending an empty
answer is a valid one.

Still future: per-org trust domains for JWT-SVID auth, and the impersonation
*flow* (minting short-lived credentials) behind the already-modeled
`serviceaccount:impersonate` permission.

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
  every change to the platform policy, the guardrails, or the role store
  appends a row carrying a monotonic `version`, the reason, and who made it.
  For roles that means role CRUD (`/api/iam/roles`), the boot-time
  reconciliation of the seeded rows, and the org/project delete cascades that
  remove owned roles — each inside `withPolicySetChange`, each bumping only
  when something actually changed, so a rolling deploy of an unchanged
  registry is silent.
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
  `environment` matches the resource). The `Context` shape is declared;
  nothing populates the ambient half yet, which is why binding conditions are
  unimplemented (STR-108) — a role's or guardrail's own `when` clause is what
  carries a condition today.
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
  skipped and counted, never flattened — flattening one would widen it. Since
  STR-108 the schema refuses to store one, so the count stays zero and the skip
  is defence in depth against a row written against an older schema.
- **Guardrails compile to `forbid` policies** (`GuardrailRendering`), one
  per row, id `guardrail-<row id>` so a denial names its ceiling. The attach
  node becomes `resource in <node>` over the chain's parent edges;
  `external_to_organization` compiles against the attach node's resolved org.
  The compiler can emit forbids and nothing else. `GuardrailRendering` owns
  *every* rendering of a guardrail row — this compiled forbid, the write-time
  check's solver-facing permit, and the structural match the store and
  who-can use — as projections of one parsed representation, so the three
  cannot drift.
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

`who-can` *enumerates* from `role_bindings` plus the resource tree — an
ancestor walk (`IAMResourceTree`) and a group expansion — because a reverse
query against an evaluator means enumerating every principal and checking
each; against tables we own it is a bounded set of indexed reads. This is what
the one-parent invariant buys. What each enumerated candidate can *actually
do* is then decided by `IAMDecisionEngine` — the single evaluator shared with
enforcement — so the tables explain grants while the engine has the last word
(the `ceilinged` marks, and every `WhoCanService.can` verdict).

Because not every grant is a binding, each answer carries the reason it was
included — `binding` (with the role, the node it was granted on, and the group
it was inherited through), `orgMembership` (the two membership-derived
actions), or `systemAdmin`. A principal appears once per distinct grant, since
revoking access means revoking all of them. Principals from other orgs are
reported, not filtered: cross-org access is exactly what most needs to be
visible.

Reading who holds access is itself administrative — both endpoints require
admin over the resource or a container above it.

Both forms of `can-i` answer from the evaluator — exactly what gates
requests, guardrails included, with no admin fast path (a forbid can deny an
admin, so short-circuiting to "true" could lie). The caller-scoped form is
the enforcement path itself (`req.can`, which records a decision-log row) and
accepts IAM action names plus legacy (SpiceDB-era) permission names
translated the same way `req.can` translates, until clients finish migrating.
The arbitrary-principal form (`WhoCanService.can`) decides through
`IAMDecisionEngine` without recording, plus the reachability gates a real
request would have hit first: a disabled or nonexistent principal answers
`false`, and a *group* — a binding subject that never makes a request —
answers from its bindings minus the matcher guardrails that can name one.

### Decision logs (shipped with #481; the reverse shadow retired with #483)

Before cutover, SpiceDB gated requests and Cedar shadowed it. Cutover (#482)
reversed the direction: **Cedar gates requests inline** — `IAMDecisionEngine`
decides (the one evaluator, shared with `who-can`), `IAMAuthorizer` enforces
and records — and every decision lands in `iam_decision_logs` with the
deciding policy ids, the policy-set version, and the tier. Through the rollback window —
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
  Cedar-native form — is recorded off the request path, queued for a batching
  drain.
  `IAM_DECISION_LOG_ENABLED` controls whether rows are written at all; it
  defaults on everywhere except `.testing`, where hundreds of unrelated
  controller tests would each pay a background insert per check for rows
  nothing reads (the IAM suites that assert on rows opt in).
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
  not off the connection pool: a row still costs a connection, against a
  Fluent pool that defaults to one connection per event loop. It used to cost
  one background task and one single-row insert *per check*, so a VM create —
  three authorizations — spawned three inserts competing with the create's own
  queries; the wait for a connection, up to ~530ms on a loaded host, is what
  the traces showed (#736). Decisions now go through `IAMDecisionQueue`: a
  bounded buffer (`IAM_DECISION_LOG_MAX_QUEUE_DEPTH`, default 2048) drained by
  a single task that writes each batch (`IAM_DECISION_LOG_MAX_BATCH_SIZE`,
  default 128) as one multi-row insert. Recording therefore holds at most one
  connection at a time, and the batching is self-regulating: an idle drain
  writes each row as it arrives, a drain waiting on a connection accumulates,
  so rows coalesce exactly when the pool is contended. Overflow is shed and counted
  rather than queued without limit, so a saturated queue is a number rather
  than a latency regression in the request path. The drain runs with no
  service context: it outlives the request that started it and carries other
  requests' rows, so its inserts form their own trace instead of nesting under
  one arbitrary `iam.authorize` span. Shutdown flushes the queue before
  Fluent's pools close.

Since cutover the system-admin bypass is gone from the middleware and
`req.can`: admins are allowed by the `platform-system-admin` policy inside the
evaluator, so their decisions appear in the log (`AuditMiddleware` derives its
admin-bypass marker from the determining policy ids) and tier-2 guardrail
forbids bind them like everyone else. The controller-local admin
*object-check* skips that briefly survived the cutover are gone too, so every
per-object decision — admin or not — flows through the evaluator, and the
middleware's handler-evaluated assertion covers all users. What legitimately
remains admin-conditional in controllers:

The query-level list widenings that survived cutover — the "list twins" of
`platform-system-admin`, where a list endpoint skipped per-row checks for
admins — are gone as well. They returned the same rows the evaluator would
have allowed, but they returned them *without asking*: no decision-log row,
and, more seriously, no tier-2 guardrail. A guardrail forbidding `site:view`
in an organization bound an admin on `GET /api/sites/:id` and not on
`GET /api/sites`. Every list endpoint now filters per row through `req.can`
for every caller, admins included.

The pre-cutover audit looked for handler-level *allows* that bypassed the
evaluator, so it could not see the other shape of the same gap: a list that
never asked at all. The container lists — projects, folders, quotas, and the
hierarchy tree, search and resource dumps under `/api/organizations/:id` —
gated on `view_organization` and then returned everything inside the
organization, which is exactly the `inherited_member` behaviour the invariant
above deliberately reverses: bare membership let you enumerate every project
name, description, folder and VM count in the org while every individual
`GET /api/projects/:id` answered 403 (issue #870). They route through the
evaluator now — projects and quota rows in STR-116, folders, the hierarchy
tree, its resource dumps and both search routes in STR-113 — on
`project:read` / `folder:read` / `vm:read` / the quota's own scope.
**Reaching a container is not reaching its contents**: an organization-level
gate says the caller may see the container, and each row inside it is still a
decision of its own. `docs/architecture/authorization-edge-audit.md` carries
the per-endpoint table and what remains open.

Two things the fix has to keep apart, because collapsing them is how the leak
happened: the query **bound** and the **gate**. A bound derived from
membership rows decides too — silently, by never putting a row in front of the
evaluator — which is the same defect pointing the other way, and it costs a
caller rows they hold a real grant on. So a bound has to come from the
caller's grants (`ProjectVisibility`) wherever the gate can see further than
membership does.

What legitimately remains admin-conditional in controllers, in exactly two
shapes:

- **Admin-only platform surfaces** (hierarchy validate/repair, audit events,
  decision logs, workload identity, the policy-set version, org listing, user
  invites, scopeless quota/pool/enrollment/agent rows): these have no node in
  the IAM tree to attach a policy to. They gate through
  `req.requireSystemAdmin()`, which can only deny, never widen, and which
  marks the decision so the admin audit trail and the default-deny handler
  assertion both see it. Its list-side companion,
  `req.allowsScopelessPlatformRow()`, returns the same verdict as a Bool for
  the one-row-at-a-time case.
- **Rows scoped to their initiator**: `GET /api/operations/:id` after the
  underlying resource is deleted, and `/api/api-keys`. Row scoping, declared
  with `req.markRowScopedAuthorization()`.

- **The list-scoping narrowing** in `ProjectVisibility` (issue #688). The
  project-scoped list endpoints (`/api/volumes`, `/api/networks`,
  `/api/security-groups`, `/api/floating-ips`, `/api/dns-zones`, and since
  issue #870 the project-scoped rows of `/api/quotas`) used to load every
  project in the installation and evaluate each one; they now derive a *superset* of the
  caller's reachable projects from their own grants and narrow the row query to
  it, then decide each project the surviving rows land in through `req.can` as
  before. An admin holds no bindings, so a bindings-derived superset would be
  empty and would hide rows the evaluator allows — hence the one
  `isSystemAdmin` read, which skips the narrowing entirely. It can only widen
  what reaches the evaluator, never what the evaluator allows, so a guardrail
  forbidding `project:read` narrows an admin's list exactly as it does anyone
  else's.

Nothing else reads `User.isSystemAdmin`. The two business-rule exemptions that
used to — an agent hosting another tenant's workloads, and explicit
agent-artifact overrides — are policy now (see below), and the identity plane
is an ordinary resource type.

### The identity plane is a resource type

A user record is `IAMNodeType.user`, a Cedar resource as well as a principal.
`UserController` used to spell its rule as
`currentUser.isSystemAdmin || currentUser.id == userID` — a decision the
evaluator never saw. Both halves are tier-1 policies now:

- `platform-user-self` — `permit (principal is User, action in [user:read,
  user:update, user:delete], resource is User) when { principal == resource }`.
- `platform-system-admin` covers anyone else's record, as it does everywhere.

Consequences worth knowing:

- A user node is **parentless**. Users belong to organizations as a set
  (`memberOfOrgs` on the principal entity), which the tree's one-parent
  invariant cannot express, so nothing inherits down to a user record and
  `IAMResourceTree.ancestors` returns a one-element chain that counts as
  complete. `iam:*` actions exclude `User` for the same reason: a binding or
  guardrail attached to a user record could never grant or deny anything.
- **Known gap:** guardrails therefore cannot ceiling `user:*`. A guardrail
  attaches to a node and compiles to `resource in <node>`, and nothing is ever
  `in` a user record, so an org-scoped forbid on `user:delete` does not fire.
  Pinned by `AdminExceptionPathTests` so the gap stays a decision on record.
  Closing it means giving users a place in the tree, which multi-org
  membership rules out today; the alternative is a guardrail shape whose
  resource side is a type rather than a container.
- `GET /api/users` filters per row on `user:read` like every other list
  endpoint, so a non-admin gets a 200 listing themselves rather than a 403.
- `POST /api/users` (invite) stays on `requireSystemAdmin()`: the record does
  not exist yet and a user has no container to check instead.
- In the entity slice a self-check merges principal and resource into one
  entity. Two entries under one UID would shadow `systemAdmin` and
  `memberOfOrgs` and silently break both tier-1 policies. Conversely, a user
  standing as the resource must carry those required attributes too, or the
  whole entity store fails schema validation and the check fails closed.

### Agent restrictions as policy

Two agent rules used to live in `AgentController` as admin-only escalations.
Both are policy now, so they show up in the decision log and a custom role or
guardrail can move them:

- **`platform-agent-foreign-workloads`** — a `forbid` on `agent:manage` when
  the agent hosts a VM, sandbox, or volume belonging to another organization
  and the principal is not a system admin. This replaces
  `requireNoForeignWorkloads`. Until placement is org-scoped (phase 2 of the
  hierarchy overhaul), a delegated org admin must not force-offline,
  deregister, or restart an agent carrying another tenant's workloads. Being a
  `forbid`, it beats every `permit` — `platform-system-admin` included, which
  is why it names `!principal.systemAdmin` explicitly.

  `Agent.hostsForeignWorkloads` costs a workload inventory, so the entity-slice
  loader fills the attribute in only for the actions
  `IAMRoleRegistry.agentForeignWorkloadGuardedActions` names — the same
  constant the policy's action list is built from, so the two cannot drift into
  a silently detached ceiling. The attribute is optional and the forbid guards
  its read with `has`, so fleet listing never pays for it. This is the only
  place an action reaches the slice loader.

  **Tradeoff:** the controller version returned a specific reason ("Agent hosts
  VMs belonging to another organization…"). A policy denial is a generic 403,
  so an org admin refused here has no inline explanation. The decision log
  names `platform-agent-foreign-workloads` as the determining policy, which is
  where to look — worth surfacing in the UI if operators trip over it.
- **`agent:updateArtifact`** — a distinct action for overriding an agent
  update's artifact URL. That binary is installed and run as the agent on the
  hypervisor host, which is a strictly larger power than `agent:manage`, so it
  gets its own name rather than riding along inside it. No seeded role carries
  it (`IAMRoleRegistry.systemAdminOnlyActions`), leaving `platform-system-admin`
  as the only thing that grants it today.

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
- `/api/users/:id` — was self-or-system-admin here; since the identity plane
  became a resource type it is an ordinary evaluator check and the route is
  `handlerChecked`, not login-only. Still pinned by `UserControllerTests`.
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

#### The request-scoped cache (shipped with #686, extended by #735)

A check reads three things from the database: the principal's group and
organization memberships, the ancestor chain above the resource, and the
bindings along that chain. The first two are the same for every check in a
request, and the resource-mapped routes ask the *same question twice* on
purpose — the middleware evaluates the path-derived check and the handler
re-checks the same triple through `Request.authorizedVM` as defense in depth.
Before #686 that cost two entity slices, two evaluations and two decision-log
rows to answer one question.

`IAMRequestCache` (`req.iamCache`) memoizes, for the life of one request:
the per-user facts (`IAMUserFacts`: system-admin flag, group ids, org ids,
seeded with the `User` the session already authenticated), the resolved
ancestor chain per node, the principal's bindings at each chain node, and the
verdict per `(principal, action, node)`. A memoized verdict still sets the
audit flags — a consulted decision is one the request acted on — but is not
counted as a second decision or logged again; its span carries `iam.cache_hit`
so the double-check stays visible in a trace.

The bindings memo (#735) is what carries the saving across a request's
*distinct* questions, which the verdict memo can never help with. A VM create
asks three different questions — `org:read` on the organization, `image:read`
on the image, `vm:create` on the project — whose chains all pass through the
same org and mostly the same project, and each check used to re-read
`role_bindings` for those shared nodes. Bindings are role-shaped and
action-free, so one `(principal, node)` entry serves every check whose chain
passes through the node (cached as value snapshots, `IAMBindingFact`, not
model rows); only pairs no check has seen yet reach the query, and a later
check whose chain is fully covered — the create's third — loads its slice
without touching the database at all.

Staleness is not a hazard here: a mutation landing mid-request cannot make a
decision already made wrong, because the request was authorized against the
state it read. Nothing is cached beyond the request, so grant and revoke stay
free of invalidation machinery.

Two related shapes fall out of the same pass. The ancestor walk now returns
the leaf row's IAM-relevant attributes (`IAMLeafFacts`: `environment`, and a
network's project/site nullity) instead of discarding the row and re-reading
it for each attribute — one read of the leaf per check, and one place that
knows which resource types carry an environment. And a folder chain resolves
in at most two queries rather than one per level: the materialized
`organizational_units.path` prefetches the rows the walk is about to need,
while the parent pointers stay authoritative, so a stale path costs a query,
never a wrong chain.

#### Batch decisions (shipped with #687)

The cache above makes a *repeated* question free, but a list endpoint asks a
different question per row — `GET /api/vms` asks "may I read this VM?" once per
VM — so a hundred rows meant a hundred full evaluations and a hundred
decision-log inserts.

`IAMDecisionEngine.decide(_ targets:action:built:cache:on:)` decides a whole
batch of `(principal, node)` questions at once, and `Request.canFilter(_:on:)`
is the list-scoping sugar over it: hand it the page's nodes, get back the
subset the caller may act on. Cedar evaluation itself never needed batching —
it is pure CPU over an entity store already in memory — so all of the work is
in `EntitySliceLoader`, where every read became set-based:

- Ancestor chains resolve in one **lockstep walk**: each level of the tree is
  one query per node type in the frontier, for the whole batch at once.
  `IAMResourceTree.resolve(_ nodes:)` is now the only walk, and the
  single-node form is a batch of one — there is no second chain builder to
  drift from it.
- Principal memberships load in three queries however many principals the
  batch names (which is what makes who-can's ceiling marking, N principals on
  one node, cost what one principal costs).
- Bindings along every chain come back in **at most one query** (none when
  the request cache already holds every `(principal, node)` pair, #735), its
  predicate grouped as `(type, id-set)` pairs so a hundred-VM page is a
  handful of OR terms rather than a hundred.

The number of queries therefore depends on the *shape* of a batch — tree depth
and node types — not its size: scoping twenty-five VMs costs exactly what
scoping one costs, which `IAMBatchDecisionTests` asserts by counting queries
rather than by timing an endpoint.

Decision rows are batched to match: a batched authorization enqueues one
gated background task that writes the whole page as one multi-row insert.
Spawning a row per item is what used to push a large list into the recording
gate's shed ceiling — a hundred tasks each queueing for one of four slots.

The single-question forms (`decide(principal:action:node:)`,
`EntitySliceLoader.load(principal:node:)`, `IAMAuthorizer.authorize(…node:)`)
are all batches of one. Agreement between a batched list decision and the
per-object check it links to is therefore structural rather than a property
two code paths have to maintain — and it is pinned by tests over a mixed grid
of principals, actions, and node types all the same.

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
   `IAM_DECISION_LOG_MAX_QUEUE_DEPTH` / `IAM_DECISION_LOG_MAX_BATCH_SIZE`),
   and the decision-log API keeps the historical
   `spicedbPermission`/`spicedbDecision` field names for compatibility
   (`spicedbDecision` is always `none` on new rows).

   **Upgrade constraint:** a deployment must pass through the phase-5
   cutover release — whose boot-time backfill exported the resource-level
   `owner`/`editor`/`viewer` tuples from SpiceDB into `role_bindings` —
   before upgrading past #483. Releases after #483 no longer carry the
   SpiceDB export, so skipping the cutover release would silently drop
   resource-level grants that existed only in SpiceDB.
7. **Payoff features.** The symcc write-time guardrail analysis **shipped** —
   every grant comes back naming the ceilings that narrow it; see "The
   write-time ceiling report" above. Still ahead: policy simulator, workload
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
