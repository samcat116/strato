# ADR 0004: Cedar replaces SpiceDB for authorization

- **Status**: Accepted — design accepted 2026-07-16; migration complete,
  SpiceDB deleted (#483)
- **Date**: 2026-07-16
- **Deciders**: Sam Schmitt
- **Scope**: the control-plane authorization engine — policy language,
  evaluator, and stores — and the migration that replaced SpiceDB
- **Related**: [`docs/architecture/iam.md`](../architecture/iam.md) documents
  how the shipped system works. This ADR records why it is shaped the way it
  is and the migration that produced it; both began as one document and were
  split once the migration completed.

## Summary

Replace SpiceDB with an embedded [Cedar](https://www.cedarpolicy.com/)
evaluator as the authoritative — and only — authorization engine. Postgres
becomes the only authorization store, which makes grants transactional with
the resources they protect, and Cedar's decidable, statically analyzable
policies are what the guardrail mechanism depends on. The migration ran as
independently landing phases — bindings groundwork, guardrail store, Cedar
integration, shadow evaluation, cutover, deletion — with the shadow-eval
mismatch burn-down as the gate on cutover. SpiceDB is deleted (#483). One
**upgrade constraint** survives it: a deployment must pass through the
phase-5 cutover release before upgrading past #483 (see phase 6 below).

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

- **Decidable, statically analyzable policies.** The guardrail mechanism
  ([Guardrails](../architecture/iam.md#guardrails-tier-2) in the architecture
  doc) depends on answering "does policy set A permit anything policy set B
  forbids?" offline. The open-source
  [`cedar-policy-symcc`](https://crates.io/crates/cedar-policy-symcc) crate
  compiles policy sets to SMT and decides subsumption/equivalence, with the
  compiler formally verified in Lean.
- **A formally verified evaluator**, differentially fuzzed against the spec.
- **`forbid` semantics** with a fixed evaluation rule (explicit forbid >
  explicit permit > default deny — see
  [The shape](../architecture/iam.md#the-shape)). Our SpiceDB schema was
  100% additive; there was no way to express a ceiling.

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

## Migration plan

Phases; each landed independently:

1. **Bindings groundwork (engine-independent).** Bindings table + role
   registry in Postgres, dual-written alongside SpiceDB tuples (SpiceDB
   remained authoritative). Backfill from the existing Postgres mirrors plus
   a one-time SpiceDB relationship export — resource-level
   `owner`/`viewer`/`editor` tuples existed **only** in SpiceDB and had to
   be exported before any cutover. Shipped `who-can` and `expires_at` early.
2. **Guardrail store + policy versioning.** Forbid-only by construction;
   versioned policy sets. **Shipped** — see
   ["The store"](../architecture/iam.md#the-store-shipped) under Guardrails
   and "Versioning" under
   ["Architecture: the evaluator is in-process"](../architecture/iam.md#architecture-the-evaluator-is-in-process).
   Guardrails are stored and evaluable but not yet on the enforcement path,
   which arrives with the evaluator.
3. **Cedar integration.** Swift binding (separate track), Cedar schema (entity
   types, action groups, binding templates), entity-slice loader, compiled
   policy-set cache with Valkey invalidation. **Shipped** — see
   ["The Cedar encoding"](../architecture/iam.md#the-cedar-encoding-shipped-with-480).
4. **Shadow evaluation + decision logs.** Every check ran through both
   engines; mismatches were logged with both verdicts and burned down against
   the target semantics (now documented in [iam](../architecture/iam.md)).
   The decision-log infrastructure was built here. **Shipped** (#481,
   including the real engine behind `CedarEngine`) — see
   ["Decision logs"](../architecture/iam.md#decision-logs-shipped-with-481)
   and "Shadow evaluation" below. The burn-down itself was the gate on
   phase 5, not part of this phase.
5. **Cutover.** Flip `req.can` and the middleware to Cedar; default-deny
   middleware; admin bypass through the evaluator; creator bindings at create.
   **Shipped** (#482) — see
   ["Enforcement path"](../architecture/iam.md#enforcement-path-shipped-with-482).
   During the rollback
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
   every grant comes back naming the ceilings that narrow it; see
   ["The write-time ceiling report"](../architecture/iam.md#the-write-time-ceiling-report-shipped-484).
   Still ahead: policy simulator, workload registry/principals, service
   accounts.

The **folder rename** (OU → folder) happens in two steps: UI/docs copy
anytime; the API/database rename is still pending (the Cedar vocabulary
already says `Folder`) — it was deliberately kept out of the migration
rather than churning the authorization types mid-flight.

## Shadow evaluation and the reverse shadow

Before cutover, SpiceDB gated requests and Cedar shadowed it: every check ran
through both engines, and mismatches were logged with both verdicts. Cutover
(#482) reversed the direction — Cedar gates requests inline — and through the
rollback window, while SpiceDB remained deployed, each check with a
SpiceDB-vocabulary equivalent also asked SpiceDB in a background task and
recorded both verdicts, so the mismatch surface kept watching for
regressions. That reverse shadow ended when #483 deleted SpiceDB (its kill
switch, `IAM_SHADOW_EVAL_ENABLED`, went with it); the decision log stays,
recording the Cedar verdict alone. The
`spicedb_permission`/`spicedb_decision` columns — and the
`spicedbPermission`/`spicedbDecision` API fields — keep their historical
names for compatibility: the former carries the legacy-vocabulary question
as asked at the check site, the latter is always `none` on rows written
after the removal.

The burn-down ran on the decision-log summary
(`GET /api/iam/decision-logs`, `/summary`, `?mismatchesOnly=true`); the
three *expected* mismatch classes — org members losing implicit project
visibility, nested-folder admin inheritance being fixed, and conditioned
bindings (which the entity slice deliberately does not flatten, surfacing as
a non-zero `skipped_conditioned_bindings`) — confirmed the target semantics
rather than refuting them.

## Pre-cutover audit of handler-level allows (gate on phase 5)

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
  became [a resource
  type](../architecture/iam.md#the-identity-plane-is-a-resource-type) it is
  an ordinary evaluator check and the route is
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
