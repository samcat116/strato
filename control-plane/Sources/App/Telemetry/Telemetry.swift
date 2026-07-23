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

    // MARK: - Agent auto-update (issue #434)

    /// The rollout sweep assigned an agent its target version.
    static func agentAutoUpdateAssigned() {
        Counter(label: "strato_agent_auto_update_assignments_total").increment()
    }

    /// An assigned agent re-registered at its target version.
    static func agentAutoUpdateConverged() {
        Counter(label: "strato_agent_auto_update_converged_total").increment()
    }

    /// An assigned update failed terminally, halting the rollout. `reason`
    /// distinguishes `agent_reported` (the agent pushed the real error) from
    /// `health_budget` (the agent went silent past its budget).
    static func agentAutoUpdateFailed(reason: String) {
        Counter(label: "strato_agent_auto_update_failures_total", dimensions: [("reason", reason)]).increment()
    }

    /// An assigned agent stayed blocked past the health budget; the rollout
    /// parked it (assignment kept, advancement no longer waits on it).
    static func agentAutoUpdateParked() {
        Counter(label: "strato_agent_auto_update_parked_total").increment()
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

    // MARK: - HTTP request layer

    /// RED metrics for the whole API surface, emitted once per request by
    /// `MetricsMiddleware`. `route` is the matched route pattern (e.g.
    /// `/api/vms/:vmID`) rather than the concrete path, so cardinality stays
    /// bounded no matter how many resources exist; unmatched requests fall back
    /// to `unmatched`. `status` is bucketed by class (`2xx`, `4xx`, ...) for the
    /// counter to keep label cardinality low, while the duration timer carries
    /// only method + route.
    static func recordHTTPRequest(method: String, route: String, statusClass: String, durationSeconds: Double) {
        Counter(
            label: "strato_http_server_requests_total",
            dimensions: [("method", method), ("route", route), ("status", statusClass)]
        ).increment()
        Timer(
            label: "strato_http_server_request_duration_seconds",
            dimensions: [("method", method), ("route", route)]
        ).recordSeconds(durationSeconds)
    }

    // MARK: - Scheduler / placement

    /// A placement decision resolved. `outcome` is `success` (an agent was
    /// selected), `no_candidate` (constraints/resources left no eligible
    /// agent), or `error` (an unexpected failure). `strategy` records which
    /// selection policy ran. The companion timer captures selection latency.
    static func recordPlacement(strategy: String, outcome: String, durationSeconds: Double) {
        Counter(
            label: "strato_scheduler_placements_total",
            dimensions: [("strategy", strategy), ("outcome", outcome)]
        ).increment()
        Timer(
            label: "strato_scheduler_placement_duration_seconds",
            dimensions: [("strategy", strategy)]
        ).recordSeconds(durationSeconds)
    }

    // MARK: - Authorization (Cedar)

    /// A Cedar authorization decision was evaluated. `decision` is `allow` or
    /// `deny`; the timer records evaluation latency (entity-slice load plus
    /// policy-set evaluation). Every `IAMAuthorizer.authorize` funnels here, so
    /// this is the allow/deny rate for the entire API.
    static func recordAuthzDecision(allowed: Bool, durationSeconds: Double) {
        Counter(
            label: "strato_authz_decisions_total",
            dimensions: [("decision", allowed ? "allow" : "deny")]
        ).increment()
        Timer(label: "strato_authz_evaluation_duration_seconds").recordSeconds(durationSeconds)
    }

    // MARK: - IPAM

    /// A NIC address was allocated from a logical network's subnet. `family` is
    /// `ipv4` or `ipv6`.
    static func ipamAllocated(family: String) {
        Counter(label: "strato_ipam_allocations_total", dimensions: [("family", family)]).increment()
    }

    /// An address allocation failed. `reason` distinguishes `pool_exhausted`
    /// (no free host addresses) from configuration faults (`invalid_subnet`,
    /// `invalid_gateway`). `pool_exhausted` in particular is the alertable
    /// capacity signal.
    static func ipamAllocationFailed(family: String, reason: String) {
        Counter(
            label: "strato_ipam_allocation_failures_total",
            dimensions: [("family", family), ("reason", reason)]
        ).increment()
    }

    // MARK: - Reconciliation / desired-state sync

    /// A desired-state sync to a locally-socketed agent resolved. `outcome` is
    /// `sent` or `failed` (assembly or send threw — the periodic timer will
    /// retry). The timer captures assemble+send latency. Complements the
    /// level-triggered failure counters (`strato_vm_errors_total`,
    /// `strato_vm_drift_total`); the pushed-state size is carried on the sync
    /// span rather than a metric to avoid a misleading fleet-wide gauge.
    static func recordDesiredStateSync(outcome: String, durationSeconds: Double) {
        Counter(label: "strato_agent_sync_total", dimensions: [("outcome", outcome)]).increment()
        Timer(label: "strato_agent_sync_duration_seconds").recordSeconds(durationSeconds)
    }
}
