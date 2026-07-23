# Observability: Metrics & Traces

The control plane emits OpenTelemetry **metrics** and **traces** (and logs) over
OTLP. Metrics started with the failure modes the 2026-06-12 end-to-end test made
painful to diagnose — agents silently going away, heartbeats drying up, VMs
landing in `.error` — and have since grown to cover the request path and the
core control-loop subsystems. Traces give a per-request span tree so a slow or
failing API call can be followed through authorization, scheduling, and the
agent sync it triggers.

This page is the catalog of those signals and the alert runbook built on them.

## Enabling metrics & traces

Metrics flow through the swift-metrics facade and traces through the
swift-distributed-tracing facade, both backed by the OTLP exporter when
OpenTelemetry is bootstrapped. Controlled by environment variables (see
`configure.swift`):

| Variable | Default | Notes |
|----------|---------|-------|
| `OTEL_METRICS_ENABLED` | `true` (the compose deployment sets it to `false`) | Master switch for metric export |
| `OTEL_TRACES_ENABLED` | `true` | Master switch for trace/span export |
| `OTEL_LOGS_ENABLED` | `true` | Master switch for log export |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `localhost:4317` (gRPC) | Where to ship OTLP |
| `OTEL_SERVICE_NAME` | `strato-control-plane` | `service.name` resource attribute |
| `OTEL_RESOURCE_ATTRIBUTES` | — | Extra resource attributes; merged over the built-in `service.version` / `service.instance.id` / `deployment.environment.name` |

When a pillar is disabled, its facade uses a no-op backend — emission call sites
(`Counter`/`Gauge`/`Timer`, `withSpan`) stay in the code but cost nothing. The
bootstrap is also skipped entirely under the `.testing` environment.

Production should run with `OTEL_METRICS_ENABLED=true` pointed at a collector.
The Helm chart wires this via the `opentelemetry.*` values.

## Scraping the chart from an existing Prometheus

The control plane has **no `/metrics` endpoint of its own** — it pushes OTLP to
a collector. What a Prometheus scrapes is the collector's `prometheus` exporter
(port `8889`), which re-exposes everything in the metric catalog below.

That exporter is controlled by `opentelemetry.prometheusExport`, which is
independent of `opentelemetry.prometheus` (the chart's *bundled* Prometheus
StatefulSet). To scrape strato from a monitoring stack you already run, without
also standing up a second Prometheus and its PVC:

```yaml
opentelemetry:
  enabled: true

  prometheusExport:
    enabled: true          # default: exposes the scrape endpoints
    serviceMonitor:
      enabled: true        # needs the monitoring.coreos.com CRDs
      labels:
        release: kube-prometheus-stack   # match your operator's serviceMonitorSelector

  prometheus:
    enabled: false         # no bundled Prometheus, no 10Gi PVC
    # Keeps the Workload Identity "Issuance" panel working without it
    url: "http://kube-prometheus-stack-prometheus.monitoring.svc:9090"
```

This renders two ServiceMonitors:

| Target | Port | What it carries |
|--------|------|-----------------|
| `<release>-otel-collector` | `prometheus` (8889) | Strato application metrics (the catalog below) |
| `<release>-otel-collector` | `metrics` (8888) | The collector's own pipeline health — set `serviceMonitor.collectorTelemetry: false` to drop it |
| `<release>-spire-server` | `metrics` (9988) | SPIRE SVID-signing counters, one target per replica |

Without the Prometheus Operator, set `prometheusExport.podAnnotations: true`
instead for `prometheus.io/scrape` annotation discovery (plain Prometheus
`kubernetes_sd`, Grafana Alloy, DataDog).

