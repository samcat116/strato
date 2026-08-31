# Audit Logging

The control plane keeps a centralized audit trail of who did what: every API
mutation, authentication events (login, logout, registration, OIDC), and — as
first-class events — every request allowed by the platform system-admin
policy, including reads. Events are fanned out to one or more configurable
backends.

## What gets recorded

Each audit event captures the actor (user, username snapshot, API key),
the organization, the HTTP method/path/status, a parsed resource reference
(type, id, action — e.g. `vms` / `<uuid>` / `start`), the client IP, and
whether the request was allowed by the system-admin policy. That last flag
is recorded as `adminBypass` (the historical name): since the Cedar cutover
it is derived from the evaluator's determining policies — admin access is a
Cedar-evaluated tier-1 allow, not a controller bypass — and it is what makes
admin activity a filterable, first-class part of the trail.

The client IP (`sourceIP`) is resolved through the shared proxy-trust
configuration (`RATE_LIMIT_TRUST_FORWARDED_FOR` /
`RATE_LIMIT_TRUSTED_PROXY_HOPS`), counting in from the right of
`X-Forwarded-For` so a client cannot forge the address on its own audit
events — see [Rate limiting](/deployment/rate-limiting#configuration).

Event types:

| Event type | When |
|---|---|
| `api.request` | Any API mutation (`POST`/`PUT`/`PATCH`/`DELETE` under `/api/`), any admin-bypassed request (including reads), and — when `AUDIT_INCLUDE_READS` is set — all reads. Denied requests (401/403) are recorded with their status. |
| `auth.login` / `auth.login_failed` | WebAuthn login success / failure |
| `auth.logout` | Session logout |
| `auth.register` | Passkey registration completing (also creates a session) |
| `auth.oidc_login` / `auth.oidc_login_failed` | OIDC callback success / failure |
| `auth.passkey_added` / `auth.passkey_removed` | Self-service passkey enrollment / removal (`/api/users/me/passkeys`). Credential changes alter who can sign in, so they are audited alongside the login events. |
| `iam.cross_org_grant` | A role granted to a principal (user or group) outside the resource's organization. Cross-org access is explicit-only and deliberately loud; the metadata names the principal and the role. |
| `iam.cross_org_revoke` | A cross-org principal's role revoked — the visible end of external access. |
| `vm.command.requested` | A durable captured command was accepted for dispatch. |
| `vm.command.completed` | A captured command reached a terminal result. A late exit after a timeout appends a second event with `correctsOutcome=timed_out`; it does not replace the timeout fact. |
| `vm.exec.requested` | An interactive VM exec session was accepted and minted. |
| `vm.exec.started` | The owning agent confirmed that the guest process started. |
| `vm.exec.ended` | An interactive session exited, was refused, timed out, disconnected, or was terminated by its operator. |
| `ssf.*` | Actions taken by the [Shared Signals](/deployment/shared-signals) receiver: `ssf.event_received`, `ssf.sessions_revoked`, `ssf.api_keys_deactivated`, `ssf.user_disabled`, `ssf.user_enabled`, `ssf.stream_verified`, `ssf.stream_updated`, `ssf.event_ignored`, `ssf.event_error`, `ssf.subject_unmatched`. Security-relevant by construction — an IdP told Strato to revoke sessions or disable a user, and the trail shows what was done about it. |

### Guest execution metadata

Guest execution events use `resourceType=vms` and the VM's canonical UUID as
`resourceID`. Their metadata is deliberately small and fixed:

- `argv` is the command encoded as a JSON array, preserving argument
  boundaries;
- `correlationID` is the durable command UUID or interactive session ID;
- `outcome` and `phase` describe the lifecycle transition;
- `exitCode`, `reason`, and `correctsOutcome` appear only when applicable.

`argv` is the exact accepted argument vector; the reason field is normalized
and bounded. Audit metadata never contains an environment variable, working
directory, stdin, stdout, stderr, captured command output, terminal frame, or
interactive transcript. The durable command result API remains the only place
captured output is returned.

Authorization and validation refusals remain visible as `api.request` events.
The VM-specific events add the accepted command/session correlation and the
asynchronous outcome that HTTP middleware cannot know.
Guest-execution refusal facts deliberately omit raw error text because request
validation errors can echo caller-controlled environment variable names; the
HTTP status and VM resource reference remain available for investigation.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `AUDIT_ENABLED` | `true` | Master switch. |
| `AUDIT_BACKENDS` | `database` | Comma-separated destinations: `database`, `log`, `loki`, `webhook`. |
| `AUDIT_INCLUDE_READS` | `false` | Also audit `GET`/`HEAD`/`OPTIONS` API requests. Admin-bypassed reads are always audited. |
| `AUDIT_WEBHOOK_URL` | — | Destination for the `webhook` backend (required when enabled). |
| `LOKI_ENDPOINT` | — | Shared with VM console logs; required for the `loki` backend. |
| `AUDIT_RETENTION_DAYS` | — | Delete `audit_events` rows older than this many days. Unset (or non-positive) keeps events forever. |
| `AUDIT_SYNCHRONOUS` | `false` | Write ordinary audit events on the request path instead of in the background. Costs every mutation an insert (and any configured HTTP POST) of latency; intended for tests. Guest-execution request and domain facts remain buffered and fail open. |
| `AUDIT_MAX_QUEUE_DEPTH` | `2048` | Events that may await background delivery before the excess is shed. |
| `AUDIT_MAX_QUEUE_BYTES` | `67108864` | Approximate retained bytes allowed in the background queue (64 MiB). |
| `AUDIT_MAX_BATCH_SIZE` | `128` | Events one drain pass ships together; the `database` backend writes a batch as a single multi-row insert. Clamped to 1024 (see [Delivery](#delivery)). |
| `AUDIT_MAX_BATCH_BYTES` | `8388608` | Approximate payload bytes one drain pass may claim (8 MiB). A single larger event is shed visibly rather than retried as an oversized batch. |

### Backends

- **`database`** — persists events to the `audit_events` table. This is the
  default, and the backend the query API reads from; without it the
  `/api/audit-events` endpoints return nothing.
- **`log`** — emits one structured `audit_event` log line per event via the
  process logger, so events follow the control plane's normal log pipeline
  (stdout, and OTLP when log export is enabled — see
  [Logging](/deployment/logging)).
- **`loki`** — pushes events directly to Loki under `service_name=strato-audit`
  with an `event_type` label; the log line is the full event as JSON.
- **`webhook`** — POSTs each event as a JSON object to `AUDIT_WEBHOOK_URL`, for
  SIEM ingestion or custom collectors. Delivery is best-effort with a 5-second
  timeout; failures are logged and never fail the originating request.

Backends compose: `AUDIT_BACKENDS=database,loki,webhook` writes each event to
all three.

### Delivery

Recording an event only buffers it: a background task drains the buffer in
batches and writes every backend concurrently, so request latency is
independent of how healthy the destinations are — a Loki outage or a slow SIEM
delays the trail, never the API. Shutdown flushes the buffer, and waits for the
batch already being delivered, before the database pools close; a graceful stop
loses nothing unless a backend is still hung when the flush deadline expires,
and that case is logged.

The trade is that an event is no longer durable the instant its response
returns — a caller that reads `/api/audit-events` immediately after a mutation
may not see the row yet. For compliance regimes that require an ordinary audit
event committed before the client is told the mutation succeeded, set
`AUDIT_SYNCHRONOUS=true` and accept the per-mutation latency. The generic
`api.request` facts for VM guest-execution routes and the `vm.command.*` and
`vm.exec.*` domain facts are the deliberate exception: STR-84 requires those
producers to remain independent of audit availability, so they always use the
bounded background queue.

The buffer is bounded by both `AUDIT_MAX_QUEUE_DEPTH` and
`AUDIT_MAX_QUEUE_BYTES`. Drained batches are likewise bounded by count and
`AUDIT_MAX_BATCH_BYTES`, so a burst of large exact-argv events cannot turn one
database insert or webhook drain into an unbounded allocation. If events arrive
faster than the backends accept them for long enough to hit either limit, or a
single record exceeds the batch byte limit, the excess is dropped and counted.
The control plane logs `Audit events shed under backpressure` with the running
total and limit reason (the first drop, then every hundredth). A trail with a
gap in it says so out loud; sustained shedding means a backend needs attention
or the queue limits need raising.

`AUDIT_MAX_BATCH_SIZE` is clamped to 1024. A batch is written as one multi-row
INSERT, and Postgres rejects a statement carrying more than 65535 bind
parameters, so an unclamped value in the thousands would fail every insert
rather than write a bigger batch. A larger request is clamped and logged.

## Querying the trail

- `GET /api/audit-events` — system administrators only; the full,
  cross-organization trail.
- `GET /api/organizations/:organizationID/audit-events` — organization admins;
  events scoped to that organization.

Both endpoints return newest-first pages:

```
GET /api/audit-events?eventType=api.request&adminOnly=true&from=2026-07-01T00:00:00Z&limit=100
```

| Query parameter | Meaning |
|---|---|
| `eventType` | Exact event type (`api.request`, `auth.login`, ...) |
| `userID` | Filter to one actor |
| `organizationID` | (Global endpoint only) filter to one organization |
| `resourceType` / `resourceID` | Apply both predicates to one resource. For VM history, use `resourceType=vms` and the canonical VM UUID. |
| `adminOnly` | `true` → only admin-bypassed events |
| `from` / `to` | ISO 8601 timestamps (epoch seconds also accepted) |
| `limit` / `offset` | Paging; limit defaults to 50, capped at 500 |

The response is `{ events, total, limit, offset }`.

The system-administrator audit page exposes the five guest execution event
types. Paste a VM UUID into its VM filter, or select a VM resource cell in the
table, to send both resource predicates. Execution rows show argv, outcome,
exit code, phase, bounded reason, correlation, and correction metadata; missing
or malformed historical metadata renders as unavailable rather than breaking
the page.

## Retention

Set `AUDIT_RETENTION_DAYS` to bound the `database` backend: an hourly sweep
deletes `audit_events` rows older than the cutoff (the first pass runs at
boot). With multiple control-plane replicas, a Valkey lock makes the sweep a
cluster singleton, so only one replica prunes per interval.

Retention is off by default — with `AUDIT_RETENTION_DAYS` unset, the table
grows unbounded and events are kept forever. The sweep only prunes the
database; events shipped to `log`, `loki`, or `webhook` are subject to that
system's own retention. For compliance regimes that require long-lived audit
trails, ship events externally and set a retention window that satisfies your
local query needs.
