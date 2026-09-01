# Logging & Log Visibility

Operational notes on getting control-plane and agent logs to disk/console reliably,
plus the HTTP request log. Motivated by the 2026-06-12 end-to-end test, where
control-plane logs never reached disk because stdout was block-buffered under
`nohup`, and the real cause of a failure was invisible until far too late.

## Where logs go

Both the control plane and the agent log to **stdout/stderr** via SwiftLog. They
do not write log files themselves — capture is the responsibility of whatever
supervises the process. The control plane keeps Vapor's console format, while
the agent writes JSON Lines to stderr.

The control plane always installs that console sink. When
`OTEL_LOGS_ENABLED=true`, the same SwiftLog records are also exported over OTLP;
the OTLP backend is multiplexed with the console backend and does not replace
it. `OTEL_LOGS_ENABLED=false` therefore means console-only logging, not no
logging. Metrics and traces can be enabled or disabled independently.

The Helm chart defaults OTLP log export on and points it at the configured OTel
collector, so control-plane records appear both in Kubernetes container logs
and in the collector's logs pipeline. The compose deployment disables OTLP
signals and keeps the console sink.

**Verbosity** is set with the `LOG_LEVEL` environment variable (a SwiftLog
level: `trace`, `debug`, `info`, `notice`, `warning`, `error`, `critical`;
default `info`) — the compose stack reads it from `.env`, and the Helm
chart sets it from `strato.logLevel`.

Two other subsystems ride this same stdout pipeline:

- The audit `log` backend emits one structured `audit_event` line per event
  — see [Audit logging](/deployment/audit-logging).
