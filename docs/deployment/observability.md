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
| `OTEL_METRICS_ENABLED` | `true` | Master switch for metric export |
| `OTEL_TRACES_ENABLED` | `true` | Master switch for trace/span export |
| `OTEL_LOGS_ENABLED` | `true` | Adds OTLP log export; console/stdout logging always remains enabled |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `localhost:4317` (gRPC) | Where to ship OTLP |
| `OTEL_SERVICE_NAME` | `strato-control-plane` | `service.name` resource attribute |
| `OTEL_RESOURCE_ATTRIBUTES` | — | Extra resource attributes; merged over the built-in `service.version` / `service.instance.id` / `deployment.environment.name` |

The compose deployment defaults all **three** `OTEL_*_ENABLED` variables to
`false` — its Prometheus and Loki serve agent host telemetry and VM console
logs, not control-plane OTLP export. Metrics can be opted in from `.env` with
`OTEL_METRICS_ENABLED=true` and an `OTEL_EXPORTER_OTLP_ENDPOINT` reachable from
the control-plane container; logs and traces remain disabled by the Compose
manifest.

When metrics or traces are disabled, their facade uses a no-op backend —
emission call sites (`Counter`/`Gauge`/`Timer`, `withSpan`) stay in the code but
cost nothing. Disabling OTLP logs leaves the console backend in place. The OTel
backends are skipped entirely under the `.testing` environment.

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
| `strato_agent_registration_failures_total` | counter | `reason` = `register_error` \| `unsupported_protocol` \| `organization_scope_mismatch` \| `missing_organization_scope` \| `same_named_networks_unsupported` | A registration attempt was rejected |
| `strato_agent_send_failures_total` | counter | `kind` = `message` \| `success` \| `error` | Failed to encode/send a message to an agent over its WebSocket |
| `strato_agent_up` | gauge | `agent` = agent name | `1` while connected, `0` once disconnected. Durable per-agent up/down signal — keeps reporting `0` after the stale sweep, so it's the basis for the "agent down" alert |
| `strato_agent_heartbeat_staleness_seconds` | gauge | `agent` = agent name | Seconds since the agent's last heartbeat, recorded each ~30s cycle **while connected**. Secondary "heartbeats slowing" signal; stops updating once the agent is swept |
| `strato_vm_errors_total` | counter | `reason` = `reconciliation` \| `convergence_failed` \| `stuck_convergence` \| `mutation_failed` | A VM transitioned into `.error` |
| `strato_vm_drift_total` | counter | — | A VM's observed state changed out-of-band with no mutation in flight (issue #260) |
| `strato_desired_state_assembly_failures_total` | counter | `kind` = `vm`, `reason` = `boot_volume_count` \| `non_canonical_boot_volume` \| `terminating_boot_volume` \| `missing_volume_identity` \| `invalid_volume_device_name` \| `unexpected` | One workload entry could not be assembled and was omitted while the rest of the host payload continued. Alert on any increase; inspect the named VM in the paired error log and its degraded condition |
| `strato_diverged_workloads` | gauge | `kind` = `vm` \| `sandbox` | Current workloads whose acknowledged observed status has remained different from desired state for at least 15 minutes with no mutation outstanding. Recorded every sweep, including zero. **Alert on `> 0`** |

### Teardown safety & site networking

