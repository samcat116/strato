# Code Review Checklist

What to evaluate when reviewing a change in this repo, roughly in the order a
defect costs the most to discover late. Not every item applies to every diff —
use the section headers to decide what's in play, then work the relevant items.

The single most useful habit: **read the diff against the code it replaces, not
in isolation.** Most real findings come from what the change stopped doing, not
from what it started doing.

## 1. Correctness

- Does the change do what the issue/PR actually asked for, and nothing extra?
  Scope creep in a diff is a review finding, not a bonus.
- Walk the happy path with concrete values. Then walk at least one failure path.
- **Boundaries**: empty collection, single element, `nil`/`NULL`, zero, negative,
  max value, duplicate input, unicode, very long strings.
- **Removed behavior**: for every deleted branch, was it truly unreachable? A
  `default:` case or dialect check that "can't happen" is often the only thing
  keeping a future caller honest.
- **Off-by-one and ordering**: does the new statement order still hold the
  invariant the old order guaranteed? Migrations, reconciliation, and lock
  acquisition are all order-sensitive here.
- **Concurrency**: two replicas running this simultaneously — what breaks? Two
  agents? A request racing the reconciler? Look for read-modify-write without a
  transaction or a Valkey lock.
- **Idempotency**: control-plane syncs are level-triggered and safe to replay.
  Migrations may be retried after an interrupted non-transactional run. Does
  running this twice produce the same state?

## 2. Project standards and style

- `swift format lint --strict --recursive` clean (4-space indent, 120 cols, the
  root `.swift-format`). CI enforces this; format before pushing.
- Frontend: `bun run lint` and `bun run build` under `control-plane/web`. Bun,
  not npm.
- Tests use swift-testing (`@Test`/`#expect`), not XCTest.
- New code reads like its neighbors: same naming, same comment density, same
  idiom. A change that is stylistically correct but locally alien is still a
  finding.
- Comments explain *why*, not *what*. A comment that restates the line below it
  is noise; a comment that records a non-obvious constraint is the most
  valuable line in the diff.
- Doc comments that describe behavior must still be true after the change.
  Stale doc comments are the most commonly missed defect in cleanup PRs.

## 3. Readability and maintainability

- Can a reader who has never seen this file follow it without the PR
  description? The PR description is not shipped with the code.
- Names: does each one say what the value *is* at the point of use? Watch for
  names that survived a refactor and now describe the old design.
- Function shape: one job per function, early returns over nesting, no
  parameter that only exists to select behavior at a distance.
- Is there a simpler formulation with the same behavior? A wrapper that is now
  a trivial negation of one field, a `switch` with one arm, a filter closure
  that no longer filters — all are collapse candidates.
- **Duplication**: is this logic already implemented somewhere? Prefer calling
  the existing helper over a near-copy that will drift. Conversely, resist
  extracting an abstraction from two call sites that only look similar.
- **Modularity**: does the change respect the package boundaries
  (`control-plane` / `agent` / `shared` / `cli`)? Wire types belong in
  `shared`; agent logic that needs testing belongs in `StratoAgentCore`, not
  `StratoAgent`.

## 4. Security

- **Authorization**: every new API route is gated by the default-deny
  `AuthorizationMiddleware` and evaluated through `IAMAuthorizer`. There are no
  controller-local admin fast paths — a new one is a finding.
- **Tenancy**: can a caller reach a resource in another project, folder, or
  organization by ID? Cross-project reference checks are the recurring bug
  class here (see the volume-attach and network-isolation fixes).
- **Injection**: any raw SQL must quote identifiers and escape literals through
  the existing helpers — never interpolate an unsanitized value. Same for
  shell, path, and OVN/OVS command construction on the agent.
- **Input validation** happens server-side; client-side validation is a UX
  affordance, not a control.
- **Secrets**: nothing in logs, error messages, commit messages, PR bodies, or
  test fixtures. Check that new error descriptions don't echo credentials or
  tokens.
- **Untrusted input** from images, OCI layers, tar entries, agent-reported
  paths, and OIDC/SCIM claims must be validated, and must throw rather than
  trap on hostile values.
- **Quotas**: new resource-creating paths draw from the right `ResourceQuota`
  pool and are enforced on create *and* release on delete.

## 5. Performance and scalability

- **N+1 queries**: a loop containing a database call is the default suspect.
  Prefer a single query with `IN` or a join.