Logs and traces stay on the OTLP path; only metrics need the scrape endpoint.
For traces, see [Sending traces to a backend](#sending-traces-to-a-backend)
below.

Setting `opentelemetry.prometheusExport.enabled: false` **and**
`opentelemetry.prometheus.enabled: false` removes the exporter, its Service and
container ports, and SPIRE's telemetry listener entirely.

::: warning networkPolicy
With `networkPolicy.enabled: true`, an external `opentelemetry.prometheus.url`
on a non-443 port needs its own rule in `networkPolicy.egress` — the chart can
only scope the built-in rule to its own Prometheus pods.
:::

## Sending traces to a backend

Spans reach the chart's collector over OTLP, but by default the collector's
traces pipeline ends in the `debug` exporter: it receives every span, logs a
one-line summary per batch, and drops them. **Enabling `traces` alone does not
store a trace anywhere.** Give the pipeline a real destination:

```yaml
opentelemetry:
  traces:
    enabled: true
    exporter:
      otlp:
        # host:port, no scheme. gRPC, matching what the control plane speaks.
        endpoint: tempo.monitoring.svc.cluster.local:4317
        insecure: true      # plaintext; fine for a same-cluster backend
```

Anything that speaks OTLP works — Tempo, Jaeger (`:4317` with its OTLP receiver
enabled), or an upstream collector that fans out further.

| Value | Default | Notes |
|-------|---------|-------|
| `traces.exporter.otlp.endpoint` | `""` | `host:port`. Empty leaves the pipeline on `debug` |
| `traces.exporter.otlp.insecure` | `true` | Plaintext gRPC. Set `false` for TLS |
| `traces.exporter.otlp.caFile` | `""` | PEM CA bundle path, mounted separately. Only read when `insecure: false` |
| `traces.exporter.otlp.headers` | `{}` | Per-export headers — a tenant ID (`X-Scope-OrgID`) or API token |

Setting an endpoint also **removes** `debug` from the traces pipeline, so the
collector stops narrating every batch into its own stdout — which your log
shipper would otherwise pay to store.

::: warning networkPolicy
`networkPolicy.egress` allows port 4317 already, but that rule is for the
control plane reaching the collector. A collector shipping to a backend on some
other port (or off-cluster) needs its own rule.
:::

## Metric catalog

All metrics are defined and documented in one place:
`control-plane/Sources/App/Telemetry/Telemetry.swift`. Emission goes through the
swift-metrics facade, so every call site is a no-op unless `OTEL_METRICS_ENABLED`
is on.

### Request layer (RED)

Emitted once per HTTP request by `MetricsMiddleware`, so the whole API surface is
covered without per-route instrumentation. `route` is the matched **route
pattern** (`/api/vms/:vmID`), never the concrete path, so cardinality stays
bounded; unmatched requests fall back to `unmatched`.

| Metric | Type | Labels | Meaning |
|--------|------|--------|---------|
| `strato_http_server_requests_total` | counter | `method`, `route`, `status` = `2xx`…`5xx` | Request count by route and status class |
| `strato_http_server_request_duration_seconds` | timer | `method`, `route` | Request latency distribution |

### Agent lifecycle & VM health

| Metric | Type | Labels | Meaning |
|--------|------|--------|---------|
| `strato_agent_connections_total` | counter | — | Agent successfully (re)registered |
| `strato_agent_disconnections_total` | counter | `reason` = `connection_closed` \| `unregister` \| `stale` | Agent connection ended |
| `strato_agent_registration_failures_total` | counter | `reason` = `invalid_token` \| `expired_token` \| `register_error` \| `token_save_failed` \| `unsupported_protocol` \| `organization_scope_mismatch` \| `missing_organization_scope` | A registration attempt was rejected |
| `strato_agent_send_failures_total` | counter | `kind` = `message` \| `success` \| `error` | Failed to encode/send a message to an agent over its WebSocket |
| `strato_agent_up` | gauge | `agent` = agent name | `1` while connected, `0` once disconnected. Durable per-agent up/down signal — keeps reporting `0` after the stale sweep, so it's the basis for the "agent down" alert |
| `strato_agent_heartbeat_staleness_seconds` | gauge | `agent` = agent name | Seconds since the agent's last heartbeat, recorded each ~30s cycle **while connected**. Secondary "heartbeats slowing" signal; stops updating once the agent is swept |
| `strato_vm_errors_total` | counter | `reason` = `reconciliation` \| `stuck_transition` \| `agent_reported` \| `operation_failed` \| `stuck_operation` \| `convergence_failed` | A VM transitioned into `.error` |
| `strato_vm_drift_total` | counter | — | A VM's observed state changed out-of-band with no operation in flight (issue #260) |

### Agent auto-update rollout (issue #434)

| Metric | Type | Labels | Meaning |
|--------|------|--------|---------|
| `strato_agent_auto_update_assignments_total` | counter | — | The rollout sweep assigned an agent its target version |
| `strato_agent_auto_update_converged_total` | counter | — | An assigned agent re-registered at its target version |
| `strato_agent_auto_update_failures_total` | counter | `reason` = `agent_reported` \| `health_budget` | An assigned update failed terminally, halting the rollout |
| `strato_agent_auto_update_parked_total` | counter | — | An assigned agent stayed blocked past the health budget and was parked |

### Control loop (scheduler, reconciliation)

| Metric | Type | Labels | Meaning |
|--------|------|--------|---------|
| `strato_scheduler_placements_total` | counter | `strategy`, `outcome` = `success` \| `no_candidate` \| `error` | A placement decision resolved |
| `strato_scheduler_placement_duration_seconds` | timer | `strategy` | Placement selection latency |
| `strato_agent_sync_total` | counter | `outcome` = `sent` \| `failed` | A desired-state sync to a locally-socketed agent resolved |
| `strato_agent_sync_duration_seconds` | timer | — | Assemble + send latency for a desired-state sync |

### Authorization (Cedar)

Every `IAMAuthorizer.authorize` funnels through the same instrumented entry, so
this is the allow/deny rate and evaluation latency for the entire API.

| Metric | Type | Labels | Meaning |
|--------|------|--------|---------|
| `strato_authz_decisions_total` | counter | `decision` = `allow` \| `deny` | A Cedar decision was evaluated (503/500 faults are not counted) |
| `strato_authz_evaluation_duration_seconds` | timer | — | Entity-slice load + policy-set evaluation latency |

### IPAM

| Metric | Type | Labels | Meaning |
|--------|------|--------|---------|
| `strato_ipam_allocations_total` | counter | `family` = `ipv4` \| `ipv6` | A NIC address was allocated from a network's subnet |
| `strato_ipam_allocation_failures_total` | counter | `family`, `reason` = `pool_exhausted` \| `invalid_subnet` \| `invalid_gateway` | An allocation failed; `pool_exhausted` is the capacity signal |

### Notes on the labels

- **`strato_agent_disconnections_total{reason}`** — `connection_closed` is the
  WebSocket close handler, `unregister` is a graceful agent shutdown, `stale` is
  the heartbeat monitor sweeping an agent that went quiet for >60s.
- **`strato_vm_errors_total{reason}`** — `reconciliation` fires when a VM the DB
  maps to an agent is absent from that agent's heartbeat; `stuck_transition`
  fires when a VM sits in `.starting`/`.stopping` past the 120s timeout;
  `agent_reported` fires when an agent pushes an `.error` status (e.g. a failed
  create or boot). A failed VM create surfaces as `agent_reported` if the agent
  reports it, otherwise as `reconciliation` once the VM goes missing from a
  heartbeat — check the control-plane logs (`http_request` / warnings) alongside.

## Distributed tracing

Traces are enabled with `OTEL_TRACES_ENABLED` (default `true`) and export over
the same OTLP endpoint as metrics. Every signal is stamped with the
`service.version`, `service.instance.id` (the coordination replica ID),
`deployment.environment.name`, and (when built with one) `vcs.revision` resource
attributes, so a trace can be tied back to the exact build and replica that
produced it.

Note that enabling the pillar only gets spans as far as the collector — see
[Sending traces to a backend](#sending-traces-to-a-backend) for storing them.

### Coverage

- **Per-request server span** — `TracingMiddleware` opens one span per HTTP
  request with HTTP semantic-convention attributes (`http.request.method`,
  `http.route`, `http.response.status_code`, …), named by the matched route. It
  also extracts inbound W3C `traceparent`, so a client or gateway trace continues
  through the control plane, and publishes the span on `request.serviceContext`
  so everything below nests under it.
- **`iam.authorize`** — one child span per Cedar decision, with `iam.action`,
  `iam.resource_type`, `iam.principal`, and `iam.decision`.
- **`scheduler.select_agent`** — one span per placement, with `scheduler.strategy`,
  `scheduler.candidate_count`, `scheduler.selected_agent`, and (on failure)
  `scheduler.outcome`.
- **`agent.desired_state_sync`** — a producer span per desired-state sync pushed
  to a locally-socketed agent, with `agent.id`, `sync.id`, and `sync.vm_count`.
- **`fluent.query`** — one client span per database query, with
  `fluent.query.operation` (`read`/`update`/…), `fluent.query.collection` (the
  table), `fluent.query.namespace`, and a combined `fluent.query.summary`. No
  call site in this repo opens it: FluentKit emits it itself (fluent-kit 1.57.0,
  the version we resolve), so it appears the moment a real tracer is installed.
- **Valkey commands** — likewise emitted by the client library rather than by
  any call site here: valkey-swift opens a client span per command, named after
  the command (`GET`, `SETEX`, `PUBLISH`, …) plus `Pipeline` and `MULTI` for
  batched and transactional execution, with `db.system.name`, `db.operation.name`,
  and `server.address`/`server.port`.
- **Outbound HTTP** — one client span per request through the shared `HTTPClient`
  (OIDC discovery/token/userinfo/JWKS, OCI registry manifests, webhook
  deliveries, audit export), from AsyncHTTPClient's own instrumentation, named
  after the HTTP method and carrying `http.request.method` and
  `http.status_code`.

Spans go through the swift-distributed-tracing facade, which installs a no-op
tracer unless OpenTelemetry bootstraps a real one — so the `withSpan` call sites
cost nothing when tracing is disabled, and are safe under `.testing` (where OTel
is never bootstrapped).

### Bootstrap ordering (why client spans can silently vanish)

`configure(_:)` bootstraps OpenTelemetry **first**, ahead of every client it
configures. This is load-bearing, not stylistic. Fluent resolves the tracer per
query, but the Valkey and HTTP clients resolve it once, when their
*configuration value* is constructed:

- `HTTPClient.Configuration.TracingConfiguration.init()` stores
  `InstrumentationSystem.tracer`. Vapor's `app.http.client.configuration` is a
  get-modify-set property, so even reading it to set an unrelated option
  materializes a config that has already captured a tracer.
- `ValkeyTracingConfiguration.tracer` defaults the same way, captured when
  `ValkeyClientConfiguration` is built in `configureValkey`.

Whatever tracer is installed at that moment is the one those clients use for the
life of the process. Bootstrapping afterwards left both holding the `NoOpTracer`
— both libraries were instrumented and enabled, and neither emitted a single
span. If Valkey or outbound-HTTP spans disappear from the backend while
`fluent.query` and the request spans keep arriving, suspect that something was
constructed ahead of `bootstrapObservability()`.

### Most `fluent.query` spans are roots, and that's expected

In a trace backend you will see far more `fluent.query` spans standing alone as
their own root than nested under a request — on the dev cluster, 95 of 100
sampled traces containing a `fluent.query` were rooted at `fluent.query` itself,
and the other 5 nested under `agent.desired_state_sync`.

This is not broken context propagation. FluentKit captures whatever
`ServiceContext` is current when the query is *built*, and most of the control
plane's query volume comes from timer-driven background loops — the periodic
desired-state sync, the agent heartbeat monitor, the audit-retention sweep,
webhook delivery, SSF poll delivery — which run outside any request and so have
no enclosing span to attach to. Queries issued while serving a request do nest:
Vapor's `TracingMiddleware` opens the server span with `withSpan`, which sets
the task-local `ServiceContext` for the rest of the responder chain. Orphan
`fluent.query` roots are background work, not a lost `traceparent`.

Valkey command spans may be a different story. Verified locally against a
collector: an `EVAL` issued by the session middleware **inside** a `GET /api/vms`
request came out as its own root, where the reasoning above says it should have
nested. One observation on one local run is not a diagnosis — it may be that
valkey-swift resolves the span on a connection-pool-owned task that did not
inherit the caller's `ServiceContext`. Worth confirming against a real trace
backend before treating unparented Valkey spans as normal.

### Correlating traces with logs

`entrypoint.swift` bootstraps SwiftLog with swift-otel's logging metadata
provider, so any line logged inside a span carries `trace_id`, `span_id` and
`trace_flags`. The default console handler renders metadata as a sorted,
bracketed suffix:

```
[ INFO ] http_request [method: GET, path: /api/vms, span_id: 5f3a…, trace_flags: 1, trace_id: 9c1e…]
```

That is what makes a log line addressable from its trace. In Grafana, a Loki
derived field extracting `trace_id: ([0-9a-f]+)` links each line to the trace in
Tempo, and Tempo's `tracesToLogsV2` links the other way.

The provider costs nothing when there is no active span: it reads
`ServiceContext.current` and returns no metadata, which covers every line logged
before OTel bootstraps and every deployment running with tracing off.

### Not yet traced

The agent side of the WebSocket is not instrumented: a desired-state sync's
`agent.desired_state_sync` producer span ends at the send, and the agent does not
continue the trace through reconciliation. Cross-replica RPC and nudges
forwarded over Valkey pub/sub likewise do not propagate trace context, so a
mutation handled by another replica starts a new trace there.

## Alert runbook

Thresholds are starting points; tune to your fleet size and SLOs.

### Agent disconnected too long

- **Condition:** `strato_agent_up == 0` for more than **N minutes** (suggest
  5 min) — e.g. `min_over_time(strato_agent_up[5m]) == 0`. The `agent` label names
  the down node. Use this gauge, **not** `strato_agent_heartbeat_staleness_seconds`:
  the staleness gauge stops updating once the 60s stale sweep removes the agent
  from memory, so it never climbs to a 5-minute threshold. `strato_agent_up` keeps
  reporting `0` after the sweep, so the alert actually fires.
- **Severity:** warning at 5 min, page at 15 min (capacity loss / VMs unmanaged).
- **First checks:** is the agent process alive on the node? Network path to the
  control plane? Look for `register_error` / token issues in
  `strato_agent_registration_failures_total` (an agent stuck in a reconnect loop
  with a bad token will show rising registration failures).

### Any VM in `.error`

- **Condition:** `increase(strato_vm_errors_total[15m]) > 0`, or a nonzero count
  of VMs in `.error` in the database.
- **Severity:** warning (operator attention), page if many VMs flip at once
  (likely an agent crash taking its VMs down).
- **First checks:** the `reason` label points at the mechanism. `reconciliation`
  / `agent_reported` in bulk for one agent ⇒ that agent crashed or lost its VMs;
  cross-reference `strato_agent_disconnections_total`. `stuck_transition` ⇒ an
  operation's terminal confirmation never arrived (lost status update or an agent
  that died mid-op).

### Registration failures spiking

- **Condition:** `increase(strato_agent_registration_failures_total[10m])`
  above a small threshold.
- **Severity:** warning. A burst of `invalid_token` / `expired_token` usually
  means a misconfigured or restarting agent presenting a stale token; a burst of
  `register_error` points at a control-plane/database problem.

### Readiness probe failing

- **Condition:** `GET /health/ready` returns non-`healthy` (database check down).
- **Severity:** page — the control plane cannot serve requests reliably.
- **First checks:** database connectivity; the `identity` block in the health
  response confirms *which* instance is failing (see
  [Logging & Log Visibility](/deployment/logging)).

## Verifying locally

The compose deployment ships with OTel export disabled. To exercise metrics,
run the control plane with `OTEL_METRICS_ENABLED=true` and point
`OTEL_EXPORTER_OTLP_ENDPOINT` at an OTLP collector of your own, then:

- Kill an agent → expect `strato_agent_up{agent="…"}` to drop to `0` (and stay
  there) and a `strato_agent_disconnections_total{reason="stale"}` (or
  `connection_closed`) increment. While it's still in the 60s grace window,
  `strato_agent_heartbeat_staleness_seconds` climbs before the sweep removes it.
- Trigger a VM failure → expect `strato_vm_errors_total` to increment with the
  matching `reason`.
