import Foundation
import Fluent
import Metrics
import SQLKit
import StratoShared
import Vapor

actor AgentMaintenanceLoop {
    let app: Application
    private let interval: Duration
    private var task: Task<Void, Never>?
    var isShutDown = false
    private var autoUpdateTargetOverride: String?

    init(app: Application, interval: Duration) {
        self.app = app
        self.interval = interval
    }

    func start() {
        guard !isShutDown, task == nil, !app.didShutdown else { return }
        startHeartbeatMonitoring()
    }

    func shutdown() async {
        isShutDown = true
        task?.cancel()
        if let task { await task.value }
        task = nil
    }

    func setAutoUpdateTargetForTesting(_ target: String?) {
        autoUpdateTargetOverride = target
    }

    var autoUpdateTarget: String? {
        autoUpdateTargetOverride
            ?? AgentVersionTarget.version(configuration: app.controlPlaneConfiguration)
    }

    // MARK: - Heartbeat Monitoring

    /// Whether the heartbeat loop is currently armed. Test seam for verifying that
    /// the shutdown hook tears it down.
    var isHeartbeatActive: Bool {
        task != nil
    }

    private func startHeartbeatMonitoring() {
        // Don't (re)arm the loop if shutdown already raced ahead of init.
        guard !isShutDown else { return }
        task = Task {
            var tick = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                    tick &+= 1

                    // Shutdown cancels mid-tick and awaits the loop; checking
                    // between steps keeps the remaining app-touching work (and
                    // shutdown's wait) as short as possible. The application
                    // check is the last line of defense for a loop that
                    // somehow outlives its app: every step below touches
                    // app.db or app storage, which is a process-killing fatal
                    // error (not a throw) after core teardown.
                    try self.checkTickPreconditions()
                    try await runTick(number: tick)
                } catch {
                    if !Task.isCancelled {
                        app.logger.error("Error in heartbeat monitoring task: \(error)")
                    }
                    // A dead application never comes back: exit rather than
                    // spin on a loop whose every step would be skipped.
                    if app.didShutdown { return }
                }
            }
        }
    }

    /// Runs one maintenance pass against one PostgreSQL-sourced instant. The
    /// database query is deliberately above every sweep so another replica's
    /// wall clock can neither fail a healthy mutation nor expire data early.
    func runTick(
        number tick: Int,
        metricsFactory: (any MetricsFactory)? = nil,
        localTime: @Sendable () -> Date = { Date() }
    ) async throws {
        let instant = try await ClusterClock.read(on: app.db, localTime: localTime)
        Telemetry.recordControlPlaneClockOffset(
            seconds: instant.localClockOffsetSeconds,
            factory: metricsFactory)
        if abs(instant.localClockOffsetSeconds) > ClusterClock.warningOffsetSeconds {
            app.logger.warning(
                "Control-plane wall clock differs from PostgreSQL",
                metadata: [
                    "offsetSeconds": .stringConvertible(instant.localClockOffsetSeconds),
                    "destructiveSweepLimitSeconds": .stringConvertible(
                        ClusterClock.destructiveSweepOffsetLimitSeconds),
                ])
        }

        await checkStaleAgents(at: instant)
        try checkTickPreconditions()
        await app.replicaBridge.verifySubscriptions()
        try checkTickPreconditions()
        await sweepStuckConvergence(at: instant)
        try checkTickPreconditions()
        await sweepSteadyStateDivergence(at: instant)
        try checkTickPreconditions()
        await sweepStrandedVolumeAttachments()
        try checkTickPreconditions()
        await sweepOrphanedTerminatingResources(at: instant)
        try checkTickPreconditions()
        await sweepExpiredSandboxes(at: instant)
        try checkTickPreconditions()
        await SnapshotRetentionSweep.run(app: app, at: instant)
        try checkTickPreconditions()

        // Prune expired idempotency keys every 120 ticks. Its predicate uses
        // PostgreSQL `now()` directly, so it needs no bound tick instant.
        if tick % 120 == 0 {
            do {
                let deleted = try await IdempotencyService.sweepExpired(on: app.db)
                if deleted > 0 {
                    app.logger.info(
                        "Idempotency retention sweep pruned expired keys",
                        metadata: ["deleted": .stringConvertible(deleted)])
                }
            } catch {
                app.logger.error("Idempotency retention sweep failed: \(error)")
            }
        }

        try checkTickPreconditions()
        await sweepAgentAutoUpdates(at: instant)
    }

    /// Throws when the current tick must stop: the task was cancelled, the
    /// service shut down, or the application itself has been torn down.
    func checkTickPreconditions() throws {
        try Task.checkCancellation()
        guard !isShutDown, !app.didShutdown else {
            throw CancellationError()
        }
    }

    /// Internal so tests can drive one monitor pass without waiting for the timer.
    func checkStaleAgents(
        at instant: ClusterInstant,
        dependencyMetricsFactory: (any MetricsFactory)? = nil
    ) async {
        // Shutdown sets this before cancelling the loop; a tick that already
        // slipped past its sleep must not start a database sweep it doesn't
        // need to finish. The app-level check is a backstop for loops armed
        // outside the lifecycle handler's reach: touching `app.db` after
        // core teardown is a process-killing fatal error, not a throw.
        guard !isShutDown, !app.didShutdown else { return }

        let now = instant.date
        let staleThreshold: TimeInterval = 60  // 60 seconds

        do {
            let onlineAgents = try await Agent.query(on: app.db)
                .filter(\.$status == .online)
                .all()

            // Export per-agent heartbeat staleness as a gauge every cycle so
            // alerting can watch an agent go quiet before the sweep removes
            // it. Every heartbeat lands in the database regardless of which
            // replica received it, so `last_heartbeat` is the cluster view.
            for agent in onlineAgents {
                guard let lastHeartbeat = agent.lastHeartbeat else { continue }
                Telemetry.recordHeartbeatStaleness(
                    agentName: agent.name,
                    seconds: now.timeIntervalSince(lastHeartbeat)
                )
            }

            // Not gated on a sweep lock even though the state is shared: the
            // offline write is idempotent, and the presence check keeps
            // replicas from disagreeing — an agent heartbeating through any
            // replica keeps a live presence key and is skipped.
            for agent in onlineAgents {
                let heartbeatAge = agent.lastHeartbeat.map { now.timeIntervalSince($0) } ?? .infinity
                // A future heartbeat was stamped by a legacy replica's local
                // clock. It is not evidence of current liveness and must fail
                // closed until a cluster-clock heartbeat replaces it.
                guard heartbeatAge < 0 || heartbeatAge > staleThreshold else { continue }

                // A live presence key means *some* replica is hearing from
                // the agent even though the row hasn't been touched — e.g. a
                // write raced this read. When the store can't answer, fall
                // back to the heartbeat-age verdict alone.
                if await app.coordination.isAgentPresent(agentKey: agent.identity.key) == true {
                    app.logger.debug(
                        "Agent heartbeat is stale in the database but presence key is live; skipping",
                        metadata: ["strato.agent.name": .string(agent.name)])
                    continue
                }

                agent.status = .offline
                Telemetry.recordDependenciesUnavailable(
                    agentName: agent.name,
                    observations: agent.dependencyObservations,
                    factory: dependencyMetricsFactory)
                try await agent.save(on: app.db)

                Telemetry.agentDisconnected(reason: "stale")
                Telemetry.recordAgentUp(agentName: agent.name, up: false)
                await WebhookEvents.emitAgentPresence(
                    agent: agent, connected: false, reason: "stale", on: app.db, logger: app.logger)
                app.logger.info(
                    "Agent heartbeat stale past threshold; marked offline",
                    metadata: ["strato.agent.name": .string(agent.name)])
                await warnIfSiteNetworkController(agent)
            }
        } catch {
            app.logger.error("Stale-agent sweep failed: \(error)")
        }
    }

    /// Warns when a stale agent owns a site's shared network topology.
    private func warnIfSiteNetworkController(_ agent: Agent) async {
        guard let agentID = agent.id else { return }
        let offlineGrace = app.controlPlaneConfiguration.double(
            .siteControllerOfflineGraceSeconds)
        do {
            let controlled = try await Site.query(on: app.db)
                .filter(\.$networkControllerAgent.$id == agentID)
                .all()
            for site in controlled {
                Telemetry.recordSiteNetworkControllerUp(site: site.name, up: false)
                app.logger.warning(
                    "Site network controller went offline; nothing authors the site's network topology until it returns",
                    metadata: [
                        "strato.agent.name": .string(agent.name),
                        "site": .string(site.name),
                        "graceSeconds": .stringConvertible(offlineGrace),
                    ])
            }
        } catch {
            app.logger.warning(
                "Failed to check whether the stale agent is a site's network controller",
                metadata: ["strato.agent.name": .string(agent.name), "error": .string("\(error)")])
        }
    }

    /// Marks overdue, unconverged resources as degraded. The claim is
    /// idempotent, so every replica may run this without a singleton lock.
    func sweepStuckConvergence(at instant: ClusterInstant) async {
        guard !isShutDown, !app.didShutdown else { return }

        let db = app.db
        do {
            try await degradeOverdue(VM.self, at: instant, on: db)
            try await degradeOverdue(Sandbox.self, at: instant, on: db)
            try await degradeOverdue(Volume.self, at: instant, on: db)
            try await degradeOverdue(VolumeSnapshot.self, at: instant, on: db)
            try await degradeOverdue(VMSnapshot.self, at: instant, on: db)
            try await degradeOverdue(SandboxSnapshot.self, at: instant, on: db)
        } catch {
            app.logger.error("Stuck-convergence sweep failed: \(error)")
        }
        await app.vmCommandExecutionService.sweepStuck(at: instant)
    }

    /// Grace before a resting desired/observed mismatch becomes divergent.
    static let steadyStateDivergenceGrace: TimeInterval = 15 * 60

    struct SteadyStateDivergenceCounts: Equatable, Sendable {
        var vms = 0
        var sandboxes = 0
        var newlyDetected = 0
    }

    /// Detect steady-state divergence for workloads with no convergence
    /// deadline. The metric is level-triggered; warning logs are edge-triggered
    /// by `divergence_detected_at`, claimed atomically so every replica may run
    /// this sweep without duplicating one episode's warning.
    @discardableResult
    func sweepSteadyStateDivergence(
        at instant: ClusterInstant
    ) async -> SteadyStateDivergenceCounts {
        guard !isShutDown, !app.didShutdown else { return SteadyStateDivergenceCounts() }
        guard let sql = app.db as? any SQLDatabase else {
            app.logger.error("Steady-state divergence sweep requires an SQL database")
            return SteadyStateDivergenceCounts()
        }

        let now = instant.date
        let cutoff = now.addingTimeInterval(-Self.steadyStateDivergenceGrace)
        do {
            let vms = try await divergentVMRows(before: cutoff, on: sql)
            let sandboxes = try await divergentSandboxRows(before: cutoff, on: sql)
            var counts = SteadyStateDivergenceCounts(vms: vms.count, sandboxes: sandboxes.count)

            Telemetry.recordDivergedWorkloads(kind: "vm", count: counts.vms)
            Telemetry.recordDivergedWorkloads(kind: "sandbox", count: counts.sandboxes)

            for row in vms where try await claimVMDivergence(row.id, at: now, before: cutoff, on: sql) {
                counts.newlyDetected += 1
                logDivergence(row, kind: "vm")
            }
            for row in sandboxes
            where try await claimSandboxDivergence(row.id, at: now, before: cutoff, on: sql) {
                counts.newlyDetected += 1
                logDivergence(row, kind: "sandbox")
            }
            return counts
        } catch {
            app.logger.error("Steady-state divergence sweep failed: \(error)")
            return SteadyStateDivergenceCounts()
        }
    }

    private struct DivergedWorkloadRow: Decodable {
        let id: UUID
        let name: String
        let desiredStatus: String
        let status: String
        let generation: Int64
        let observedGeneration: Int64
        let lastError: String?

        enum CodingKeys: String, CodingKey {
            case id, name, status, generation
            case desiredStatus = "desired_status"
            case observedGeneration = "observed_generation"
            case lastError = "last_error"
        }
    }

    private struct DivergenceClaim: Decodable { let id: UUID }

    private func divergentVMRows(
        before cutoff: Date, on sql: any SQLDatabase
    ) async throws -> [DivergedWorkloadRow] {
        try await sql.raw(
            """
            SELECT id, name, desired_status, status, generation, observed_generation, last_error
            FROM vms
            WHERE convergence_deadline IS NULL
              AND desired_status <> 'Absent'
              AND observed_generation >= generation
              AND COALESCE(status_changed_at, created_at, updated_at) <= \(bind: cutoff)
              AND NOT (
                    (desired_status = 'Running' AND status = 'Running')
                 OR (desired_status = 'Paused' AND status = 'Paused')
                 OR (desired_status = 'Shutdown' AND status IN ('Shutdown', 'Created'))
              )
            """
        ).all(decoding: DivergedWorkloadRow.self)
    }

    private func divergentSandboxRows(
        before cutoff: Date, on sql: any SQLDatabase
    ) async throws -> [DivergedWorkloadRow] {
        try await sql.raw(
            """
            SELECT id, name, desired_status, status, generation, observed_generation, last_error
            FROM sandboxes
            WHERE convergence_deadline IS NULL
              AND desired_status <> 'Absent'
              AND observed_generation >= generation
              AND COALESCE(status_changed_at, created_at, updated_at) <= \(bind: cutoff)
              AND NOT (
                    (desired_status = 'Running' AND status IN ('Running', 'Exited'))
                 OR (desired_status = 'Stopped' AND status IN ('Stopped', 'Exited'))
              )
            """
        ).all(decoding: DivergedWorkloadRow.self)
    }

    private func claimVMDivergence(
        _ id: UUID, at now: Date, before cutoff: Date, on sql: any SQLDatabase
    ) async throws -> Bool {
        let rows = try await sql.raw(
            """
            UPDATE vms SET divergence_detected_at = \(bind: now)
            WHERE id = \(bind: id)
              AND divergence_detected_at IS NULL
              AND convergence_deadline IS NULL
              AND desired_status <> 'Absent'
              AND observed_generation >= generation
              AND COALESCE(status_changed_at, created_at, updated_at) <= \(bind: cutoff)
              AND NOT (
                    (desired_status = 'Running' AND status = 'Running')
                 OR (desired_status = 'Paused' AND status = 'Paused')
                 OR (desired_status = 'Shutdown' AND status IN ('Shutdown', 'Created'))
              )
            RETURNING id
            """
        ).all(decoding: DivergenceClaim.self)
        return !rows.isEmpty
    }

    private func claimSandboxDivergence(
        _ id: UUID, at now: Date, before cutoff: Date, on sql: any SQLDatabase
    ) async throws -> Bool {
        let rows = try await sql.raw(
            """
            UPDATE sandboxes SET divergence_detected_at = \(bind: now)
            WHERE id = \(bind: id)
              AND divergence_detected_at IS NULL
              AND convergence_deadline IS NULL
              AND desired_status <> 'Absent'
              AND observed_generation >= generation
              AND COALESCE(status_changed_at, created_at, updated_at) <= \(bind: cutoff)
              AND NOT (
                    (desired_status = 'Running' AND status IN ('Running', 'Exited'))
                 OR (desired_status = 'Stopped' AND status IN ('Stopped', 'Exited'))
              )
            RETURNING id
            """
        ).all(decoding: DivergenceClaim.self)
        return !rows.isEmpty
    }

    private func logDivergence(_ row: DivergedWorkloadRow, kind: String) {
        var metadata: Logger.Metadata = [
            "kind": .string(kind),
            "workloadId": .string(row.id.uuidString),
            "name": .string(row.name),
            "desiredStatus": .string(row.desiredStatus),
            "observedStatus": .string(row.status),
            "generation": .stringConvertible(row.generation),
            "observedGeneration": .stringConvertible(row.observedGeneration),
        ]
        if let lastError = row.lastError { metadata["lastError"] = .string(lastError) }
        app.logger.warning(
            "Workload remains divergent with no mutation outstanding",
            metadata: metadata)
    }

    private func degradeOverdue<R: ConvergingResource>(
        _ type: R.Type, at instant: ClusterInstant, on db: any Database
    ) async throws {
        let overdue = try await R.overdueForConvergence(at: instant, on: db)

        for resource in overdue {
            guard let id = resource.id else { continue }
            // The mutation kind is read for one thing — whether a never-settled
            // `create` should escalate to `.error` — and comes from the audit
            // trail rather than a column on the resource, so overlapping
            // mutations cannot make it disagree with what was actually asked
            // for. A resource with no recorded mutation predates the trail;
            // `.boot` is the conservative stand-in, since it resolves nothing
            // a create would not.
            let mutation =
                try await ResourceEvent.latest(
                    .requested, resourceKind: R.operationResourceKind, resourceID: id, on: db
                )?.mutation ?? .boot

            let timeoutReason =
                "Timed out: the agent did not converge to generation "
                + "\(resource.generation) before the deadline"
            let outcome = try await ResourceConvergence.recordExpiredDeadline(
                resource, mutation: mutation,
                at: instant, timeoutReason: timeoutReason, on: db)
            if case .superseded(let actualGeneration) = outcome {
                Telemetry.desiredStateWriteConflict(
                    resourceKind: R.operationResourceKind.rawValue, writer: "stuck_convergence")
                app.logger.warning(
                    "Dropped a convergence timeout after newer desired state superseded it",
                    metadata: [
                        "resourceKind": .string(R.operationResourceKind.rawValue),
                        "resourceId": .string(id.uuidString),
                        "actualGeneration": .stringConvertible(actualGeneration),
                    ])
            }
            guard outcome == .recorded else { continue }

            app.logger.warning(
                "Resource did not converge before its deadline; marked degraded",
                metadata: [
                    "resourceKind": .string(R.operationResourceKind.rawValue),
                    "resourceId": .string(id.uuidString),
                    "mutation": .string(mutation.rawValue),
                    "targetGeneration": .stringConvertible(resource.generation),
                    "observedGeneration": .stringConvertible(resource.observedGeneration),
                ])
        }
    }

    /// Releases volumes left holding an attachment to a VM that no longer
    /// exists (STR-129).
    ///
    /// This was the third and last half of the stuck-operation sweep, and the
    /// only one that never had anything to do with operations. The other two —
    /// failing rows past their per-kind budget, and marking transitional VMs
    /// and sandboxes `.error` — went with the table in STR-152: a mutation's
    /// deadline and the resource's own `conditions.degraded` say both things
    /// now, and `sweepStuckConvergence` writes them without a cluster lock.
    ///
    /// The VM reap releases volumes inside the delete transaction, so this
    /// should never fire — it is the backstop for a replica still running an
    /// older build during a rolling upgrade, and for any future path that
    /// removes a VM without going through the reap.
    ///
    /// No age budget, unlike the convergence sweep: nothing is in flight that
    /// could still land, and until the columns are cleared the volume names a
    /// device on a VM that does not exist. The generation bump is what makes
    /// the agent act on it — a desired entry no newer than the last one applied
    /// is dropped, so clearing the columns alone would leave the disk plugged
    /// into a guest the control plane no longer describes.
    ///
    /// Internal rather than private so tests can drive a pass directly.
}
