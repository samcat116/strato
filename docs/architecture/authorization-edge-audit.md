# Authorization enforcement-edge audit (STR-116)

The Cedar evaluator answers correctly. Every authorization defect found during
IAM E2E testing lived in the layer *around* it — the HTTP boundary asking the
policy engine the wrong question, or not asking it at all. This document is the
systematic pass the point findings (STR-107, STR-113, STR-115) asked for: it
maps every gate to the action it resolves to and every list endpoint to its
per-row mechanism, so the edge is checkable against
[`iam.md`](./iam.md)'s invariants rather than trusted to prose.

It is a companion to `iam.md`, not a replacement: `iam.md` documents how the
engine decides; this documents whether the edge asks it the right thing.

The two executable guards derived from this audit:

- **Privilege-tier of every legacy gate** —
  `IAMShadowTranslationTests.translationPrivilegeTiers` pins each legacy
  permission name to the exact role set its action must sit at. A remap that
  shifts a gate across tiers (the STR-107 shape) fails the suite.
- **Every authorization denial is attributable** — scope refusals now write a
  `scope_denied` row to `iam_decision_logs`
  (`APIKeyAuthenticatorTests.testScopeDenialRecorded`); previously they were the
  one denial class that left no decision row.

---

## 1. Gate → action → roles (the legacy vocabulary)

`IAMActionTranslation` maps each legacy permission name onto a registry action.
The audit confirmed every mapping resolves to an action at the privilege level
its call sites intend, with the exceptions noted. "Roles" is
`IAMRoleRegistry.roles(granting:)` for the resolved action — the set a binding
must name to pass the gate.

