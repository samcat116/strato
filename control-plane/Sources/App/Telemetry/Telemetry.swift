import Metrics

/// Central definitions for the operational metrics surfaced for production
/// observability and alerting. Routing all emission through these helpers keeps
/// metric names and label keys consistent across call sites.
///
/// These use the swift-metrics facade. When OpenTelemetry is bootstrapped
/// (`OTEL_METRICS_ENABLED=true`, see `configure.swift`) the facade is backed by
/// the OTLP exporter; otherwise swift-metrics defaults to a no-op backend and
/// every call here is a cheap no-op — so call sites need no feature gating.
///
/// See `docs/deployment/observability.md` for the alert runbook built on these.
enum Telemetry {

    // MARK: - Agent lifecycle

    /// An agent successfully (re)registered with the control plane.
    static func agentConnected() {
        Counter(label: "strato_agent_connections_total").increment()
    }

    /// An agent connection went away. `reason` distinguishes the cause:
    /// `connection_closed` (socket dropped), `unregister` (graceful shutdown),
    /// or `stale` (heartbeats stopped, swept by the monitor).
    static func agentDisconnected(reason: String) {
        Counter(label: "strato_agent_disconnections_total", dimensions: [("reason", reason)]).increment()
    }

    /// A registration attempt was rejected. `reason` is e.g. `invalid_token`,
    /// `expired_token`, or `register_error`.
    static func agentRegistrationFailed(reason: String) {
        Counter(label: "strato_agent_registration_failures_total", dimensions: [("reason", reason)]).increment()
    }

    /// Seconds since an agent's last heartbeat, recorded per agent each monitoring
    /// cycle. Alert when this climbs past the staleness threshold — a quiet agent
    /// is the early signal of a hung or partitioned hypervisor node.
    static func recordHeartbeatStaleness(agentName: String, seconds: Double) {
        Gauge(label: "strato_agent_heartbeat_staleness_seconds", dimensions: [("agent", agentName)]).record(seconds)
    }

    // MARK: - VM health

    /// A VM transitioned into the `.error` state. `reason` records which mechanism
    /// caught it: `reconciliation` (missing from an agent heartbeat),
    /// `stuck_transition` (timed out mid start/stop), or `agent_reported` (the
    /// agent pushed an error status, e.g. a failed create/boot).
    static func vmEnteredError(reason: String) {
        Counter(label: "strato_vm_errors_total", dimensions: [("reason", reason)]).increment()
    }
}