- When tracing is enabled, every line logged inside a span carries
  `trace_id` / `span_id` metadata for log↔trace correlation — see
  [Observability](/deployment/observability#correlating-traces-with-logs).

## Agent JSON record contract

Each agent event is one UTF-8 JSON object followed by one line feed. Its
top-level fields are `timestamp`, `level`, `label`, `source`, `message`,
`metadata`, and `truncated`. When truncation occurs, `truncation` identifies the
affected part and reports each byte limit.

```json
{"label":"strato-agent","level":"ERROR","message":"VM start failed","metadata":{"error.message":"permission denied","error.type":"POSIXError","service.name":"strato-agent","service.version":"1.2.3","strato.vm.id":"..."},"source":"StratoAgent","timestamp":"2026-08-30T20:14:23.418Z","truncated":false}
```

The contract is designed for both humans and line-oriented ingestion:

- JSON encoding deterministically sorts object keys and escapes quotes,
  backslashes, newlines, carriage returns, NULs, and other control characters.
  User-supplied text cannot create a second record.
- UTC timestamps use ISO 8601 with fractional seconds.
- A SwiftLog typed error is retained as `error.type` and `error.message`; those
  fields take precedence over manually supplied fields with the same names.
- Message text is limited to 8 KiB of UTF-8. Encoded metadata is limited to
  16 KiB, and the complete record, including its terminal line feed, is limited
  to 16 KiB. `truncated: true` plus the `truncation` object makes every reduction
  explicit.
- The handler constructs the complete record before taking a process-wide write
  lock. Concurrent loggers therefore write whole records without interleaving.

The total ceiling is intentionally below journald's usual 48 KiB `LineMax`, so
systemd does not split a valid application record before Alloy sees it.

## Metadata taxonomy

Use the exact keys below for SwiftLog console fields and OTLP attributes. OTel
semantic-convention keys are used where their meaning is exact; Strato-owned
identifiers live under `strato.*` so they cannot be confused with generic OTel
concepts.

| Concept | Canonical key | Meaning |
| --- | --- | --- |
| Service | `service.name` | Logical executable: normally `strato-control-plane` or `strato-agent` |
| Instance | `service.instance.id` | UUID unique to one process boot |
| Environment | `deployment.environment.name` | Configured deployment environment; omitted when the agent has no such setting |
| Version | `service.version` | Version of the executable that emitted the event |
| Revision | `vcs.revision` | Optional source revision of the emitting build |
| Request | `strato.request.id` | HTTP request or wire-message correlation ID |
| Operation | `strato.operation.id` | Accepted mutation or operation UUID |
| Agent ID | `strato.agent.id` | Persisted agent database UUID only |
| Agent name | `strato.agent.name` | Operator-selected registration name or hostname |
| Agent identity | `strato.agent.identity` | Full SPIFFE identity/key |
| VM | `strato.vm.id` | VM UUID |
| Sandbox | `strato.sandbox.id` | Sandbox UUID |
| Project | `strato.project.id` | Project UUID |
| Session | `strato.session.id` | Console, guest-exec, or OAuth session ID |
| Session kind | `strato.session.kind` | `console`, `guest_exec`, or `oauth` |

When an event contains multiple IDs of the same entity, qualify the role:
`strato.agent.claimed.id`, `strato.vm.previous.id`, and so on. Collections use
`.ids` and a metadata array. Do not repurpose `service.version` for a peer,
protocol, policy, or configuration version.

Both logging bootstraps attach stable base metadata. The control plane supplies
service name, version, environment, and the same process UUID used by health and
OTel resources. The agent supplies service name, per-boot instance UUID,
version, and build revision; its resolved registration name is attached as
`strato.agent.name`. The internal metadata-listener child uses a deliberately
minimal relay format, and its parent republishes those lines through the agent
handler with the parent's base metadata.

### Legacy-key transition

Producers must emit canonical keys now. Through **2026-12-01**, the agent handler
translates only these proven spelling aliases:

- `requestID`, `requestId`, `request_id`, `request-id` → `strato.request.id`
- `vmID`, `vmId`, `vm_id` → `strato.vm.id`
- `sandboxID`, `sandboxId`, `sandbox_id` → `strato.sandbox.id`
- `projectID`, `projectId`, `project_id` → `strato.project.id`

Translation emits only the canonical key. If a layer supplies both spellings,
the canonical value wins deterministically; later SwiftLog metadata layers still
override earlier layers. Agent and session variants are not aliases because the
old names mixed database IDs, operator names, SPIFFE identities, and different
session kinds.

Vapor continues to attach `request-id` to control-plane request loggers during
the same transition, and always-on middleware mirrors its value to
`strato.request.id`. After the date above, delete the handler alias table and
have the middleware remove Vapor's provider-owned key after copying it; the
canonical request key remains.

## Deployment ingestion compatibility

The repository-controlled paths preserve the record boundary and payload:

- The systemd agent unit captures stderr in journald. Alloy's
  `loki.source.journal` selects the unit and forwards journald's `MESSAGE`
  unchanged; it does not parse or rewrite the old flat format. The new JSON
  object therefore reaches Loki as one parseable line while the existing
  `agent=<agent name>` stream label remains unchanged.
- Docker and Kubernetes capture stderr one line at a time. The compose stack has
  no application-log parser, and the Helm workload runs the control-plane binary
  directly, so neither path depends on the agent's former rendering.
- The control-plane ConsoleKit rendering is intentionally unchanged. Existing
  Loki/Grafana extraction such as the documented `trace_id` derived-field regex
  remains compatible, while the same canonical metadata is available to the
  optional OTLP log sink.

Handler contract tests decode every emitted record as JSON and cover control
character escaping, typed errors, deterministic metadata, fractional UTC
timestamps, byte ceilings, truncation signals, alias precedence, and concurrent
write serialization.

### Production: run under a supervisor that captures stdout/stderr

Run the control plane and agent under a process supervisor that captures their
streams to a durable, queryable sink:

- **systemd**: set `StandardOutput=journal` and `StandardError=journal` (the
  default for most units). `journald` line-buffers and timestamps each line, so
  there is no block-buffering problem.
- **Kubernetes**: the container runtime captures stdout/stderr to the node log
  and `kubectl logs` / your log shipper picks it up. The Helm chart runs the
  binary directly as the container entrypoint, so this works out of the box.

No application change is needed for this path — a console/journal sink is
line-oriented, so logs appear promptly.

### Development: line-buffer when redirecting to a file

If you run a binary by hand and redirect it to a file — `nohup ... > file.log`
— the rules change. When stdout is a regular file rather than a TTY, glibc
**block-buffers** it, so log lines can sit in a 4–8 KB buffer for minutes, or
be lost entirely if the process is killed, before reaching the file.

Launch under `stdbuf -oL -eL` to force line buffering on stdout/stderr:

```sh
nohup stdbuf -oL -eL swift run > /tmp/strato-control-plane.log 2>&1 &
```

`stdbuf` ships with GNU coreutils. On macOS it isn't present by default —
install coreutils (`brew install coreutils`), where it's available as
`gstdbuf` unless the `gnubin` PATH is added.

Alternatively, skip the redirect and `tail -f` a TTY instead.

## HTTP request logging (control plane)

`RequestLoggingMiddleware` emits one structured line per HTTP request:

```
http_request method=GET http.route=/health/live path=/health/live status=200 durationMs=1.4
```

For matched requests, `http.route` and the compatibility `path` field contain
the registered route template (for example, `/auth/claim/:token`), never the
concrete URL. Unmatched requests use the constant `unmatched`. This keeps access
logs safe for secret-bearing path parameters and bounded for route-level queries;
query values are never included. Authorization denials, rate-limit events, and
sanitized request-error events use the same route value.

Failed requests are logged too: a thrown `Abort` (401/403/404/…) propagates back
through the middleware as an error, so the status is derived from the error
(`AbortError.status`, else `500`) to match what the client receives. `5xx`
responses are logged at `error` level, everything else at `info` — always as the
same `http_request` event, so it's one status-bearing line per request.
Thrown errors include only their stable type in `error`; potentially
request-derived descriptions are omitted and can be correlated through
`request-id`.

**Toggle:** the `REQUEST_LOGGING` environment variable (`true`/`false`). When
unset it defaults to **on outside `.production`** and off in production; set
`REQUEST_LOGGING=true` to enable it in production for debugging. The toggle
controls ordinary `http_request` access events only. Thrown errors always emit a
sanitized `http_request_error` event with status, error type, route, and request
ID so production failures remain visible without logging error descriptions.

## Service identity on the health endpoints

`GET /health/live` and `GET /health/ready` include an `identity` object
(`instanceId`, `startedAt`, `version`, `gitSHA`, `environment`). `instanceId` is
unique per process boot, so two control planes answering the same port are
immediately distinguishable — the signal that was missing when a stale duplicate
silently intercepted port 8080. See `BuildInfo.swift`.