| Metric | Type | Labels | Meaning |
|--------|------|--------|---------|
| `strato_site_network_controller_up` | gauge | `site` | `1` while the site's designated network controller can author its topology, `0` once it goes stale or re-registers unable to (issue #833). **Alert on `== 0`** — the highest-value alert in this area: one node going quiet stalls *every* new networked workload in its site, and this fires before an operator sees the first refusal |
| `strato_workload_tombstones_total` | counter | `kind` | A workload an agent holds was confirmed to have no control-plane row, so its teardown was authorized by tombstone. Expected near zero — ordinary deletes keep their rows until the agent confirms absence |
| `strato_workload_teardowns_withheld_total` | counter | `reason` = `row_present_here` \| `row_on_other_agent` | An agent reported holding a workload a sync omitted while the row still exists, so teardown was refused. **Alert on it firing at all**: it means the control plane described a host incorrectly (before STR-98 the same condition destroyed the workloads instead of counting them) |
| `strato_workload_claims_held` | gauge | `agent`, `reason` | Level-triggered companion to the counter above: how many workloads an agent currently holds that the control plane refused to tear down, recorded on every report including zero. Alert on `> 0` — the counter only fires at the transition, so it goes silent across a control-plane restart while the condition persists |
| `strato_agent_teardown_refusals_total` | counter | — | An agent refused a sync's teardowns because its blast-radius guard tripped |

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
| `strato_agent_poll_total` | counter | `mode` = `conditional` \| `unconditional`, `outcome` = `served` \| `not_modified` \| `assembly_budget_exhausted` \| `park_refused` | A desired-state poll resolved. `served` is a full `200` payload; the other outcomes are conditional polls that finish with `304` |
| `strato_agent_desired_state_last_full_refetch_timestamp_seconds` | gauge | `agent` = agent name | Unix timestamp of the last full `200` payload served for a request without `If-None-Match`. Conditional requests and failed response assembly do not update it |

### Webhook delivery

The queue gauges are database snapshots. Every control-plane replica observes
the same durable outbox, so aggregate them with `max` across replicas, **never
`sum`**. The per-subscription gauge is emitted for every live subscription,
including zero, so a recovered queue does not leave a stale nonzero series.
Deleting a subscription unregisters its UUID-labelled gauge.

The counters are different: only the replica that performed the work
increments them. Sum their rates or increases across replicas. For example:

```promql
max(strato_webhook_delivery_pending)
max(strato_webhook_delivery_oldest_pending_age_seconds)
max(strato_webhook_delivery_dropped)
max by (subscription_id) (strato_webhook_delivery_subscription_pending)
sum(rate(strato_webhook_delivery_attempts_total[5m]))
sum by (result) (rate(strato_webhook_delivery_results_total[5m]))
```

Scope these queries to one deployment when a metrics backend contains several
clusters.

| Metric | Type | Labels | Meaning |
|--------|------|--------|---------|
| `strato_webhook_delivery_pending` | gauge | — | Total pending delivery rows in PostgreSQL, including scheduled retries and active claims |
| `strato_webhook_delivery_oldest_pending_age_seconds` | gauge | — | Age of the oldest pending row; records zero when the queue is empty. This is the primary delivery-latency alert signal |
| `strato_webhook_delivery_subscription_pending` | gauge | `subscription_id` | Pending rows for each subscription, including an explicit zero |
| `strato_webhook_delivery_attempts_total` | counter | — | HTTP delivery attempts started. Its summed rate measures endpoint work, not terminal queue drain: retryable failures remain pending |
| `strato_webhook_delivery_results_total` | counter | `result` = `succeeded` \| `failed` \| `dead` | Durable claimed-row verdicts. `failed` remains pending; `dead` includes exhausted attempts and rows parked because their subscription is disabled |
| `strato_webhook_delivery_dropped` | gauge | — | Committed `dropped` rows still present in the seven-day delivery history. It can fall when history is pruned or a row is manually redelivered |

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
- **Desired-state polls** — `GET /agent/desired-state` is covered by the normal
  per-request server span, including its database assembly work.
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
  `ValkeyClientConfiguration` is built in `configureValkey`. Both the
  coordination and session clients are built there, for exactly this reason:
  constructing either configuration anywhere earlier — a global, a lazy
  initializer — would leave that client spanless for the process lifetime.

Whatever tracer is installed at that moment is the one those clients use for the
life of the process. Bootstrapping afterwards left both holding the `NoOpTracer`
— both libraries were instrumented and enabled, and neither emitted a single
span. If Valkey or outbound-HTTP spans disappear from the backend while
`fluent.query` and the request spans keep arriving, suspect that something was
constructed ahead of `bootstrapObservability()`.

### Why spans nest: the task-local context, and where it breaks

Every tracer involved — our own `withSpan` call sites, FluentKit, valkey-swift,
async-http-client — finds its parent by reading the task-local
`ServiceContext.current`. Vapor's `TracingMiddleware` binds it when it opens the
server span, and it then flows down the responder chain by task inheritance.

It does not survive a future-based middleware. Vapor 4 still ships several
(`SessionsMiddleware`, `RequestAuthenticator`, `SessionAuthenticator`), and each
chains downstream from inside an `EventLoopFuture` callback:

