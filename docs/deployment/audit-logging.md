# Audit Logging

The control plane keeps a centralized audit trail of who did what: every API
mutation, authentication events (login, logout, registration, OIDC), and — as
first-class events — every request served through the system-admin permission
bypass, including reads. Events are fanned out to one or more configurable
backends.

## What gets recorded

Each audit event captures the actor (user, username snapshot, API key),
the organization, the HTTP method/path/status, a parsed resource reference
(type, id, action — e.g. `vms` / `<uuid>` / `start`), the client IP, and
whether the request used the system-admin bypass.

Event types:

| Event type | When |
|---|---|
| `api.request` | Any API mutation (`POST`/`PUT`/`PATCH`/`DELETE` under `/api/`), any admin-bypassed request (including reads), and — when `AUDIT_INCLUDE_READS` is set — all reads. Denied requests (401/403) are recorded with their status. |
| `auth.login` / `auth.login_failed` | WebAuthn login success / failure |
| `auth.logout` | Session logout |
| `auth.register` | Passkey registration completing (also creates a session) |
| `auth.oidc_login` / `auth.oidc_login_failed` | OIDC callback success / failure |

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `AUDIT_ENABLED` | `true` | Master switch. |
| `AUDIT_BACKENDS` | `database` | Comma-separated destinations: `database`, `log`, `loki`, `webhook`. |
| `AUDIT_INCLUDE_READS` | `false` | Also audit `GET`/`HEAD`/`OPTIONS` API requests. Admin-bypassed reads are always audited. |
| `AUDIT_WEBHOOK_URL` | — | Destination for the `webhook` backend (required when enabled). |
| `LOKI_ENDPOINT` | — | Shared with VM console logs; required for the `loki` backend. |
| `AUDIT_RETENTION_DAYS` | — | Delete `audit_events` rows older than this many days. Unset (or non-positive) keeps events forever. |

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
| `adminOnly` | `true` → only admin-bypassed events |
| `from` / `to` | ISO 8601 timestamps (epoch seconds also accepted) |
| `limit` / `offset` | Paging; limit defaults to 50, capped at 500 |

The response is `{ events, total, limit, offset }`.

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
