# Observability: Metrics & Alerts

The control plane emits OpenTelemetry metrics for the failure modes that the
2026-06-12 end-to-end test made painful to diagnose: agents silently going away,
heartbeats drying up, and VMs landing in `.error` without anyone noticing.

This page is the catalog of those metrics and the alert runbook built on them.

## Enabling metrics

Metrics flow through the swift-metrics facade, backed by the OTLP exporter when
OpenTelemetry is bootstrapped. Controlled by environment variables (see
`configure.swift`):

| Variable | Default | Notes |
|----------|---------|-------|
| `OTEL_METRICS_ENABLED` | `true` (the compose deployment sets it to `false`) | Master switch for metric export |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `localhost:4317` (gRPC) | Where to ship OTLP |
| `OTEL_SERVICE_NAME` | `strato-control-plane` | `service.name` resource attribute |

When metrics are disabled, swift-metrics uses a no-op backend — emission call
sites stay in the code but cost nothing.

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

Logs and traces stay on the OTLP path — point
`opentelemetry.collector.endpoint` (or the collector's exporters) at your
backend; only metrics need the scrape endpoint.

Setting `opentelemetry.prometheusExport.enabled: false` **and**
`opentelemetry.prometheus.enabled: false` removes the exporter, its Service and
container ports, and SPIRE's telemetry listener entirely.

::: warning networkPolicy
With `networkPolicy.enabled: true`, an external `opentelemetry.prometheus.url`
on a non-443 port needs its own rule in `networkPolicy.egress` — the chart can
only scope the built-in rule to its own Prometheus pods.
:::

## Metric catalog

All metrics are defined in one place: `control-plane/Sources/App/Telemetry/Telemetry.swift`.

| Metric | Type | Labels | Meaning |
|--------|------|--------|---------|
| `strato_agent_connections_total` | counter | — | Agent successfully (re)registered |
| `strato_agent_disconnections_total` | counter | `reason` = `connection_closed` \| `unregister` \| `stale` | Agent connection ended |
| `strato_agent_registration_failures_total` | counter | `reason` = `invalid_token` \| `expired_token` \| `register_error` | A registration attempt was rejected |
| `strato_agent_up` | gauge | `agent` = agent name | `1` while connected, `0` once disconnected. Durable per-agent up/down signal — keeps reporting `0` after the stale sweep, so it's the basis for the "agent down" alert |
| `strato_agent_heartbeat_staleness_seconds` | gauge | `agent` = agent name | Seconds since the agent's last heartbeat, recorded each ~30s cycle **while connected**. Secondary "heartbeats slowing" signal; stops updating once the agent is swept |
| `strato_vm_errors_total` | counter | `reason` = `reconciliation` \| `stuck_transition` \| `agent_reported` | A VM transitioned into `.error` |

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