```swift
return future.flatMap { _ in next.respond(to: request) }
```

That callback runs on the event loop, outside any Swift task, so task-local
storage is gone; the `AsyncMiddleware` bridge below it then starts a fresh
`Task` with nothing to inherit from. Until this was fixed, `ServiceContext`
read back `nil` for the entire remainder of every request — `iam.authorize`, the
rate limiter's Valkey `EVAL`, and every controller's `fluent.query` each opened
a root span in a trace of its own, which is why a dev-cluster sample found 95 of
100 traces containing a `fluent.query` rooted at `fluent.query` itself.

`ServiceContextRestoringMiddleware` closes it: `request.serviceContext` lives on
the `Request` object and is untouched by the event-loop hop, so re-binding the
task-local from it restores parenting for everything below. It is registered
right after the session authenticator, and **any future-based middleware added
after that point needs another one behind it**.

This is what the locally-observed orphan `EVAL` turned out to be — an `EVAL`
issued **inside** a `GET /api/vms` landing in its own trace. Nothing about
valkey-swift's connection pool was involved: it resolves the parent from
`ServiceContext.current` like everything else, and there was no parent to find.

Spans genuinely started outside a request still appear as roots, and should:
the agent heartbeat monitor, the audit-retention sweep, webhook delivery, and
SSF poll delivery are all timer-driven, with no enclosing span to attach to.

### Correlating traces with logs

`entrypoint.swift` bootstraps SwiftLog once with the console handler, the
optional OTLP handler, and swift-otel's logging metadata provider. Any line
logged inside a span therefore carries `trace_id`, `span_id` and `trace_flags`
in both sinks. The default console handler renders metadata as a sorted,
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

The agent does not continue a desired-state poll's HTTP trace through local
reconciliation. Doorbells forwarded over Valkey pub/sub likewise do not
propagate trace context, so the replica that wakes and answers a poll has no
trace link back to the mutation that rang it.

## Alert runbook

Thresholds are starting points; tune to your fleet size and SLOs.

### Webhook outbox is falling behind

- **Condition:** alert when
  `max(strato_webhook_delivery_oldest_pending_age_seconds)` exceeds the webhook
  delivery SLO for 5 minutes. Five minutes is a useful initial warning
  threshold; unlike `WEBHOOK_DELIVERY_INTERVAL_SECONDS`, it measures actual
  queued delay under load. Also alert when
  `max(strato_webhook_delivery_dropped) > 0`: committed delivery history shows
  that the queue reached its fixed safety ceiling and intentionally shed rows.
- **Severity:** warning when age exceeds the SLO or a drop occurs. Page if age
  and total depth keep rising for 15 minutes, or drops continue across several
  windows.
- **First checks:** compare
  `max(strato_webhook_delivery_pending)` with
  `max by (subscription_id) (strato_webhook_delivery_subscription_pending)` to
  distinguish a broad backlog from one hot subscription. Then compare the
  summed attempt rate with
  `sum by (result) (rate(strato_webhook_delivery_results_total[5m]))`.
  Rising `failed` results point to endpoint health, DNS/SSRF rejection, or
  request timeouts; those rows may be waiting in backoff for as long as one
  hour. A deep pending gauge also includes future retries and active leases, so
  a low immediate attempt rate does not by itself prove a capacity problem.
  Confirm delivery is enabled, inspect worker errors, the `next_attempt_at` and
  `claimed_until` distribution, and result rates over the full backoff window.
  Then scale control-plane replicas if due, unleased work for healthy endpoints
  still cannot keep up. Lowering the 15-second interval does not increase
  busy-drain throughput; it changes the no-work and sweep-error retry delay.

### Agent disconnected too long

- **Condition:** `strato_agent_up == 0` for more than **N minutes** (suggest
  5 min) — e.g. `min_over_time(strato_agent_up[5m]) == 0`. The `agent` label names
  the down node. Use this gauge, **not** `strato_agent_heartbeat_staleness_seconds`:
  the staleness gauge stops updating once the 60s stale sweep removes the agent
  from memory, so it never climbs to a 5-minute threshold. `strato_agent_up` keeps
  reporting `0` after the sweep, so the alert actually fires.