| Legacy permission | Resolves to | Roles that hold it | Intended tier | Verdict |
| -- | -- | -- | -- | -- |
| `view_organization` / `view_project` / `view_ou` / `view` / `read` | `<svc>:read` | viewer+ | read | OK |
| `download` | `image:download` | viewer+ | read | OK |
| `list` | `<svc>:list` | viewer+ | read | OK (no call site) |
| `start` `stop` `restart` `pause` `resume` | `<svc>:<verb>` | operator+ | lifecycle | OK |
| `exec` (sandbox) | `sandbox:exec` | operator+ | lifecycle | OK |
| `create` `update` `delete` (resources) | `<svc>:<verb>` | editor+ | mutation | OK |
| `create_volume` / `_network` / `_floating_ip` / `_security_group` / `_dns_zone` | `<svc>:create` | editor+ | mutation | OK |
| `create_resources` | `vm:create` / `sandbox:create` (by path) | editor+ | mutation | OK |
| `snapshot` `restore` `clone` `resize` `attach` `detach` `export` | `<svc>:<verb>` | editor+ | mutation | OK |
| `view_console` | `vm:viewConsole` | editor+ | mutation | OK |
| `update_project` | `project:update` | editor+ | metadata edit | OK |
| **`manage_project`** | **`project:update`** | **editor+** | **admin (per call sites)** | **STR-107 — gate defect** |
| `manage_members` / `manage_organization` | `org:update` | admin | admin | OK |
| `manage_ou` | `folder:update` | admin | admin | OK |
| `manage` (site / agent) | `site:manage` / `agent:manage` | admin | admin | OK |
| `manage_agents` | `agent:manage` | admin | admin | OK |
| `exec` (vm) / `run` (vm) | `vm:exec` / `vm:runCommand` | none (custom role only) | root-on-VM | OK (issue #804) |

### The one wrong-privilege gate (STR-107)

`manage_project` translates to `project:update`, an **editor** action, but
`OrganizationAccessService.requireProjectAdmin` used it as the gate on
admin-only project surfaces — member/group role bindings, quotas, registry pull
secrets, project deletion and transfer. A project editor therefore passed an
admin gate and could self-promote to admin. The translation is not wrong
(updating a project's metadata *is* an editor act); the *gate* was asking an
editor question on an admin surface. The fix (tracked in
[#859](https://github.com/samcat116/strato/issues/859), PR
[#863](https://github.com/samcat116/strato/pull/863)) splits the gate per call
site — `iam:setPolicy` for bindings, `quota:manage` for quotas,
`project:delete` for deletion, `project:transfer` for transfer — and leaves
`project:update` only on metadata edits.

### Benign edge cases the audit surfaced (no defect, worth recording)

- **`update_project` gates image creation** (`ImageController.create`) while
  every other resource create uses a `create_*` permission. Both are editor
  tier, so image creation demands `project:update` rather than an
  `image:create` — a stricter, not weaker, gate. Cosmetic inconsistency, not a
  hole.
- **`manage_ou` / `view_ou` are dead.** Folder-scoped authorization resolves to
  the *root organization's* `manage_members` / `view_organization` throughout
  (`ResourceQuotaController`, `OrganizationalUnitController`), so an org admin
  implicitly administers every folder. The folder-level binding API
  ([#862](https://github.com/samcat116/strato/issues/862)) is where per-folder
  gates would start using these.
- **`manage_agents` gates site and floating-IP-pool creation** — cross-service
  verb reuse (`site`/`floatingip` creation asking `agent:manage`). Consistent
  and admin-tier; noted only so it is not mistaken for a mapping error.
- **Snapshot delete/restore/export** gate on the parent's `read` first, then the
  per-snapshot `delete`/`restore`/`export` action. The destructive privilege
  comes entirely from the second, per-snapshot check — correct, but the parent
  gate alone is only a read.

---

## 2. List endpoint → per-row mechanism

Every collection `GET` was classified by how it decides which rows the caller
may see. The correct mechanisms already in the tree are `ProjectVisibility`
(project-scoped resources), `req.canFilter` (per-row batch decision), and a
container gate whose action matches the rows' own privilege. The defect class is
a list gated only on **org membership** that then returns everything in scope —
the old "every org member sees every project" behaviour the SpiceDB replacement
was meant to remove.

### Fixed in this pass

| Endpoint | Was | Now |
| -- | -- | -- |
| `GET /api/projects` | org-membership filter, no per-row check | `ProjectVisibility` + `readableProjects` |
| `GET /api/organizations/:id/projects` | `requireMember` then all rows | `ProjectVisibility` + `readableProjects` |
| `GET /api/organizations/:id/ous/:ouID/projects` | `requireMember` then all rows | `ProjectVisibility` + `readableProjects` |
| `GET /api/quotas?level=project` | org-membership filter | project rows filtered on `project:read` |

The project-list leaks are STR-113
([#870](https://github.com/samcat116/strato/issues/870)); the `/api/quotas`
project-row leak is the same class, found in this pass.

### Already correct (per-row filtered)

`GET /api/vms`, `/api/sandboxes` (`canFilter`); `/api/volumes`, `/api/networks`,
`/api/security-groups`, `/api/floating-ips`, `/api/dns-zones`
(`ProjectVisibility`); `/api/sites`, `/api/agents`, `/api/agent-enrollments`,
`/api/floating-ip-pools` (`canFilter`); `/api/users`
(`UserDirectoryVisibility`). Nested lists whose rows have no identity apart from
their parent — a VM's operations/logs/snapshots, a project's members/service
accounts, the IAM policy/role/guardrail lists gated on `iam:readPolicy` of the
owner — correctly use a container gate whose action matches the rows.

### Fixed in the aggregation pass ([#882](https://github.com/samcat116/strato/issues/882))

The deferred aggregation leaks are closed. The design question they were
deferred on — admin-gate the aggregate or filter the whole tree per-row —
resolved to *filter*: `HierarchySnapshot.readable(on:)` narrows one loaded
snapshot through three batched decisions, and the tree, the flat dump and the
summary are all assembled from it, so there is one answer rather than three.

| Endpoint | Was | Now |
| -- | -- | -- |
| `GET /api/organizations/:id/resources` | the org's entire VM fleet, projects, folders, quotas | snapshot narrowed on `project:read` / `folder:read` / `vm:read`; folders from `decidedFolders` |
| `GET /api/organizations/:id/hierarchy` | VM summaries for every project | same snapshot; ancestor folders retained only to keep the tree connected |
| `GET /api/organizations/:id/resources/summary` | org-wide usage + per-quota compliance | same snapshot, so the totals count what the tree would show |
| `GET /api/organizations/:id/search` / `GET /api/hierarchy/search` | matching folders/projects/VMs org-wide | `HierarchySearchService.readable`, one batch per result kind |
| `GET /api/organizations/:id/ous`, `.../ous/:ouID/ous` | the org's whole folder structure | `folder:read` per folder |
| `GET /api/organizations/:id/path/:type/:id` | folder/project/VM names for an arbitrary entity | `HierarchyPathResolver.visibleComponents`, one batch per component type |

One row survives without a decision of its own, documented at the call site:
folders on the path down to a readable project — dropping those disconnects the
tree, and the project's own materialized `path` names them anyway. It only
applies to the nested tree; flat consumers read `decidedFolders` and never see
them.

Organization-scoped quota **rows** likewise ride the handler's
`view_organization` gate, since they describe that organization. Their
*measured usage* does not. `QuotaComplianceService` calls
`calculateActualUsage`, which sums every row beneath the quota's node, so an
organization-scoped quota reports the organization's whole vCPU, memory and VM
consumption — handing back through `quotaCompliance` the same totals
`resourceUsage` had just been narrowed to remove. The summary endpoint
therefore decides each quota on `quota:read` at the node it hangs on before
measuring: unlike the `org:read` that admits the row, `quota:read` is
role-derived, so a bare member does not hold it, while anyone with a viewer
role at organization level already sees the rows the total is drawn from.

`GET /api/organizations/:id/search` was additionally **500ing for every
caller**: it declared its folder join inside an `.or` group, which Fluent drops
from the emitted SQL while keeping its filter, so the statement named a table it
never joined. Nothing covered the route.

### Open findings (documented, not fixed)

| Endpoint | Leaks | Notes |
| -- | -- | -- |
| `GET /api/organizations/:id/groups` | every group in the org, and `getMembers` discloses emails | `group:read` exists, so this is fixable the same way; identity-plane inventory rather than the project one |
| `GET /api/organizations/:id/webhooks` | every subscription in the org, **including delivery URLs** | no `webhook:*` actions in the registry, so there is nothing to decide on yet — registering them comes first |
| `GET /api/organizations/:id/ous/:ouID` and the folder mutation routes | any folder in the org, by id | an *item*-route gap, not a list one: the controller gates on `requireMember` where `folder:read` / `folder:update` exist |
| `GET /api/projects` candidate set | nothing — an under-grant | bounded by membership rows, so a binding reaching a project in an org the caller holds no membership row in is hidden from the list while the item route allows it. A bound must come from grants, not membership, or it decides silently |

Weaker container gates worth revisiting (SUSPECT, not confirmed leaks):
`GET /api/projects/:id/images` (`view_project` where `image` is its own node
type with per-image guardrails), DNS record lists and VM/sandbox/volume snapshot
lists (container `read` where the item routes authorize on the child node type).
Each is defensible — a child cannot outlive its parent's read grant — but none
honours a row-level forbid the way its item route does.

---

## 3. The parallel credential-scope system (STR-115)

API keys and CLI sessions carry a `read`/`write`/`admin` scope enforced by
`APIKeyScopeMiddleware` from the HTTP method alone, entirely outside Cedar. This
is `iam.md`'s "identity never carries authorization" invariant violated at the
edge, and it means a request has two independent ways to be denied, only one of
which the evaluator knows about. The direction — fold scopes into the evaluator
as a `bindings ∩ restriction` intersection — is recorded in
[`iam.md`](./iam.md#credential-scopes-are-a-parallel-gate-to-be-folded-in-str-115)
and tracked as [#873](https://github.com/samcat116/strato/issues/873).

The one repair made here: a scope refusal now writes a `scope_denied` row to
`iam_decision_logs` (naming the principal, the credential, and the missing
scope), so the audit trail that exists to explain 403s no longer has a blind
spot for this denial class.

---

## What still isn't structurally prevented

`AuthorizationMiddleware` already fails boot on an unclassified route and fails
the test suite on a *mutating* handler that served without evaluating any
decision. It does **not** catch a handler that evaluates the *wrong* action, nor
a *list* (GET) handler that filters on membership instead of the evaluator —
`assertHandlerEvaluated` deliberately skips reads. The two guards this audit adds
(privilege-tier table; scope-denial attribution) close the first-point and
third-point acceptance items; a fully structural list-coverage guard — asserting
every collection GET routes through `ProjectVisibility`/`canFilter` — remains the
strongest available follow-up and is noted here so it is not forgotten.
