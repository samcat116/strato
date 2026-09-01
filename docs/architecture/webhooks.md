# Webhooks

User-managed event notifications (issue #559): organizations subscribe webhook
endpoints to typed platform events, and the control plane delivers signed JSON
payloads reliably through a transactional outbox. This closes the automation
loop — external systems no longer need to poll operations or resources.

This subsystem supersedes the operator-level `AUDIT_WEBHOOK_URL` audit export
for product use; that backend remains as an ops trail export.

## Event catalog

Events are a small typed enum (`WebhookEventType`) with wire-stable `type`
strings:

| Type | Fires when |
| ---- | ---------- |
| `operation.completed` | An async resource mutation (VM, sandbox or volume create/start/stop/delete/resize/…) converges |
| `operation.failed` | An async resource mutation fails (agent error, or the stuck-convergence sweep past its deadline) |
| `vm.state_changed` | A VM's observed status transitions (agent reports, drift, loss) |
| `agent.connected` | An agent registers its WebSocket connection |
| `agent.disconnected` | An agent unregisters, its socket closes, or its heartbeat goes stale |
| `quota.threshold_exceeded` | A workload admission pushes a quota pool across 80% or 100% of its limit |
| `webhook.test` | The "send test event" endpoint (not subscribable; always delivered to the target subscription) |

Every payload is a stable envelope:

```json
{
  "id": "8f7c…",                    // event id, shared across the fan-out — dedupe on this
  "type": "operation.completed",
  "timestamp": "2026-07-22T18:03:12Z",
  "organizationId": "…",
  "projectId": "…",                  // null for org-level events (agent presence)
  "resource": { "kind": "virtual_machine", "id": "…", "name": "web-1" },
  "data": { "operationId": "…", "operationKind": "boot", "status": "succeeded" }
}
```

Growing the catalog is one new enum case plus an emit call at the semantic
moment (image import finished, snapshot completed, floating IP attached, …).

## Subscriptions

`WebhookSubscription` rows are org-scoped configuration (managed under
**Settings → Webhooks** in the UI, or `/api/organizations/:orgID/webhooks`):
target URL, selected event types (empty = all), an optional project scope
filter, an active flag, and a per-subscription signing secret. Org members can
read subscription configuration; org admins mutate, and delivery history is
admin-only too — delivery rows carry frozen event payloads (resource names,
error strings) from any project in the organization (the same
`OrganizationAccessService` Cedar gates as SSF streams).

- **Secrets** are generated server-side (`whsec_…`), stored encrypted at rest
  by `SecretsEncryptionService`, and shown exactly once — in the create and
  rotate-secret responses.
- **SSRF**: target URLs are validated by `SSRFGuard` at create/update, and the
  delivery sweep POSTs through `GuardedHTTPClient`, which re-validates before
  every attempt and pins the connection to the address it approved — so a DNS
  record that later rebinds to an internal address is refused, and one that
  rebinds *between* the check and the connect is never reached.

## Transactional outbox

Request handlers and agent-report processing never fire HTTP. Emitting an
event means inserting `webhook_deliveries` rows — one per matching active
subscription, all sharing the event's id — on the same `Database` handle as
the state change that produced the event:

- `operation.completed`/`operation.failed` are enqueued inside
  `ResourceConvergence.recordSuccess`/`recordFailure` — the two funnels every
  outcome goes through — in the same transaction as the write that closes the
  transition. Committing the guard without the event would lose it permanently,
  since nothing re-enters; committing the event without the guard would fire it
  twice. A **delete** is the exception, because its success is the resource's
  absence: the finalizer reap enqueues `operation.completed` from the terminal
  `resource_events` row, which is the only place the delivery context still
  exists. (Both replaced `ResourceOperation.completeIfPending`, which was the
  single funnel until the operations table retired in STR-152.)
- `quota.threshold_exceeded` is enqueued inside the quota admission
  transaction (`QuotaEnforcementService.reserveWorkload`), comparing the
  post-resync baseline against the post-admission reservation so only a
  *crossing* fires, not every admission above 80%.
- VM state changes and agent presence are enqueued fire-and-forget next to
  the status writes (`WebhookEvents.emit` logs failures rather than breaking
  observed-state bookkeeping).

The payload JSON is frozen at enqueue time, so what was true at the semantic
moment is what gets delivered, regardless of later mutations.

The enqueue transaction also enforces a ceiling of **10,000 pending rows** per
subscription. In the same transaction that adds deliveries, it moves the
subscription's oldest unclaimed overflow rows to the terminal `dropped` state;
an active claim is never shed. Dropped rows remain visible in delivery history,
contribute to the committed-history `strato_webhook_delivery_dropped` gauge,
and can be manually redelivered. A capacity drop is not an endpoint failure and
does not advance the subscription's auto-disable streak. The ceiling is a fixed
safety invariant, not an operator-tunable setting.

The drop transition preserves the original enqueue time in `enqueued_at` and
refreshes the legacy `created_at` retention anchor. This keeps an older replica's
pre-STR-264 retention query from deleting a newly dropped old backlog row during
a rolling deployment; current replicas still return the immutable enqueue time
through the API and retain terminal history from its latest transition.

Only rows with no active explicit lease are eligible for shedding. A future
retry schedule also receives one 120-second claim-lease grace period after its
last update. During a rolling upgrade, an older worker claims by advancing the
retry schedule and `updated_at` without writing the lease column, and it can
leave any previous lease value untouched. The grace period therefore protects
that mixed-version worker's active POST; afterwards an old scheduled retry can
still be shed before its backoff expires. The ceiling can be temporarily soft
during the grace period rather than risking in-flight work. New workers
dual-write the legacy retry deadline while claiming, which prevents old workers
from reclaiming their rows.

## Delivery sweep

`WebhookDeliveryService` runs a periodic loop on every replica (armed by
`WebhookDeliveryLifecycleHandler`). Every replica contributes to the drain:
each pass repeatedly claims batches of 16 due rows and starts no more than 8
HTTP requests concurrently. Claim selection ranks each subscription's due rows
by earliest scheduled attempt, then interleaves subscriptions and organizations
so the first candidate from each tenant precedes that tenant's later candidates,
with stable timestamp and ID tie-breakers. That keeps one tenant or subscription
burst from filling every early concurrency window. Retries can intentionally
reorder events because their next scheduled attempt is later.

A pass keeps claiming until no work is due or its soft wall-clock budget
expires (30 seconds by default). The deadline is checked between batches, so an
already-claimed batch always finishes and may carry the pass past its nominal
budget. If work remains after the budget, the worker yields and immediately
starts another budgeted pass. It sleeps for
`WEBHOOK_DELIVERY_INTERVAL_SECONDS` (15 seconds by default) when no currently
due, unleased row is claimable, or before retrying a sweep-level database error.
Future backoff rows and rows leased by other replicas can still exist. The
interval is therefore healthy idle added latency and an error-retry delay, not
a busy-backlog throughput limit.

For every claimed delivery:

- **Signing**: `X-Strato-Signature: t=<unix seconds>,v1=<hex hmac>` where the
  HMAC is SHA-256 over `"<t>.<body>"` with the subscription secret. Consumers
  recompute it and should reject stale timestamps. `X-Strato-Event-Id`,
  `X-Strato-Event-Type`, and `X-Strato-Delivery-Id` headers ride along.
- **Retry**: non-2xx or transport errors back off exponentially (30s doubling
  to a 1h cap); after 8 attempts the delivery is `dead` and only a manual
  redeliver revives it. Requests time out after 10s.
- **Auto-disable**: the subscription tracks `failingSince`, the start of its
  current unbroken failure streak (any success clears it). Once the streak is
  older than `WEBHOOK_AUTO_DISABLE_DAYS` (default 3), the subscription is
  deactivated with a `disabledReason` the UI surfaces; re-activating clears
  the bookkeeping.
- **History**: terminal deliveries are kept 7 days as browsable per-
  subscription history (`succeeded`, `dead`, or `dropped`, plus attempts, last
  response code, and frozen payload) with manual redeliver and a "send test
  event" endpoint.

## Multi-replica properties

Reliability falls out of the same machinery as the rest of the control plane:
PostgreSQL is the only source of truth (any replica can enqueue — it is just
a row insert in the caller's transaction). Once a row is claimed, its POST is
**at-least-once** — a crash between POST and the success write replays the
delivery once the claim lease lapses. Consumers dedupe on the event id. Rows
explicitly shed at the per-subscription pending ceiling are the exception: they
are recorded as `dropped`, counted, and receive no further POST attempt. A
dropped retry retains its earlier failed-attempt history.

Concurrent drainers are safe by construction. Each pass **claims** its batch
with one atomic `UPDATE … FOR UPDATE SKIP LOCKED … RETURNING`, writing an
explicit lease deadline that is separate from retry scheduling. Concurrent
replicas therefore claim disjoint rows without a cluster-wide sweep lock. A
crashed drainer's rows become claimable again when their leases expire.
Claims also advance the legacy `next_attempt_at` lease deadline so an older
replica participating in a rolling deployment cannot reclaim new work.

The effective drain ceiling is governed by replica count, eight concurrent
requests per replica, endpoint latency (requests time out after 10 seconds), and
database capacity. The 16-row claim batch and 30-second cooperative pass budget
bound local work without pinning the whole deployment to 16 deliveries per
interval. Fair selection prevents subscription-level head-of-line blocking;
adding replicas increases delivery capacity.

## Queue observability

The delivery worker records cluster-wide queue depth, oldest-pending age,
per-subscription depth, and retained dropped history, plus replica-local HTTP
attempt and claimed-row result counters. Deleted subscriptions explicitly
unregister their UUID-labelled gauge. Oldest-pending age is the primary
delivery-latency alert. Because every replica snapshots the same PostgreSQL
outbox, queue/history gauges must be aggregated with `max`, never `sum`; work
counters are summed across replicas.
The exact metric names, PromQL examples, and response steps are in
[Observability: Metrics & Traces](/deployment/observability#webhook-delivery).

## Configuration

| Variable | Default | Meaning |
| -------- | ------- | ------- |
| `WEBHOOK_DELIVERY_ENABLED` | `true` (off under tests) | Enable outbound delivery; queue telemetry continues while disabled |
| `WEBHOOK_DELIVERY_INTERVAL_SECONDS` | `15` | Delay after no claimable work or a sweep error |
| `WEBHOOK_DELIVERY_PASS_BUDGET_SECONDS` | `30` | Soft per-pass budget, checked between claim batches (valid range 1–3600 seconds) |
| `WEBHOOK_AUTO_DISABLE_DAYS` | `3` | Continuous-failure window before auto-disable |
