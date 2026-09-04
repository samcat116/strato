import Foundation
import Metrics
import StratoShared

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

    /// Bounded durable outcomes from processing a claimed delivery. A retryable
    /// endpoint or transport failure is `failed`; `dead` means either the final
    /// attempt failed or the subscription was disabled before a POST began.
    enum WebhookDeliveryResult: String, CaseIterable, Sendable {
        case succeeded
        case failed
        case dead
    }

    // MARK: - PostgreSQL advisory locks (STR-275)

    /// One successful lock acquisition and the time spent waiting for it.
    /// Namespace is the only dimension: resource identifiers would create an
    /// unbounded time series at exactly the fleet sizes this signal diagnoses.
    static func advisoryLockAcquired(
        namespace: AdvisoryLockNamespace,
        waitSeconds: Double,
        factory: (any MetricsFactory)? = nil
    ) {
        let dimensions = [("namespace", namespace.name)]
        if let factory {
            Counter(
                label: "strato_advisory_lock_acquisitions_total",
                dimensions: dimensions,
                factory: factory
            ).increment()
            Timer(
                label: "strato_advisory_lock_wait_duration_seconds",
                dimensions: dimensions,
                factory: factory
            ).recordSeconds(waitSeconds)
        } else {
            Counter(
                label: "strato_advisory_lock_acquisitions_total",
                dimensions: dimensions
            ).increment()
            Timer(
                label: "strato_advisory_lock_wait_duration_seconds",
                dimensions: dimensions
            ).recordSeconds(waitSeconds)
        }
    }

    /// A session lock could not be confirmed released. This is a counter, not
    /// a gauge: the paired critical log carries the object id/digest needed to
    /// investigate without putting either into metric labels.
    static func advisoryLockReleaseFailed(
        namespace: AdvisoryLockNamespace,
        factory: (any MetricsFactory)? = nil
    ) {
        let dimensions = [("namespace", namespace.name)]
        if let factory {
            Counter(
                label: "strato_advisory_lock_release_failures_total",
                dimensions: dimensions,
                factory: factory
            ).increment()
        } else {
            Counter(
                label: "strato_advisory_lock_release_failures_total",
                dimensions: dimensions
            ).increment()
        }
    }

    /// The two request shapes the desired-state endpoint accepts. Keeping the
    /// metric dimension typed prevents validators or other request data from
    /// becoming labels and bounds the series to these two values.
    enum DesiredStatePollMode: String, CaseIterable, Sendable {
        case conditional
        case unconditional

        static func from(ifNoneMatch: String?) -> Self {
            ifNoneMatch == nil ? .unconditional : .conditional
        }
    }

    /// Retire the UUID-labelled gauge when its subscription is deleted. The
    /// OpenTelemetry backend retains attribute sets until `destroy()` is called;
    /// explicitly unregistering prevents unbounded cardinality and a phantom
    /// last non-zero value after the row is cascade-deleted.
    static func removeWebhookDeliverySubscriptionQueueMetric(
        subscriptionID: UUID,
        factory: (any MetricsFactory)? = nil
    ) {
        let dimensions = [("subscription_id", subscriptionID.uuidString)]
        let gauge =
            if let factory {
                Gauge(
                    label: "strato_webhook_delivery_subscription_pending",
                    dimensions: dimensions,
                    factory: factory)
            } else {
                Gauge(
                    label: "strato_webhook_delivery_subscription_pending",
                    dimensions: dimensions)
            }
        gauge.record(0)
        gauge.destroy()
    }

    /// Bounded outcomes emitted by the desired-state endpoint.
    enum DesiredStatePollOutcome: String, CaseIterable, Sendable {
        case served
        case notModified = "not_modified"
        case assemblyBudgetExhausted = "assembly_budget_exhausted"
        case parkRefused = "park_refused"
    }

    // MARK: - Desired-state ordering (STR-125)

    /// A background writer reached a resource after another desired-state
    /// mutation had already advanced it. The guarded writer drops or re-decides
    /// that stale work instead of overwriting the newer intent.
    static func desiredStateWriteConflict(resourceKind: String, writer: String) {
        Counter(
            label: "strato_desired_state_write_conflicts_total",
            dimensions: [("resource_kind", resourceKind), ("writer", writer)]
        ).increment()
    }

    // MARK: - Webhook delivery (STR-264)

    /// Record one cluster-wide snapshot of the durable webhook outbox.
    ///
    /// `subscriptionIDs` must contain every live subscription, including those
    /// with no pending rows. Missing entries in `pendingBySubscription` are
    /// recorded as zero so a recovered subscription's gauge does not retain its
    /// previous backlog forever. Counts supplied for a subscription absent from
    /// `subscriptionIDs` are still recorded, which keeps the snapshot useful if
    /// a subscription is deleted concurrently with the database query.
    ///
    /// Every replica observes the same PostgreSQL queue. Dashboards therefore
    /// aggregate these gauges with `max`, not `sum`, across replica instances.
    static func recordWebhookDeliveryQueue(
        pendingCount: Int,
        oldestPendingAgeSeconds: Double?,
        droppedCount: Int,
        subscriptionIDs: [UUID],
        pendingBySubscription: [UUID: Int],
        factory: (any MetricsFactory)? = nil
    ) {
        recordGauge(
            label: "strato_webhook_delivery_pending",
            value: Double(max(pendingCount, 0)),
            factory: factory)
        recordGauge(
            label: "strato_webhook_delivery_oldest_pending_age_seconds",
            value: max(oldestPendingAgeSeconds ?? 0, 0),
            factory: factory)
        // This is derived from committed, retained `dropped` rows rather than
        // incremented in the admission transaction. It therefore cannot claim
        // a drop that later rolls back.
        recordGauge(
            label: "strato_webhook_delivery_dropped",
            value: Double(max(droppedCount, 0)),
            factory: factory)

        let observedSubscriptionIDs = Set(subscriptionIDs).union(pendingBySubscription.keys)
        for subscriptionID in observedSubscriptionIDs.sorted(by: {
            $0.uuidString < $1.uuidString
        }) {
            recordGauge(
                label: "strato_webhook_delivery_subscription_pending",
                dimensions: [("subscription_id", subscriptionID.uuidString)],
                value: Double(max(pendingBySubscription[subscriptionID] ?? 0, 0)),
                factory: factory)
        }
    }

    /// Count HTTP delivery attempts. Callers may aggregate a pass and increment
    /// once; retryable failures remain queued, so this is endpoint work rate
    /// rather than terminal queue drain.
    static func webhookDeliveryAttempted(
        count: Int = 1,
        factory: (any MetricsFactory)? = nil
    ) {
        incrementCounter(
            label: "strato_webhook_delivery_attempts_total",
            count: count,
            factory: factory)
    }

    /// Count the mutually-exclusive durable result of processing a claimed row.
    /// `dead` includes both an exhausted HTTP attempt and a row parked because
    /// its subscription was disabled; use the separate attempt counter for the
    /// actual HTTP request rate.
    static func webhookDeliveryFinished(
        result: WebhookDeliveryResult,
        count: Int = 1,
        factory: (any MetricsFactory)? = nil
    ) {
        incrementCounter(
            label: "strato_webhook_delivery_results_total",
            dimensions: [("result", result.rawValue)],
            count: count,
            factory: factory)
    }

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

    /// A registration attempt was rejected. `reason` is e.g. `register_error`,
    /// `unsupported_protocol`, `organization_scope_mismatch`,
    /// `missing_organization_scope`, or `same_named_networks_unsupported`.
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

    /// Latest feature dependency state. Counters are reported as gauges because
    /// the agent owns their monotonicity across control-plane replicas.
    static func recordDependency(
        agentName: String,
        observation: NodeDependencyObservation,
        receivedAt: Date,
        factory: (any MetricsFactory)? = nil
    ) {
        let dimensions = [("agent", agentName), ("dependency", observation.id.rawValue)]
        let available = observation.allowsNewWork(
            receivedAt: receivedAt,
            at: Date(),
            staleAfter: Agent.dependencyObservationStaleAfter)
        recordDependencyAvailability(
            dimensions: dimensions, available: available, factory: factory)
        Gauge(label: "strato_agent_dependency_consecutive_failures", dimensions: dimensions)
            .record(Int64(observation.consecutiveFailures))
        Gauge(label: "strato_agent_dependency_remediation_count", dimensions: dimensions)
            .record(Int64(observation.remediationCount))
        Gauge(label: "strato_agent_dependency_restart_count", dimensions: dimensions)
            .record(Int64(observation.restartCount))
    }

    /// Clear every dependency availability series when an agent goes offline.
    /// A gauge otherwise retains its last healthy value forever because no
    /// further heartbeat will arrive to update it.
    static func recordDependenciesUnavailable(
        agentName: String,
        observations: [NodeDependencyObservation],
        factory: (any MetricsFactory)? = nil
    ) {
        for observation in observations {
            recordDependencyAvailability(
                dimensions: [("agent", agentName), ("dependency", observation.id.rawValue)],
                available: false,
                factory: factory)
        }
    }

    /// Clear availability series that disappeared from a successful
    /// re-registration before the previous snapshot is discarded.
    static func recordRemovedDependenciesUnavailable(
        agentName: String,
        previousObservations: [NodeDependencyObservation],
        currentObservations: [NodeDependencyObservation],
        factory: (any MetricsFactory)? = nil
    ) {
        let currentIDs = Set(currentObservations.map { $0.id.rawValue })
        recordDependenciesUnavailable(
            agentName: agentName,
            observations: previousObservations.filter { !currentIDs.contains($0.id.rawValue) },
            factory: factory)
    }

    private static func recordDependencyAvailability(
        dimensions: [(String, String)],
        available: Bool,
        factory: (any MetricsFactory)?
    ) {
        let gauge =
            if let factory {
                Gauge(
                    label: "strato_agent_dependency_available",
                    dimensions: dimensions,
                    factory: factory)
            } else {
                Gauge(label: "strato_agent_dependency_available", dimensions: dimensions)
            }
        gauge.record(available ? 1 : 0)
    }

    /// Whether a site's designated network controller can author its topology:
    /// `1` while it can, `0` once it goes stale or re-registers unable to
    /// (issue #833). The highest-value alert in this area — one node going
    /// quiet stalls *every* new networked workload in its site, and this fires
    /// before an operator sees the first refusal. Alert on
    /// `strato_site_network_controller_up == 0`.
    static func recordSiteNetworkControllerUp(site: String, up: Bool) {
        Gauge(label: "strato_site_network_controller_up", dimensions: [("site", site)]).record(up ? 1 : 0)
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
    /// `convergence_failed` (the agent reported a failure at the current
    /// generation), `stuck_convergence` (the convergence deadline passed
    /// unconverged), or `mutation_failed` (the accept path's background dispatch
    /// threw). `stuck_transition` and `stuck_operation` went with the
    /// stuck-operation sweep in STR-152.
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

    /// A single workload could not be projected into an agent's desired-state
    /// payload. Both dimensions are bounded enums owned by the assembler; no
    /// workload ids or exception messages enter metric labels.
    static func desiredStateAssemblyFailed(
        kind: String, reason: String, factory: (any MetricsFactory)? = nil
    ) {
        let dimensions = [("kind", kind), ("reason", reason)]
        if let factory {
            Counter(
                label: "strato_desired_state_assembly_failures_total",
                dimensions: dimensions,
                factory: factory
            ).increment()
        } else {
            Counter(
                label: "strato_desired_state_assembly_failures_total",
                dimensions: dimensions
            ).increment()
        }
    }

    /// Workloads whose observed state has remained different from desired
    /// state past the steady-state grace window. Recorded for both bounded
    /// kinds on every sweep, including zero, so recovered series do not stick.
    static func recordDivergedWorkloads(kind: String, count: Int) {
        Gauge(label: "strato_diverged_workloads", dimensions: [("kind", kind)]).record(count)
    }

    /// Stored secrets the configured primary/previous keyring cannot open.
    /// This is level-triggered and records zero at every startup so a repaired
    /// rotation clears the prior series. `table` is one of four fixed columns.
    static func recordUnopenableStoredSecrets(table: String, count: Int) {
        Gauge(
            label: "strato_secrets_encryption_unopenable",
            dimensions: [("table", table)]
        ).record(count)
    }

    // MARK: - Teardown safety (STR-98)

    /// A workload an agent holds was confirmed to have no control-plane row,
    /// so its teardown was authorized by tombstone. Expected to be near zero:
    /// ordinary deletes never come through here, because their rows survive
    /// until the agent confirms absence.
    static func workloadTombstoned(kind: String) {
        Counter(label: "strato_workload_tombstones_total", dimensions: [("kind", kind)]).increment()
    }

    /// An agent reported holding a workload that a sync omitted, and the row
    /// still exists — so teardown was refused. `reason` is
    /// `row_present_here` (the sync under-listed an agent's own workloads: an
    /// assembly or scoping bug) or `row_on_other_agent` (the node is running
    /// workloads still placed on a superseded agent record).
    ///
    /// This counter firing at all means the control plane described a host
    /// incorrectly. Alert on it: before STR-98 the same condition destroyed
    /// the workloads instead of counting them.
    static func workloadTeardownWithheld(reason: String) {
        Counter(label: "strato_workload_teardowns_withheld_total", dimensions: [("reason", reason)])
            .increment()
    }

    /// How many workloads an agent is currently holding that the control plane
    /// refused to authorize tearing down, by reason. Recorded on every report,
    /// including zero.
    ///
    /// The counter above only fires at the transition, so it answers "did this
    /// start happening" and nothing else: a control plane restarted while the
    /// condition persists emits nothing at all, and an operator who wasn't
    /// watching that minute has no signal. This is the level-triggered half —
    /// alert on it being above zero, not on the counter's rate.
    static func workloadClaimsHeld(agentName: String, reason: String, count: Int) {
        Gauge(
            label: "strato_workload_claims_held",
            dimensions: [("agent", agentName), ("reason", reason)]
        ).record(count)
    }

    /// An agent refused a sync's teardowns because the blast-radius guard
    /// tripped.
    static func agentTeardownRefused() {
        Counter(label: "strato_agent_teardown_refusals_total").increment()
    }

    /// Whether an agent can currently enumerate its own workloads (STR-138).
    /// A gauge rather than a counter for the same reason as
    /// `workloadClaimsHeld`: a blind host is a standing condition — it
    /// advertises no capacity and converges nothing for as long as it lasts —
    /// so the alert is "above zero", not a rate.
    static func agentManifestUnreadable(agentName: String, unreadable: Bool) {
        Gauge(
            label: "strato_agent_manifest_unreadable",
            dimensions: [("agent", agentName)]
        ).record(unreadable ? 1 : 0)
    }

    // MARK: - HTTP request layer

    /// RED metrics for the whole API surface, emitted once per request by
    /// `MetricsMiddleware`. `route` is the matched route pattern (e.g.
    /// `/api/vms/:vmID`) rather than the concrete path, so cardinality stays
    /// bounded no matter how many resources exist; unmatched requests fall back
    /// to `unmatched`. `status` is bucketed by class (`2xx`, `4xx`, ...) for the
    /// counter to keep label cardinality low, while the duration timer carries
    /// only method + route.
    /// Label of the RED duration histogram. Named here because the histogram's
    /// bucket bounds are configured by label at OTel bootstrap
    /// (`ObservabilityBootstrap`) — sharing the constant keeps the override
    /// pinned to the instrument it widens.
    static let httpRequestDurationMetric = "strato_http_server_request_duration_seconds"

    static func recordHTTPRequest(method: String, route: String, statusClass: String, durationSeconds: Double) {
        Counter(
            label: "strato_http_server_requests_total",
            dimensions: [("method", method), ("route", route), ("status", statusClass)]
        ).increment()
        Timer(
            label: Telemetry.httpRequestDurationMetric,
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

    /// Number of canonical MAC addresses currently assigned to more than one
    /// VM or sandbox interface. Recorded by the startup audit; zero is healthy.
    static func recordDuplicateMACAddressGroups(_ count: Int) {
        Gauge(label: "strato_network_interface_duplicate_mac_addresses").record(Double(count))
    }

    // MARK: - Desired-state polling

    /// A desired-state long-poll resolved (STR-146). Both dimensions are typed
    /// finite sets; no ETag, agent identity, or response detail can create an
    /// unbounded counter series.
    ///
    /// The ratio is the health signal for the pull transport: a fleet that is
    /// converged should sit almost entirely on `not_modified`, so a sustained
    /// `served` rate with no mutation traffic means the digest is churning —
    /// some per-assembly value escaped `DesiredStateDigest.volatilePaths` and
    /// every agent is refetching its full state on every poll.
    static func recordDesiredStatePoll(mode: DesiredStatePollMode, outcome: DesiredStatePollOutcome) {
        Counter(
            label: "strato_agent_poll_total",
            dimensions: [("mode", mode.rawValue), ("outcome", outcome.rawValue)]
        ).increment()
    }

    /// Unix timestamp of the last full payload served to an agent in response
    /// to a request without `If-None-Match`. Conditional `200`s deliberately
    /// do not update it: they prove the latency path works, not the periodic
    /// correctness backstop. Called only after the full response is encoded.
    static func recordDesiredStateFullRefetch(agentName: String, at date: Date = Date()) {
        Gauge(
            label: "strato_agent_desired_state_last_full_refetch_timestamp_seconds",
            dimensions: [("agent", agentName)]
        ).record(date.timeIntervalSince1970)
    }

    // MARK: - Resource pressure and contention (STR-266)

    /// Publish a host snapshot as remote gauges. Kernel counters are gauges
    /// here because monotonicity belongs to the agent/host and may reset when
    /// either restarts. `agent_id` is a control-plane-issued UUID; signal,
    /// resource, stall, and event are closed vocabularies.
    static func recordHostResourceTelemetry(
        agentID: String,
        telemetry: HostResourceTelemetry,
        factory: (any MetricsFactory)? = nil
    ) {
        let base = [("agent_id", agentID)]
        recordGauge(
            label: "strato_agent_resource_health",
            dimensions: base,
            value: telemetry.health.metricValue,
            factory: factory)
        recordPressure(
            prefix: "strato_agent", base: base, resource: "cpu",
            pressure: telemetry.cpuPressure, factory: factory)
        recordPressure(
            prefix: "strato_agent", base: base, resource: "memory",
            pressure: telemetry.memoryPressure, factory: factory)
        recordPressure(
            prefix: "strato_agent", base: base, resource: "io",
            pressure: telemetry.ioPressure, factory: factory)

        for (signal, label, value) in [
            ("swap_total_bytes", "strato_agent_swap_total_bytes", telemetry.swapTotalBytes),
            ("swap_used_bytes", "strato_agent_swap_used_bytes", telemetry.swapUsedBytes),
            ("zswap_stored_bytes", "strato_agent_zswap_stored_bytes", telemetry.zswapStoredBytes),
            ("zswap_pool_bytes", "strato_agent_zswap_pool_bytes", telemetry.zswapPoolBytes),
            ("zram_used_bytes", "strato_agent_zram_used_bytes", telemetry.zramUsedBytes),
            ("major_faults_total", "strato_agent_major_faults_total", telemetry.majorFaultsTotal),
            (
                "reclaim_scanned_pages_total", "strato_agent_reclaim_scanned_pages_total",
                telemetry.reclaimScannedPagesTotal
            ),
            (
                "reclaim_reclaimed_pages_total", "strato_agent_reclaim_reclaimed_pages_total",
                telemetry.reclaimReclaimedPagesTotal
            ),
            ("oom_kills_total", "strato_agent_oom_kills_total", telemetry.oomKillsTotal),
        ] {
            recordRemoteValue(
                prefix: "strato_agent", base: base, signal: signal,
                label: label, value: value, factory: factory)
        }
        let mglru = telemetry.mglruEnabled
        recordRemoteValue(
            prefix: "strato_agent", base: base, signal: "mglru_enabled",
            label: "strato_agent_mglru_enabled",
            value: ResourceTelemetryValue(
                availability: mglru.availability,
                value: mglru.value.map { $0 ? 1 : 0 }),
            factory: factory)
    }

    /// Publish one workload snapshot and the existing QEMU balloon values.
    /// Only server-issued agent/workload UUIDs and bounded enums become labels;
    /// names, projects, tenants, tags, errors, and cgroup paths never do.
    static func recordWorkloadResourceTelemetry(
        agentID: String,
        workloadID: String,
        kind: WorkloadKind,
        telemetry: WorkloadResourceTelemetry?,
        balloon: VMMemoryStats? = nil,
        factory: (any MetricsFactory)? = nil
    ) {
        let base = [
            ("agent_id", agentID),
            ("workload_id", workloadID),
            ("kind", kind.rawValue),
        ]

        if let telemetry {
            recordGauge(
                label: "strato_workload_resource_health", dimensions: base,
                value: telemetry.health.metricValue, factory: factory)
            recordAvailability(
                prefix: "strato_workload", base: base, signal: "cgroup_v2",
                available: telemetry.cgroupV2 == .available, factory: factory)
            recordPressure(
                prefix: "strato_workload", base: base, resource: "cpu",
                pressure: telemetry.cpuPressure, factory: factory)
            recordPressure(
                prefix: "strato_workload", base: base, resource: "memory",
                pressure: telemetry.memoryPressure, factory: factory)
            recordPressure(
                prefix: "strato_workload", base: base, resource: "io",
                pressure: telemetry.ioPressure, factory: factory)

            for (signal, label, value, scale) in [
                (
                    "memory_current_bytes", "strato_workload_memory_current_bytes",
                    telemetry.memoryCurrentBytes, 1.0
                ),
                (
                    "cpu_usage_microseconds_total", "strato_workload_cpu_usage_seconds_total",
                    telemetry.cpuUsageMicroseconds, 0.000_001
                ),
                (
                    "cpu_throttled_microseconds_total", "strato_workload_cpu_throttled_seconds_total",
                    telemetry.cpuThrottledMicroseconds, 0.000_001
                ),
                (
                    "cpu_throttled_periods_total", "strato_workload_cpu_throttled_periods_total",
                    telemetry.cpuThrottledPeriodsTotal, 1.0
                ),
                (
                    "guest_steal_microseconds_total", "strato_workload_guest_steal_seconds_total",
                    telemetry.guestStealMicroseconds, 0.000_001
                ),
            ] {
                recordRemoteValue(
                    prefix: "strato_workload", base: base, signal: signal,
                    label: label, value: value, scale: scale, factory: factory)
            }

            let events = telemetry.memoryEvents
            for (event, value) in [
                ("low", events.low), ("high", events.high), ("max", events.max),
                ("oom", events.oom), ("oom_kill", events.oomKill),
                ("oom_group_kill", events.oomGroupKill),
            ] {
                let signal = "memory_events_\(event)"
                recordRemoteValue(
                    prefix: "strato_workload", base: base, signal: signal,
                    label: "strato_workload_memory_events_total",
                    value: ResourceTelemetryValue(
                        availability: events.availability,
                        value: value),
                    extraDimensions: [("event", event)],
                    factory: factory)
            }
        } else {
            destroyGauge(
                label: "strato_workload_resource_health",
                dimensions: base, factory: factory)
            recordAvailability(
                prefix: "strato_workload", base: base, signal: "cgroup_v2",
                available: false, factory: factory)
            for resource in ["cpu", "memory", "io"] {
                recordPressure(
                    prefix: "strato_workload", base: base, resource: resource,
                    pressure: .unavailable, factory: factory)
            }
            for (signal, label) in [
                ("memory_current_bytes", "strato_workload_memory_current_bytes"),
                ("cpu_usage_microseconds_total", "strato_workload_cpu_usage_seconds_total"),
                (
                    "cpu_throttled_microseconds_total",
                    "strato_workload_cpu_throttled_seconds_total"
                ),
                (
                    "cpu_throttled_periods_total",
                    "strato_workload_cpu_throttled_periods_total"
                ),
                (
                    "guest_steal_microseconds_total",
                    "strato_workload_guest_steal_seconds_total"
                ),
            ] {
                recordRemoteValue(
                    prefix: "strato_workload", base: base, signal: signal,
                    label: label, value: .unavailable, factory: factory)
            }
            for event in ["low", "high", "max", "oom", "oom_kill", "oom_group_kill"] {
                recordRemoteValue(
                    prefix: "strato_workload", base: base,
                    signal: "memory_events_\(event)",
                    label: "strato_workload_memory_events_total",
                    value: .unavailable,
                    extraDimensions: [("event", event)],
                    factory: factory)
            }
        }

        for (signal, label, value) in [
            (
                "balloon_total_bytes", "strato_workload_balloon_total_bytes",
                balloon.map { ResourceTelemetryValue.available($0.totalBytes) } ?? .unavailable
            ),
            (
                "balloon_available_bytes", "strato_workload_balloon_available_bytes",
                balloon.map { ResourceTelemetryValue.available($0.availableBytes) } ?? .unavailable
            ),
            (
                "balloon_actual_bytes", "strato_workload_balloon_actual_bytes",
                balloon.flatMap(\.balloonActualBytes).map(ResourceTelemetryValue.available)
                    ?? .unavailable
            ),
        ] {
            recordRemoteValue(
                prefix: "strato_workload", base: base, signal: signal,
                label: label, value: value, factory: factory)
        }
    }

    /// Remove every series belonging to a finalized workload. UUID identity is
    /// required for attribution while a workload exists, but finalized UUIDs
    /// must not accumulate forever in a long-lived collector process.
    static func removeWorkloadResourceTelemetry(
        agentID: String,
        workloadID: String,
        kind: WorkloadKind,
        factory: (any MetricsFactory)? = nil
    ) {
        let base = [
            ("agent_id", agentID),
            ("workload_id", workloadID),
            ("kind", kind.rawValue),
        ]
        recordWorkloadResourceTelemetry(
            agentID: agentID, workloadID: workloadID, kind: kind,
            telemetry: nil, balloon: nil, factory: factory)

        let availabilitySignals = [
            "cgroup_v2",
            "psi_cpu_some", "psi_cpu_full",
            "psi_memory_some", "psi_memory_full",
            "psi_io_some", "psi_io_full",
            "memory_current_bytes",
            "cpu_usage_microseconds_total",
            "cpu_throttled_microseconds_total",
            "cpu_throttled_periods_total",
            "guest_steal_microseconds_total",
            "memory_events_low", "memory_events_high", "memory_events_max",
            "memory_events_oom", "memory_events_oom_kill", "memory_events_oom_group_kill",
            "balloon_total_bytes", "balloon_available_bytes", "balloon_actual_bytes",
        ]
        for signal in availabilitySignals {
            destroyGauge(
                label: "strato_workload_resource_signal_available",
                dimensions: base + [("signal", signal)],
                factory: factory)
        }
    }

    private static func recordPressure(
        prefix: String,
        base: [(String, String)],
        resource: String,
        pressure: PressureStallTelemetry,
        factory: (any MetricsFactory)?
    ) {
        for (stall, sample) in [("some", pressure.some), ("full", pressure.full)] {
            let dimensions = base + [("resource", resource), ("stall", stall)]
            let available = pressure.availability == .available && sample != nil
            recordAvailability(
                prefix: prefix, base: base,
                signal: "psi_\(resource)_\(stall)", available: available,
                factory: factory)
            guard let sample, available else {
                destroyGauge(
                    label: "\(prefix)_pressure_average10_percent",
                    dimensions: dimensions, factory: factory)
                destroyGauge(
                    label: "\(prefix)_pressure_total_seconds",
                    dimensions: dimensions, factory: factory)
                continue
            }
            recordGauge(
                label: "\(prefix)_pressure_average10_percent",
                dimensions: dimensions, value: sample.average10, factory: factory)
            recordGauge(
                label: "\(prefix)_pressure_total_seconds",
                dimensions: dimensions,
                value: Double(sample.totalMicroseconds) / 1_000_000,
                factory: factory)
        }
    }

    private static func recordRemoteValue(
        prefix: String,
        base: [(String, String)],
        signal: String,
        label: String,
        value: ResourceTelemetryValue,
        extraDimensions: [(String, String)] = [],
        scale: Double = 1,
        factory: (any MetricsFactory)?
    ) {
        let available = value.availability == .available && value.value != nil
        recordAvailability(
            prefix: prefix, base: base, signal: signal,
            available: available, factory: factory)
        let dimensions = base + extraDimensions
        guard let raw = value.value, available else {
            destroyGauge(label: label, dimensions: dimensions, factory: factory)
            return
        }
        recordGauge(
            label: label, dimensions: dimensions,
            value: Double(raw) * scale, factory: factory)
    }

    private static func recordAvailability(
        prefix: String,
        base: [(String, String)],
        signal: String,
        available: Bool,
        factory: (any MetricsFactory)?
    ) {
        recordGauge(
            label: "\(prefix)_resource_signal_available",
            dimensions: base + [("signal", signal)],
            value: available ? 1 : 0,
            factory: factory)
    }

    private static func destroyGauge(
        label: String,
        dimensions: [(String, String)],
        factory: (any MetricsFactory)?
    ) {
        let gauge =
            if let factory {
                Gauge(label: label, dimensions: dimensions, factory: factory)
            } else {
                Gauge(label: label, dimensions: dimensions)
            }
        gauge.destroy()
    }

    static func recordGuestIdentityMint(outcome: String) {
        Counter(
            label: "strato_guest_identity_mints_total",
            dimensions: [("outcome", outcome)]
        ).increment()
    }

    // MARK: - Metric construction

    private static func recordGauge(
        label: String,
        dimensions: [(String, String)] = [],
        value: Double,
        factory: (any MetricsFactory)?
    ) {
        let gauge =
            if let factory {
                Gauge(label: label, dimensions: dimensions, factory: factory)
            } else {
                Gauge(label: label, dimensions: dimensions)
            }
        gauge.record(value)
    }

    private static func incrementCounter(
        label: String,
        dimensions: [(String, String)] = [],
        count: Int,
        factory: (any MetricsFactory)?
    ) {
        guard count > 0 else { return }
        let counter =
            if let factory {
                Counter(label: label, dimensions: dimensions, factory: factory)
            } else {
                Counter(label: label, dimensions: dimensions)
            }
        counter.increment(by: Int64(count))
    }
}

private extension ResourcePressureHealth {
    var metricValue: Double {
        switch self {
        case .unknown: 0
        case .healthy: 1
        case .pressured: 2
        case .critical: 3
        }
    }
}