- **Severity:** warning at 5 min, page at 15 min (capacity loss / VMs unmanaged).
- **First checks:** is the agent process alive on the node? Network path to the
  control plane? Look at `strato_agent_registration_failures_total` (an agent
  stuck in a reconnect loop that keeps being rejected shows rising
  registration failures with the `reason` naming why).

### Desired-state full refetch is stale

- **Condition:** an online agent has not completed its unconditional
  desired-state correctness backstop for more than **600 seconds** (two default
  300-second intervals):

  ```promql
  (
    time()
    - max by (agent) (
        strato_agent_desired_state_last_full_refetch_timestamp_seconds
      )
  ) > 600
  and on (agent)
  max by (agent) (strato_agent_up) == 1
  ```

  The `max by (agent)` aggregation is intentional: different long polls can be
  served by different control-plane replicas, so the newest exported timestamp
  is authoritative. Gating on `strato_agent_up` suppresses the alert for a node
  that is already known to be disconnected.
- **Threshold:** when an agent overrides
  `desired_state_full_refetch_seconds`, set the threshold to at least twice the
  largest interval used by the agents covered by the rule (or split the rule
  by fleets with different settings).
- **Severity:** warning. Page if it persists past another interval or affects
  multiple online agents.
- **First checks:** compare
  `strato_agent_poll_total{mode="unconditional",outcome="served"}` with
  conditional poll traffic, then inspect the agent's poll/reconnect logs and
  the control plane's `GET /agent/desired-state` errors. Conditional `200`s do
  not prove this backstop is healthy.

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

### Workload remains divergent

- **Condition:** `strato_diverged_workloads > 0`. The `kind` label separates
  VMs and sandboxes; the gauge already includes the 15-minute grace window.
- **Severity:** warning for one workload; page when the count rises across many
  workloads or both kinds on one host.
- **First checks:** inspect `conditions.degraded.reason` and
  `conditions.degraded.lastErrorAt` on the workload detail response, then the
  owning agent's warning/error logs. The agent retries transient failures at
  most hourly after its first four attempts; a permanent failure instead logs
  one retry-suppression warning and needs operator repair plus a new generation.

### Registration failures spiking

- **Condition:** `increase(strato_agent_registration_failures_total[10m])`
  above a small threshold.
- **Severity:** warning. A burst of `organization_scope_mismatch` /
  `missing_organization_scope` means a node's SPIFFE identity doesn't match
  the organization it is enrolled under (an enrollment or trust-domain
  misconfiguration); `unsupported_protocol` is version skew — an agent too
  old or too new for this control plane; a burst of `register_error` points
  at a control-plane/database problem.

### Readiness probe failing

- **Condition:** `GET /health/ready` returns non-`healthy` (database check down).
- **Severity:** page — the control plane cannot serve requests reliably.
- **First checks:** database connectivity; the `identity` block in the health
  response confirms *which* instance is failing (see
  [Logging & Log Visibility](/deployment/logging)).

## Verifying locally

The compose deployment ships with OTel export disabled. To exercise metrics,
set `OTEL_METRICS_ENABLED=true` and a reachable
`OTEL_EXPORTER_OTLP_ENDPOINT` in `.env`, then:

- Create a webhook subscription and enqueue an event while delivery is stopped
  → expect `strato_webhook_delivery_pending` and the matching
  `strato_webhook_delivery_subscription_pending` series to rise. Re-enable the
  worker and expect both to return to zero while attempts/results increase.
- Kill an agent → expect `strato_agent_up{agent="…"}` to drop to `0` (and stay
  there) and a `strato_agent_disconnections_total{reason="stale"}` (or
  `connection_closed`) increment. While it's still in the 60s grace window,
  `strato_agent_heartbeat_staleness_seconds` climbs before the sweep removes it.
- With an online agent, query
  `strato_agent_desired_state_last_full_refetch_timestamp_seconds`; it should
  advance only on an unconditional poll roughly every 300 seconds by default.
  `strato_agent_poll_total` should expose `mode="conditional"` and
  `mode="unconditional"` without any ETag or agent-valued counter labels.
- Trigger a VM failure → expect `strato_vm_errors_total` to increment with the
  matching `reason`.
