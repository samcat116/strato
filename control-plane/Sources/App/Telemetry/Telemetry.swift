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
    /// `expired_token`, `register_error`, or `token_save_failed`.
    static func agentRegistrationFailed(reason: String) {
        Counter(label: "strato_agent_registration_failures_total", dimensions: [("reason", reason)]).increment()
    }

    /// Failed to encode or send a message to an agent over its WebSocket. `kind`
    /// distinguishes which response path failed: `message`, `success`, or `error`.
    static func agentSendFailed(kind: String) {
        Counter(label: "strato_agent_send_failures_total", dimensions: [("kind", kind)]).increment()
    }

    /// Per-agent connection state: `1` while connected, `0` once disconnected.
    /// This is the durable, alertable signal — unlike the staleness gauge it keeps
    /// reporting `0` after the stale sweep drops the agent from memory, so an alert
    /// like `strato_agent_up == 0 for 5m` actually fires, and the `agent` label
    /// identifies exactly which node is down. Set to `1` on (re)registration and
    /// `0` on every disconnect path (close / unregister / stale sweep).
    static func recordAgentUp(agentName: String, up: Bool) {
        Gauge(label: "strato_agent_up", dimensions: [("agent", agentName)]).record(up ? 1 : 0)
    }

    /// Seconds since an agent's last heartbeat, recorded per agent each monitoring
    /// cycle *while the agent is still connected*. A secondary signal for spotting
    /// heartbeats that are slowing before the 60s sweep removes the agent; once
    /// swept it stops updating, so alert on `strato_agent_up` for hard-down detection.
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

    /// A VM's observed state changed with no operation in flight (issue #260):
    /// agent reality moved out of band — a guest powered itself off, someone
    /// paused it over QMP, etc. The reconcile loop converges it back; this
    /// counter tracks how often drift happens at all.
    static func vmDriftDetected() {
        Counter(label: "strato_vm_drift_total").increment()
    }
}