- Is the query indexed? A new `WHERE`/`ORDER BY` column without an index will
  be fine in tests and slow in production.
- **Unbounded growth**: does the result set, in-memory buffer, or log volume
  scale with tenant data? Paginate and cap.
- Migrations that rewrite every row, add a `NOT NULL` column, or take a long
  table lock need a note about their cost on a large deployment.
- **Blocking work on an async path**: no synchronous I/O or long CPU work
  inside an event-loop-bound context.
- Does the change hold a lock or a transaction across an await that does
  network I/O? That's a latency amplifier and a deadlock risk.
- Multi-replica: does it assume it's the only control-plane instance? Singleton
  work needs a Valkey sweep lock.

## 6. Error handling and logging

- Every error path either recovers or surfaces a diagnostic that names the
  resource — table, column, VM ID, agent name — enough to act on without a
  debugger.
- No swallowed errors: an empty `catch`, a discarded `try?`, or a logged-and-
  continued failure needs an explicit justification in a comment.
- Errors thrown, not trapped. Force-unwraps and array subscripts on
  externally-supplied data are process-killers.
- Failure is atomic where it matters: partial application should leave a
  recoverable state (validate everything before mutating anything).
- Log levels are honest: `error` for things a human must act on, `warning` for
  degraded-but-handled, `debug` for the rest. An `error` line that fires on a
  normal condition trains operators to ignore the log.
- Log messages carry context, not just a message string, and never carry
  secrets or full request bodies.
- Fail-open vs fail-closed is deliberate: Valkey coordination fails open by
  design; authorization must fail closed.

## 7. Tests

- Does a test actually fail without the production change? A test added
  alongside a fix that passes on the old code tests nothing.
- Are the **edge cases from §1** covered, or only the happy path?
- Is the *claimed* guarantee the *tested* guarantee? When a doc comment says
  "X already ensures this," check that something verifies X. Skipped/exempted
  cases are where coverage silently disappears.
- Failure scenarios: error paths, timeouts, conflicting concurrent writes,
  and reverts (a migration's `revert` deserves a test too).
- Tests are deterministic — no wall-clock dependence, no ordering dependence
  between tests, no shared mutable fixture without `.serialized`.
- Control-plane tests need Postgres (`DATABASE_*`, default `strato_test`).
  Run the full suite once before opening or updating a PR, not just `--filter`.
- Test names describe the behavior under test, so a failure name alone tells
  you what broke.

## 8. Architecture and blast radius

- Does the change fit the declarative model? Desired state lives in Postgres;
  agents converge on it. An imperative shortcut that mutates observed state
  directly is an architectural finding, not a style one.
- **Wire protocol / DTO changes** in `shared/` affect both sides: is it
  backward compatible with an agent that hasn't been updated? Adding a required
  field is a breaking change.
- **Schema changes**: is there a migration, is it reversible, and does the
  `revert` actually undo it? Adding an enum case requires the documented
  follow-up migration that reinstalls the constraint.
- **API changes**: is the OpenAPI spec updated, and the generated Swift client
  regenerated?
- Does it invalidate a doc? `docs/architecture/*.md` is kept current — a
  behavior change with no doc update is an incomplete change.
- What else in the codebase assumed the old behavior? Grep for it. Leftover
  comments and helpers referencing a removed subsystem are a common tail.
- Is this the smallest change that solves the problem, or is a larger cleanup
  being smuggled in? Separate commits, and say so in the PR body.

## 9. Writing the feedback

- **Lead with severity.** Distinguish blocking defects from suggestions from
  nitpicks explicitly, and let the author skip the nitpicks.
- **Be specific and falsifiable.** "This breaks when `allowedValues` is empty"
  beats "consider edge cases." Give the input and the wrong output.
- **Cite the line.** `file_path:line` — reviewers and authors both navigate by it.
- **Explain the why**, briefly. A reviewer's reasoning is what generalizes; the
  fix is what doesn't.
- **Propose, don't mandate.** Offer the alternative and let the author weigh it,
  unless it's a correctness or security issue.
- **Say what's good**, when a change genuinely improves things — it calibrates
  the rest of the review.
- **Critique the code, not the author.** "This function does X" not "you did X."
- **Don't block on preference.** If the codebase has no convention and the
  change is internally consistent, that's not a finding.
- Note explicitly when you did *not* verify something (couldn't run tests,
  didn't have a database) rather than implying full coverage.
