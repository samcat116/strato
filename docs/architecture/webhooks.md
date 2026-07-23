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
| `operation.completed` | An async resource operation (VM or sandbox create/start/stop/delete/reboot/…) succeeds |
| `operation.failed` | An async resource operation fails (agent error or the stuck-operation sweep) |
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
read subscriptions and delivery history; org admins mutate (the same
`OrganizationAccessService` Cedar gates as SSF streams).

- **Secrets** are generated server-side (`whsec_…`), stored encrypted at rest
  by `SecretsEncryptionService`, and shown exactly once — in the create and
  rotate-secret responses.
- **SSRF**: target URLs are validated by `SSRFGuard` at create/update *and*
  again by the delivery sweep before every POST, so a DNS record that later
  rebinds to an internal address is still refused.

## Transactional outbox

Request handlers and agent-report processing never fire HTTP. Emitting an
event means inserting `webhook_deliveries` rows — one per matching active
subscription, all sharing the event's id — on the same `Database` handle as
the state change that produced the event:

- `operation.completed`/`operation.failed` are enqueued inside
  `ResourceOperation.completeIfPending`, the one funnel every completion path
  (agent response, post-202 task, stuck-operation sweep) goes through. The
  status flip and the outbox insert commit in one transaction, and the
  "only the winner completes" guard means the event is enqueued exactly once.
- `quota.threshold_exceeded` is enqueued inside the quota admission
  transaction (`QuotaEnforcementService.reserveWorkload`), comparing the
  post-resync baseline against the post-admission reservation so only a
  *crossing* fires, not every admission above 80%.
- VM state changes and agent presence are enqueued fire-and-forget next to
  the status writes (`WebhookEvents.emit` logs failures rather than breaking
  observed-state bookkeeping).

The payload JSON is frozen at enqueue time, so what was true at the semantic
moment is what gets delivered, regardless of later mutations.

## Delivery sweep

`WebhookDeliveryService` runs a periodic loop on every replica (armed by
`WebhookDeliveryLifecycleHandler`, default every 15s), made cluster-singleton
per pass by the `lock:sweep:webhook_delivery` Valkey lock — the same pattern
as the audit-retention and SSF poll sweeps. Each pass drains due pending rows
(oldest first, batched):

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
  subscription history (status, attempts, last response code, frozen payload)
  with manual redeliver and a "send test event" endpoint.

## Multi-replica properties

Reliability falls out of the same machinery as the rest of the control plane:
PostgreSQL is the only source of truth (any replica can enqueue — it is just
a row insert in the caller's transaction), the sweep lock ensures one drainer
per pass, and delivery is **at-least-once** — a crash between POST and the
success write replays the delivery. Consumers dedupe on the event id.

## Configuration

| Variable | Default | Meaning |
| -------- | ------- | ------- |
| `WEBHOOK_DELIVERY_ENABLED` | `true` (off under tests) | Arm the delivery sweep |
| `WEBHOOK_DELIVERY_INTERVAL_SECONDS` | `15` | Sweep cadence (worst-case added latency) |
| `WEBHOOK_AUTO_DISABLE_DAYS` | `3` | Continuous-failure window before auto-disable |
