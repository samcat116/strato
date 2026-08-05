# Code Review

What to evaluate when reviewing a change to Strato — for humans and for agents
running `/review` or `/code-review`.

The first half is the general checklist, ordered roughly by how expensive the
defect is to find later. The second half — [Strato-specific traps](#strato-specific-traps)
— is the part that actually catches bugs in this repo, because it encodes
invariants a generic reviewer has no way to know about.

## How to use it

Don't walk all of it on every diff. Pick the sections the diff touches, and
spend the time where a mistake is unrecoverable:

| Tier | Meaning | Examples |
| --- | --- | --- |
| **Blocking** | Merging causes data loss, a security hole, or a broken cluster | Missing authorization check, destructive migration, desired-state replay |
| **Should fix** | Real defect or debt, but bounded and reversible | Missing edge-case test, N+1 query on a hot path, swallowed error |
| **Nit** | Preference; author's call | Naming, comment wording, ordering |

Label the tier explicitly on every comment. An unlabeled nit next to an
unlabeled blocker makes the author guess which one matters, and they will guess
wrong.

Read the diff **twice**: once for what it does, once for what it *doesn't* —
the missing rollback, the unhandled `nil`, the second call site that wasn't
updated. Most real bugs are in the second pass.

---

## 1. Correctness

The change does what it claims, for every input it can actually receive.

- **Requirement fit** — does the diff implement what the issue/PR describes?
  Scope creep and scope shortfall are both review findings. If the PR body
  says "fixes X" and the diff also rewrites Y, ask whether Y belongs in a
  separate PR.
- **Boundary conditions** — empty collection, single element, exactly-at-limit,
  one-past-limit, zero, negative, overflow. Off-by-one lives here.
- **Optionality and failure paths** — every `try?`, `!`, `guard else`, and
  `??` is a decision. Is the fallback correct, or just convenient?
- **Concurrency** — Swift concurrency is checked, but `actor` reentrancy is
  not: any `await` inside an actor method is a suspension point where state
  can change underneath you. Check state re-read after every `await`. Look
  for check-then-act races (`if !exists { create }`) that need a transaction
  or a unique constraint instead.
- **Idempotency** — can this run twice? Retries, replays, and duplicate
  webhook deliveries are normal here, not exotic.
- **Ordering assumptions** — does the code assume messages, rows, or events
  arrive in order? Across a WebSocket reconnect or a replica failover, they
  don't.
- **State machines** — for any status/desired-state transition, enumerate the
  states the code can be entered from, not just the happy one.
- **Data migrations** — is the migration reversible? Does `revert` actually
  restore, or silently drop? Does a backfill handle rows that predate the
  column being non-null?

## 2. Standards, style, and conventions

CI enforces most of this — don't spend review time on what a linter already
catches. Check the parts it can't:

- **Swift**: `swift format lint --strict --recursive` over `Sources/` and
  `Tests/`, using the root `.swift-format` (4-space indent, 120 columns). Fix
  with `swift format --in-place --recursive <dirs>` before pushing.
- **Frontend**: `bun run lint` and `bun run build` in `control-plane/web`.
  Bun, never npm.
- **OpenAPI**: the spec at `control-plane/Sources/App/openapi.yaml` is linted
  by Redocly, and `control-plane/web/src/types/openapi.ts` is generated from
  it and checked in — CI fails if regenerating produces a diff. Any API change
  means: edit the spec, run `bun run generate:api-types`, commit both.
  `clients/swift` symlinks the same spec.
- **Conventions a linter can't see**: does the new code look like its
  neighbors? Same error-handling idiom, same layering, same naming. A
  correct change written in a foreign style is still a maintenance cost.
- **Vocabulary**: use the terms defined in `CONTEXT.md` (operation, verdict,
  desired state, generation, socket route…). Reviewers should push back on
  synonyms — drifting vocabulary is how two subsystems end up with two names
  for one concept.

## 3. Readability, maintainability, documentation

- **Names carry weight** — a name that describes *what it is* beats one that
  describes *how it was computed*. `pendingOperation` over `filteredResult2`.
- **Comments explain why, not what** — the code already says what. Comments
  earn their place by recording the non-obvious: the race being avoided, the
  reason the ordering matters, the upstream bug being worked around.
  `ResourceOperationCoordinator.recordVerdict` is the local model: its doc
  comment explains why the method returns a value at all — a lost race means
  the sweep already resolved the resource — which nothing in the signature
  conveys.
- **Function shape** — deep modules, narrow interfaces. A long function
  doing one thing beats five short ones that must be read together to
  understand any of them. Flag "helper" methods that can't be understood
  without their single caller.
- **Nesting** — more than three levels of indentation usually means an early
  return or an extracted predicate is missing.
- **Docs that must move with the code**:
  - `docs/architecture/*.md` is kept current — a change to a subsystem's
    design must update its doc in the same PR, not "later."
  - `CONTEXT.md` when a new domain term is introduced.
  - `docs/adr/` when a decision is made that a future reader would otherwise
    relitigate. If the diff contradicts an existing ADR, say so in review
    rather than letting it land silently. (The directory doesn't exist yet —
    ADRs get created lazily when a decision actually needs recording, per
    `docs/agents/domain.md`. Don't go looking for it; the first one to write
    an ADR creates it.)
  - `CLAUDE.md` when a build/test/deploy workflow changes.
- **Dead code and TODOs** — a TODO without an issue number is a comment that
  will never be actioned. Either file it or delete it.

## 4. Error handling and logging

- **No silent swallows.** `try?` that discards a real failure, an empty
  `catch`, a `.failure` branch that only returns `nil` — each needs a reason
  in a comment or a rewrite.
- **Errors carry context.** The message should tell an on-call engineer which
  resource, which agent, which operation. `"failed to start VM"` is a support
  ticket; `"failed to start VM \(vm.id) on agent \(agent.name): \(error)"` is
  a fix.
- **The right abort code.** `400` for malformed input, `403` for denied,
  `404` for absent, `409` for the double-submit guard, `422` for semantically
  invalid, `503` for a dependency down. Don't leak internals into the message.
- **Failure leaves consistent state.** If a multi-step mutation fails halfway,
  what's left in Postgres? Is it inside a transaction? For resource
  operations, is a verdict recorded so the row can't hang pending forever?
- **Log levels mean something.** `error` = a human should look; `warning` =
  degraded but handled; `info` = lifecycle events; `debug` = per-request
  detail. An `error` log on an expected condition trains people to ignore
  errors.
- **Never log secrets.** Tokens, API keys, passwords, session cookies, SVID
  private material, full request bodies on auth endpoints. Check what
  structured-logging metadata actually serializes.
- **Cancellation** — long-running tasks should handle `Task.isCancelled` /
  `CancellationError` rather than treating it as failure.

## 5. Security

Strato is infrastructure that runs other people's workloads; treat every
review as a security review. `/security-review` covers this in depth.

- **Authorization on every route.** `AuthorizationMiddleware` is default-deny,
  so a new route must declare its permission. Never add a controller-local
  admin fast path — admin access flows through the Cedar evaluator too.
- **Object-level authorization**, not just route-level: can user A pass user
  B's resource ID and have it work? Every lookup by client-supplied ID needs
  an ownership/hierarchy check.
- **Tenant isolation.** Org, folder, and project scoping must be in the
  *query*, not applied after fetching. A cross-org read that's filtered in
  Swift has already loaded the data.
- **Injection.** Fluent's query builder is safe; raw SQL and any string-built
  query are not. Same for shell: arguments must go through `ProcessRunner`'s
  argument array, never an interpolated command string.
- **SSRF.** Any control-plane fetch of a user-supplied URL (image sources,
  OIDC discovery, webhooks) must go through `SSRFGuard`.
- **Path traversal.** Image names, volume names, and snapshot IDs that reach
  the filesystem need validation — the agent owns paths, and a `../` in a
  name escapes the storage root.
- **Secrets.** No credentials in code, fixtures, or compose files; new config
  goes through environment variables and gets documented.
- **Quotas.** New resource-consuming endpoints must enforce
  `QuotaEnforcementService` on create *and* release on delete — a leak on the
  delete path is a slow denial of service.
- **Rate limiting and audit.** Unauthenticated or expensive endpoints need
  `RateLimitMiddleware`; security-relevant mutations need an `AuditService`
  entry.
- **Dependencies.** New third-party packages need a reason; check the pin and
  whether it pulls in a transitive surface we don't want.

## 6. Performance and scalability

- **N+1 queries.** The classic here: loading a list of VMs then fetching each
  one's project/network/operation in a loop. Use `.with(...)` eager loading
  or a single batched query.
- **Unbounded work.** Any query without a `limit`, any `for` loop over a
  user-controlled collection, any response that grows with tenant size. Ask
  what happens at 10,000 VMs, not 10.
- **Indexes.** A new query pattern (new `filter` on a column, new sort) needs
  a matching index in a migration.
- **Hot paths.** The agent WebSocket handler, the reconciler loop, the
  desired-state assembler, and `AuthorizationMiddleware` run constantly —
  allocation and query cost there is multiplied by every agent and request.
- **Blocking the event loop.** No synchronous file, network, or
  `Process.waitUntilExit` work on an async path.
- **Payload size.** `DesiredStateMessage` is sent in full, periodically, to
  every agent. Adding a field there multiplies across agents × sync interval.
- **Caching.** If the change adds a cache, review invalidation and the
  multi-replica story — a per-replica cache of authorization data goes stale
  independently on each replica.

## 7. Simplification, duplication, modularity

- **Is there less code that does this?** Prefer deleting a branch to adding
  one. `/simplify` exists for exactly this pass.
- **Duplication that must stay in sync** is the kind worth flagging. Two
  copies of a formatting helper is cheap; two copies of a permission check
  is a future vulnerability.
- **New switch on an existing enum** — should it be a protocol conformance or
  a registry entry instead? The hypervisor driver registry is the pattern:
  adding a backend is one registration, not new `switch` sites.
- **Leaky abstractions** — does the caller need to know the callee's
  internals to use it correctly? That's an interface problem, not a
  documentation problem.
- **Layering** — controllers orchestrate, services hold logic, models hold
  state. Business logic in a controller, or a database query in a model
  extension used by both, is a smell worth naming.
- **Premature generalization** counts as complexity too. Two call sites don't
  justify a plugin system.

## 8. Testing

- **Does the test fail without the fix?** The single most valuable question
  in a review of a bug fix. If it passes on the parent commit, it isn't a
  regression test.
- **Framework**: swift-testing (`@Test` / `#expect`), not XCTest.
- **Edge cases have tests**, not just the happy path: empty, boundary,
  concurrent, failure-injected, and the specific bug being fixed.
- **Failure scenarios**: agent offline, Valkey down, Postgres transaction
  conflict, malformed agent message, operation timing out. These are the
  paths that break in production and never get exercised by hand.
- **Authorization tests** for every new endpoint: allowed role passes, denied
  role gets 403, cross-org access gets 404/403.
- **No flake introduced**: no wall-clock sleeps, no ordering dependence
  between tests, no shared mutable fixture state. Control-plane tests clone a
  migrated template database per test so parallel runs stay isolated — keep
  new tests inside that harness rather than reaching for a shared server.
- **Test names describe the scenario**, so a failure in CI is diagnosable
  from the name alone.
- **Assertions are specific.** `#expect(result != nil)` passes for the wrong
  value; assert the value.
- **Run the full suite before opening or updating a PR** —
  `swift test --package-path control-plane` (needs Postgres; see
  `docs/development/local-development.md`). `--filter <SuiteName>` is for
  iterating, not for the final check.

## 9. Impact on the existing codebase

- **Blast radius.** Who else calls this? A changed function signature, a
  changed default, or a changed error type is only safe once every call site
  is checked — including `agent/`, `cli/`, `clients/swift/`, and the frontend.
- **Wire-protocol compatibility.** `shared/` is consumed by both the control
  plane and agents that upgrade independently. A new field must be optional
  or defaulted; a removed/renamed field is a breaking change that needs a
  deprecation window. Ask: does an old agent still work against a new control
  plane, and vice versa?
- **API compatibility.** Removing a field, tightening validation, or changing
  a status code breaks existing clients and the frontend.
- **Migration safety.** Migrations run against live data. Adding a non-null
  column without a default fails; a long `ALTER TABLE` takes a lock. Register
  new migrations in `configure.swift` — order matters and it's append-only.
- **Multi-replica behavior.** Does the change assume a single process?
  In-memory state, timers, and locks all need the Valkey coordination story
  (`docs/architecture/multi-replica.md`).
- **Configuration.** New env vars need a default, documentation, and wiring
  into both `deploy/compose` and the Helm chart — a change that only works in
  one deployment path is half-finished.
- **Architectural fit.** Does this belong here at all, or is it the third
  place we've solved the same problem?

---

## Strato-specific traps

High-frequency, high-cost mistakes in this codebase. Check these by name.

**Desired state and reconciliation**
- Every desired-state mutation must bump `generation`. Without it, agents may
  treat the sync as stale and never converge.
- Syncs are level-triggered and full — code must be safe to drop or replay a
  sync. Anything that only works if a specific message arrives exactly once
  is wrong.
- A failed operation must `revertDesiredToObserved`. An unachieved intent left
  in place (a failed delete's `.absent`) replays destructively on the next
  sync — this is the most expensive bug shape in the repo.
- Nothing in a sync may expire. Image URLs are control-plane-relative paths
  fetched over SVID mTLS precisely so a replayed sync stays valid; a
  pre-signed or time-limited URL in a sync is a bug.
- **Omission is not teardown** (STR-98). A workload missing from a sync is
  *held and reported*, never destroyed; only an explicit tombstone (or an
  `.absent` entry) removes one. Any change that makes absence destructive
  again — or that narrows `DesiredStateAssembler`'s scoping without asking
  what a short list would now do — is blocking. The same rule already governs
  the mirror direction: an agent omitting a VM from its report must not delete
  the row.

**Resource operations**
- `begin` inserts the `pending` row and applies the desired-state change in
  **one** transaction. Splitting them reintroduces the double-submit race that
  409 exists to prevent.
- Operation rows intentionally have **no FK** to the resource, so delete
  operations survive row removal. Don't "fix" this by adding one.
- Every path must reach a verdict. `recordVerdict` marks terminal only if
  still pending, so the agent-response path and the stuck-operation sweep
  can't overwrite each other — go through the coordinator, don't re-spell the
  sequence in a handler.
- New mutation endpoints return **202 Accepted** with the operation, not 200
  with the resource.

**Deletion and finalizers**
- A delete path must not remove a row. It marks desired `.absent`, stamps
  `finalizers`, and lets `ResourceFinalizerService.clear` reap when the list
  empties. A new `delete(on: db)` on a VM or sandbox outside
  `FinalizableResource.reap` is blocking.
- Stamp **before** the mark: `stampForDeletion` reads whether the resource is
  already terminating, and a re-stamp after the flip resurrects tokens their
  participants have already cleared.
- A new participant must be idempotent, crash-safe, and order-independent, and
  must have something that retries it. `agent.absent` is retried by every
  observed-state report; a participant with no repeating trigger needs a sweep
  before it can be stamped, or it strands rows.
- Clear a token with the atomic `array_remove` path, never by reading
  `finalizers`, mutating, and saving — two replicas doing that lose one of the
  updates and resurrect a token nothing will clear again.

**Multi-replica**
- Valkey **fails open**. Any new use must degrade to correct-but-slower, never
  to incorrect. Agents converge via the periodic sync even with Valkey down.
- A mutation on the replica that doesn't hold the agent's socket needs a nudge
  (or RPC forward for imperative actions like reboot). Forgetting it works
  locally and fails in production, where it silently waits for the periodic
  timer.
- Singleton work (sweeps) needs a `lock:sweep:*` lock, or every replica runs it.

**Authorization**
- No controller-local admin checks. Ever. The Cedar evaluator is the only
  authority.
- New entity types or actions need the Cedar schema and policy set updated
  together, plus tests.
- "These two resources are in different projects" goes through
  `ProjectContainment.require` — one status (`400`) and one wording for every
  site. Place it **after** the authorization checks on both resources: a
  containment refusal reaching a caller who can't see the other resource tells
  them it exists in a project they aren't in. Where there is no check to sit
  behind (nothing authorizes the caller against the resource the body names),
  don't disclose containment at all — scope the lookup to the caller's project
  and answer plain not-found, as VM create does for `networkId` and
  `securityGroupIds`.
- **A container gate is not a row filter.** `requireMember` /
  `view_organization` says the caller may know the container exists — bare org
  membership grants `org:read` and `project:create` and nothing else. Anything
  returning *rows* underneath it filters them too (issue #870). The easy misses
  are the shapes that don't look like lists: a tree, a breadcrumb, a rollup, a
  bare count.
- **A derived number needs the same filter as the rows it came from.** An
  org-wide `totalVMs`, or a quota's measured `used`, is the inventory in scalar
  form. Check both directions of a response: `/resources/summary` filtered
  `resourceUsage` per row while handing the same totals straight back through
  `quotaCompliance`.
- **Gate the quantity, not the field.** Once you find a number that needs a
  gate, find every route that ships it before claiming it closed — a stored
  counter on a DTO, a live-measured endpoint, and a derived summary are one
  quantity if the same aggregator produces them, and the weakest gate is the
  real one. `QuotaVisibility` exists because gating `quotaCompliance` alone
  left the identical figures on the quota row across three endpoints and on
  `/api/quotas/:id/usage`.

**Networking and IPAM**
- The **control plane** allocates IPs; the agent never invents them.
- There are no single-NIC fields on `VM` — everything is `VMNetworkInterface`
  rows ordered by `orderIndex`. Code that assumes one NIC is a bug.
- macOS agents are SLIRP-only (no inbound, no VM-to-VM). Don't let a feature
  that requires OVN claim macOS support.

**Storage and images**
- The **agent** owns all paths; the control plane stores and returns what the
  agent reports, verbatim. Constructing a path control-plane-side is a bug.
- All image conversion goes through `materializeDisk(at:from:format:)` —
  staging path, then atomic rename. A direct write to a live path can be read
  half-finished.
- Backing formats are **detected**, never assumed.

**Fluent query building**
- A `.join` issued **inside** a `.group(.or) { … }` closure is dropped from the
  emitted SQL while its filter is kept, so the statement names a table it never
  joined and the route 500s for every caller. Nothing catches it at compile
  time. Resolve the ids in their own query and filter with `~~`, as
  `Project.all(inOrganization:folders:on:)` does. This shipped undetected in
  the org-scoped hierarchy search.
- `~~ []` matches nothing but reads like "unfiltered" — guard the empty case
  rather than letting an empty id list reach the query.

**Frontend**
- Bun, not npm.
- Regenerate `src/types/openapi.ts` whenever the spec changes, or CI fails.
- Operations are polled to terminal state — a new async endpoint needs the
  frontend to poll, not to assume immediate success.

---

## Giving the feedback

- **Review the code, not the author.** "This function reads the state before
  the await" — not "you forgot."
- **Say what and why and what instead.** A comment that only says "this is
  wrong" costs a round trip. Include the concrete alternative, and a code
  suggestion where it's short enough.
- **Justify blocking comments with a failure scenario** — concrete inputs or
  state, and the wrong output or crash that results. If you can't write one,
  it's probably a "should fix," not a blocker.
- **Ask, don't assert, when you're unsure.** "Is this reachable when the agent
  is offline?" is better than a wrong accusation, and often finds the bug
  anyway.
- **Say what's good.** A non-obvious simplification or a well-chosen test is
  worth a sentence — it's how the pattern spreads.
- **Approve when it's better than what's there.** Perfect is not the bar;
  strictly-better-and-safe is. Track the rest as follow-up issues.
- **Don't relitigate settled decisions.** If it contradicts an ADR, cite the
  ADR. If you want to reopen it, do that in an issue, not a review thread.

## Before you request review (author's checklist)

1. `git fetch origin main && git merge origin/main` — branches go stale within
   hours here; resolve conflicts locally before opening the PR and again
   before declaring it done.
2. `swift format --in-place --recursive <changed dirs>`.
3. Full test suite for every package you touched, plus
   `bun run lint && bun run build` if the frontend changed. **This step is not
   optional and CI will not do it for you** — PR validation is a compile check
   that doesn't even build the test targets, and nothing runs `swift test` on
   `main`. A green PR says "it compiles", nothing more.
4. Spec changed? Regenerate `openapi.ts` and commit it.
5. Architecture changed? Update `docs/architecture/`, `CONTEXT.md`, or an ADR
   in the same PR.
6. Re-read your own diff as a reviewer. Most review comments are ones the
   author would have caught on a second pass.

If CI fails in a way your diff can't explain, suspect a stale build cache in the
runner's persistent scratch-slot pool producing missing-symbol errors — rerun
the failed jobs and reproduce locally before debugging source. Locally, the
control-plane suite has one known false alarm of its own: the Vapor
`ServeCommand did not shutdown before deinit` teardown race.
