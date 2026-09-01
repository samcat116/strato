import Foundation
import Fluent
import Metrics
import SQLKit
import StratoShared
import Vapor

actor AgentMaintenanceLoop {
    private let app: Application
    private let interval: Duration
    private var task: Task<Void, Never>?
    private var isShutDown = false
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

    private var autoUpdateTarget: String? {
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

                    await checkStaleAgents()

                    try self.checkTickPreconditions()

                    await app.replicaBridge.verifySubscriptions()

                    try self.checkTickPreconditions()

                    await sweepStuckConvergence()

                    try self.checkTickPreconditions()

                    await sweepSteadyStateDivergence()

                    try self.checkTickPreconditions()

                    await sweepStrandedVolumeAttachments()

                    try self.checkTickPreconditions()

                    await sweepOrphanedTerminatingResources()

                    try self.checkTickPreconditions()

                    await sweepExpiredSandboxes()

                    try self.checkTickPreconditions()

                    await SnapshotRetentionSweep.run(app: app)

                    try self.checkTickPreconditions()

                    // Prune expired idempotency keys every 120 ticks.
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

                    try self.checkTickPreconditions()

                    await sweepAgentAutoUpdates()
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

    /// Throws when the current tick must stop: the task was cancelled, the
    /// service shut down, or the application itself has been torn down.
    private func checkTickPreconditions() throws {
        try Task.checkCancellation()
        guard !isShutDown, !app.didShutdown else {
            throw CancellationError()
        }
    }

    /// Internal so tests can drive one monitor pass without waiting for the timer.
    func checkStaleAgents(dependencyMetricsFactory: (any MetricsFactory)? = nil) async {
        // Shutdown sets this before cancelling the loop; a tick that already
        // slipped past its sleep must not start a database sweep it doesn't
        // need to finish. The app-level check is a backstop for loops armed
        // outside the lifecycle handler's reach: touching `app.db` after
        // core teardown is a process-killing fatal error, not a throw.
        guard !isShutDown, !app.didShutdown else { return }

        let now = Date()
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
                guard heartbeatAge > staleThreshold else { continue }

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
    func sweepStuckConvergence() async {
        guard !isShutDown, !app.didShutdown else { return }

        let db = app.db
        let now = Date()

        do {
            try await degradeOverdue(VM.self, now: now, on: db)
            try await degradeOverdue(Sandbox.self, now: now, on: db)
            try await degradeOverdue(Volume.self, now: now, on: db)
            try await degradeOverdue(VolumeSnapshot.self, now: now, on: db)
            try await degradeOverdue(VMSnapshot.self, now: now, on: db)
            try await degradeOverdue(SandboxSnapshot.self, now: now, on: db)
        } catch {
            app.logger.error("Stuck-convergence sweep failed: \(error)")
        }
        await app.vmCommandExecutionService.sweepStuck(now: now)
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
    func sweepSteadyStateDivergence(now: Date = Date()) async -> SteadyStateDivergenceCounts {
        guard !isShutDown, !app.didShutdown else { return SteadyStateDivergenceCounts() }
        guard let sql = app.db as? any SQLDatabase else {
            app.logger.error("Steady-state divergence sweep requires an SQL database")
            return SteadyStateDivergenceCounts()
        }

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
        _ type: R.Type, now: Date, on db: any Database
    ) async throws {
        let overdue = try await R.overdueForConvergence(at: now, on: db)

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
                now: now, timeoutReason: timeoutReason, on: db)
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
    func sweepStrandedVolumeAttachments() async {
        // Never touch app.db (a fatal error, not a throw, after core
        // teardown) once shutdown has begun — this was the crashing frame of
        // the recurring "Core not configured" CI crash.
        guard !isShutDown, !app.didShutdown else { return }
        // Cluster-singleton: the repair is idempotent, but each pass bumps a
        // generation, so two replicas racing would churn the agent's sync for
        // nothing.
        guard await app.coordination.acquireSweepLock("stranded_attachments") else {
            app.logger.debug("Skipping stranded-attachment sweep; lock held by another control-plane instance")
            return
        }

        let db = app.db

        do {
            // This mirrors the schema constraint column for column: the fields
            // describe one state, so they must agree.
            let strandedVolumes = try await Volume.query(on: db)
                .filter(\.$vm.$id == nil)
                .group(.or) { unresolved in
                    unresolved.filter(\.$deviceName != nil)
                    unresolved.filter(\.$bootOrder != nil)
                    unresolved.filter(\.$attachedAgentId != nil)
                    unresolved.filter(\.$readonly == true)
                }
                .all()

            for volume in strandedVolumes {
                guard let volumeID = volume.id else { continue }
                let repaired = try await db.transaction { tx -> Bool in
                    guard try await volume.lockAndRefresh(on: tx) else { return false }
                    guard volume.$vm.id == nil,
                        volume.deviceName != nil || volume.bootOrder != nil
                            || volume.attachedAgentId != nil || volume.readonly
                    else { return false }
                    let expectedGeneration = volume.generation
                    VolumeAttachmentService.clearAttachment(volume)
                    guard
                        case .applied = try await volume.advanceDesiredStateGeneration(
                            expectedGeneration: expectedGeneration, on: tx)
                    else { return false }
                    try await volume.save(on: tx)
                    return true
                }
                guard repaired else { continue }

                app.logger.warning(
                    "Volume left attachment fields set with no VM; released",
                    metadata: [
                        "volumeId": .string(volumeID.uuidString),
                        "generation": .string("\(volume.generation)"),
                    ])
            }
        } catch {
            app.logger.error("Stranded-attachment sweep failed: \(error)")
        }
    }

    /// How long a terminating workload may sit with every finalizer cleared
    /// before this sweep reaps it. Generous on purpose: the delete path's own
    /// reap follows its finalizer clear by milliseconds, so anything this old
    /// lost the process that owed it (crash, drain, OOM kill) rather than
    /// being slow.
    static let orphanedTerminatingBudgetSeconds: TimeInterval = 60

    /// Reaps workloads whose finalizers all cleared but whose row survived
    /// (STR-144). Clearing a token and removing the row are two commits; a
    /// crash between them leaves a terminating row with an empty list, which
    /// still holds quota and still appears in listings.
    ///
    /// Participants with a repeating trigger heal themselves — every
    /// observed-state report re-drives `agent.absent`. This is the backstop for
    /// the ones that do not: the offline/unplaced direct path is a one-shot
    /// background task, and the sandbox expiry sweep's deletions are unattended,
    /// so without this a drained replica could strand a row with nobody left to
    /// notice. It is also what lets a future participant be added without each
    /// one inventing its own retry.
    ///
    /// Internal rather than private so tests can drive a pass directly.
    func sweepOrphanedTerminatingResources() async {
        guard !isShutDown, !app.didShutdown else { return }
        // Cluster-singleton like the other sweeps: the reap claim would make
        // concurrent passes safe anyway, but there is no reason to pay for
        // every replica scanning.
        guard await app.coordination.acquireSweepLock("orphaned_terminating") else { return }

        let db = app.db
        let cutoff = Date().addingTimeInterval(-Self.orphanedTerminatingBudgetSeconds)

        do {
            // `finalizers` is filtered in Swift, not SQL: Fluent cannot express
            // array cardinality, and the scanned set is only workloads that
            // have been terminating for at least a minute — normally empty.
            let vms = try await VM.query(on: db)
                .filter(\.$desiredStatus == .absent)
                .filterAged(before: cutoff, by: \.$updatedAt, fallingBackTo: \.$createdAt)
                .all()
            await reapOrphanedTerminating(vms.filter { $0.finalizers.isEmpty }, kind: "VM", on: db)

            let sandboxes = try await Sandbox.query(on: db)
                .filter(\.$desiredStatus == .absent)
                .filterAged(before: cutoff, by: \.$updatedAt, fallingBackTo: \.$createdAt)
                .all()
            await reapOrphanedTerminating(
                sandboxes.filter { $0.finalizers.isEmpty }, kind: "sandbox", on: db)

            let volumes = try await Volume.query(on: db)
                .filter(\.$desiredStatus == .absent)
                .filterAged(before: cutoff, by: \.$updatedAt, fallingBackTo: \.$createdAt)
                .all()
            await reapOrphanedTerminating(
                volumes.filter { $0.finalizers.isEmpty }, kind: "volume", on: db)

            // Snapshot artifacts (STR-150). Their `agent.absent` trigger is the
            // same repeating observed-state report, but the retention sweep's
            // deletions are unattended in exactly the way the sandbox expiry
            // sweep's are, so they need the same backstop.
            //
            // No age cutoff here, unlike the three above, and it is not an
            // oversight: `finalizers.isEmpty` on a terminating row already
            // means nobody owes cleanup — either the token cleared, or none was
            // stamped because the artifact never reached an agent. The cutoff
            // exists to keep the workload scan cheap on a large table, and the
            // terminating set here is normally empty.
            try await reapOrphanedTerminatingSnapshots(
                VolumeSnapshot.self, kind: "volume snapshot", on: db)
            try await reapOrphanedTerminatingSnapshots(
                VMSnapshot.self, kind: "checkpoint", on: db)
            try await reapOrphanedTerminatingSnapshots(
                SandboxSnapshot.self, kind: "sandbox snapshot", on: db)
        } catch {
            app.logger.error("Orphaned-terminating sweep failed: \(error)")
        }
    }

    /// The snapshot-artifact half of the orphan sweep. Separate from the
    /// workload half only because `desired_status` is a different enum type per
    /// family, which Fluent's field projection cannot be abstracted over.
    private func reapOrphanedTerminatingSnapshots<A: SnapshotArtifactResource>(
        _ type: A.Type, kind: String, on db: any Database
    ) async throws {
        let terminating = try await A.terminating(on: db).filter { $0.finalizers.isEmpty }
        await reapOrphanedTerminating(terminating, kind: kind, on: db)
    }

    /// Drives one kind's orphans through the ordinary clear path — clearing an
    /// already-cleared token on an empty list reaps — so the sweep shares the
    /// reap claim and per-kind teardown instead of re-spelling either.
    private func reapOrphanedTerminating<R: FinalizableResource>(
        _ resources: [R], kind: String, on db: any Database
    ) async {
        for resource in resources {
            guard let id = resource.id else { continue }
            do {
                let outcome = try await ResourceFinalizerService.clear(
                    .agentAbsent, from: resource, on: db, app: app)
                guard case .reaped = outcome else { continue }
                app.logger.warning(
                    "Reaped a terminating \(kind) whose row outlived its last finalizer",
                    metadata: ["resourceId": .string(id.uuidString)])
            } catch {
                app.logger.error(
                    "Failed to reap orphaned terminating \(kind): \(error)",
                    metadata: ["resourceId": .string(id.uuidString)])
            }
        }
    }

    // The transitional-status backstop — VMs and sandboxes sitting in
    // `.starting`/`.stopping` past 120s with no pending operation, marked
    // `.error` — went with the operations table (STR-152). It predated
    // generations: with no `observedGeneration` to compare against, "stuck" had
    // to be inferred from a status and a clock, and the pending-operation query
    // existed only to stop the two backstops fighting. `sweepStuckConvergence`
    // says the same thing from the deadline every accepted mutation stamps, and
    // resolves through the same per-kind `resolveForStuckOperation`.

    // MARK: - Sandbox expiry (issue #424)

    /// How long a terminal sandbox's record is kept by default.
    static let defaultSandboxRetentionHours = 24

    /// The retention window for terminal sandboxes, or nil when retention is
    /// off. `SANDBOX_RETENTION_HOURS` overrides the default; a non-positive
    /// value keeps terminal records — and the quota they still hold — forever,
    /// which is a deliberate opt-in, not the default.
    static func sandboxRetentionHours(configuration: ControlPlaneConfiguration) -> Int? {
        let raw = configuration.int(.sandboxRetentionHours)
        return raw > 0 ? raw : nil
    }

    /// Why the expiry sweep is deleting a sandbox. Both reasons end in the
    /// same deletion; they differ only in what started the clock.
    private enum SandboxExpiryReason {
        /// The lifetime budget ran out (`ttl_seconds` from `createdAt`).
        case ttl(seconds: Int)
        /// A terminal sandbox outlived the retention window for its record.
        case retention(hours: Int)

        var description: String {
            switch self {
            case .ttl(let seconds):
                return "TTL of \(seconds)s elapsed"
            case .retention(let hours):
                return "terminal record retained for \(hours)h"
            }
        }
    }

    /// Deletes sandboxes that have outlived either clock (issue #424):
    ///
    /// - **TTL** — `ttl_seconds` past `createdAt`. Sandboxes are ephemeral;
    ///   this is what makes the stored budget real.
    /// - **Retention** — an exited or errored sandbox keeps its terminal
    ///   record (status and exit code) for `SANDBOX_RETENTION_HOURS` so the
    ///   result stays inspectable, then the row goes. Errored sandboxes are
    ///   included because they are terminal too and would otherwise hold their
    ///   quota indefinitely.
    ///
    /// Cluster-singleton via the sweep lock, and level-triggered like every
    /// other sweep: a skipped or crashed pass costs latency, never
    /// correctness, because the next tick recomputes both clocks from scratch.
    ///
    /// Internal rather than private so tests can drive a pass directly.
    func sweepExpiredSandboxes() async {
        // Never touch app.db once shutdown has begun — after core teardown
        // that is a process-killing fatal error, not a throw.
        guard !isShutDown, !app.didShutdown else { return }
        guard await app.coordination.acquireSweepLock("sandbox_expiry") else {
            app.logger.debug("Skipping sandbox expiry sweep; lock held by another control-plane instance")
            return
        }

        let db = app.db
        let now = Date()

        do {
            var expiring: [(sandbox: Sandbox, reason: SandboxExpiryReason)] = []

            // A sandbox already heading for `.absent` is being deleted by
            // something else; leave it to that operation.
            let budgeted = try await Sandbox.query(on: db)
                .filter(\.$desiredStatus != .absent)
                .filter(\.$ttlSeconds != nil)
                .all()
            for sandbox in budgeted where sandbox.isExpired(at: now) {
                expiring.append((sandbox, .ttl(seconds: sandbox.ttlSeconds ?? 0)))
            }

            if let hours = Self.sandboxRetentionHours(configuration: app.controlPlaneConfiguration) {
                let window = TimeInterval(hours) * 3600
                // A sandbox already expiring on TTL must not be queued twice:
                // the second `begin` would collide with the first's pending
                // operation and log a spurious conflict.
                let alreadyExpiring = Set(expiring.compactMap(\.sandbox.id))
                // Terminal sandboxes are what accumulates, so the retention
                // window is a SQL predicate rather than a Swift filter over
                // every terminal row ever kept.
                let expiredBefore = now.addingTimeInterval(-window)
                let terminal = try await Sandbox.query(on: db)
                    .filter(\.$desiredStatus != .absent)
                    .filter(\.$status ~~ [.exited, .error])
                    .filterAged(before: expiredBefore, by: \.$statusChangedAt, fallingBackTo: \.$updatedAt)
                    .all()

                for sandbox in terminal {
                    guard let sandboxID = sandbox.id, !alreadyExpiring.contains(sandboxID) else { continue }
                    expiring.append((sandbox, .retention(hours: hours)))
                }
            }

            for (sandbox, reason) in expiring {
                await expireSandbox(sandbox, reason: reason, on: db)
            }
        } catch {
            app.logger.error("Sandbox expiry sweep failed: \(error)")
        }
    }

    /// Deletes one expired sandbox down the same path as `DELETE
    /// /api/sandboxes/:id`: desired `.absent` plus its attribution event in one
    /// transaction, then either agent teardown (the row goes once a report
    /// confirms absence) or — with no agent to converge on — a direct record
    /// delete. Sharing the path is the point: quota release, reservation
    /// release, and the audit trail all come for free, and the `system` actor
    /// on the event makes the unattended deletion attributable.
    private func expireSandbox(_ sandbox: Sandbox, reason: SandboxExpiryReason, on db: Database) async {
        guard let sandboxID = sandbox.id else { return }

        var onlineAgentID: String?
        if let agentId = sandbox.hypervisorId,
            let agentUUID = UUID(uuidString: agentId),
            let agent = try? await Agent.find(agentUUID, on: app.db),
            agent.status == .online
        {
            onlineAgentID = agentId
        }

        // With no agent to converge on, the expiry owns the teardown itself;
        // otherwise `.stateSync` nudges the agent holding it.
        let strategy: ResourceMutation.Dispatch =
            onlineAgentID == nil
            ? .directResolution { @Sendable [app = self.app] db in
                try await SandboxController.performDirectDeletion(sandbox: sandbox, on: db, app: app)
            }
            : .stateSync

        do {
            let accepted = try await app.resourceMutation.accept(
                .delete, on: sandbox, actor: .system, dispatch: strategy, on: db, app: app
            ) { db in
                try await SandboxController.requireSnapshotLineageDeletable(
                    for: sandboxID, on: db)
                // Same stamp-then-mark order as the user-initiated delete: an
                // expiry that races a user's DELETE must not re-stamp a token
                // its participant already cleared.
                try await ResourceFinalizerService.stampForDeletion(sandbox, on: db)
                sandbox.setDesiredStatus(.absent)
            }

            app.logger.info(
                "Expiring sandbox",
                metadata: [
                    "strato.sandbox.id": .string(sandboxID.uuidString),
                    "reason": .string(reason.description),
                    "strato.operation.id": .string(accepted.mutationID.uuidString),
                ])
        } catch {
            // The "operation already pending" `409` that used to defer an
            // expiry racing a user action is gone with the operation row
            // (STR-147), and is not missed: marking `.absent` is idempotent and
            // level-triggered, so an expiry landing on top of a user's own
            // delete converges on the same thing. What remains here is a real
            // failure — a snapshot lineage that refuses deletion, or a write
            // that did not commit — and the next tick recomputes both clocks,
            // so an expired sandbox is deferred rather than dropped.
            app.logger.debug(
                "Skipping sandbox expiry: \(error)",
                metadata: ["strato.sandbox.id": .string(sandboxID.uuidString)])
        }
    }

    // MARK: - Agent auto-update rollout (issue #434)

    /// How long an assigned agent has to either re-register at its target
    /// version or report a blocker before the sweep treats the silence as a
    /// failed update and halts the rollout. Generous on purpose: it spans the
    /// artifact download, the restart, and re-registration.
    static let autoUpdateHealthBudgetSeconds: TimeInterval = 600

    /// Advances the fleet's declarative agent updates one agent at a time
    /// (issue #434). Cluster-singleton via the sweep lock; all rollout state
    /// lives on the agent rows, so any replica can pick up where another
    /// stopped.
    ///
    /// Per tick, each *assigned* agent is classified — an operator's "update
    /// now" writes the same assignment (STR-145), so it is tracked, budgeted,
    /// and reported exactly like a rollout one, and an in-flight manual update
    /// holds the fleet rollout for the same reason a rollout assignment does:
    /// one agent restarts at a time.
    /// - **converged** — re-registered at the target: assignment cleared.
    /// - **stale** — a *rollout* assignment whose version the deployment target
    ///   has moved past: reset, including failures, so an old halt never blocks
    ///   a new target. Manual assignments are exempt — the operator named that
    ///   version (possibly a one-off build) deliberately.
    /// - **failed** — a recorded failure (agent-reported, or silence past the
    ///   health budget, recorded here). A *rollout* failure halts the fleet
    ///   until an operator intervenes or the target changes: the next agent
    ///   would most likely hit the same bad artifact. A *manual* one does not —
    ///   one operator action on one agent must not stop every other agent's
    ///   auto-update, especially since the manual assignment's own escapes
    ///   (converge, stale reset) are exactly what a terminal failure closes off.
    ///   Cancelling the assignment is what clears it.
    /// - **parked** — blocked past the health budget (e.g. running
    ///   Firecracker VMs): the assignment stays, level-triggered, so the
    ///   agent converges whenever its blocker clears — but advancement stops
    ///   waiting on it. Parked is marked by a nil `updateAttemptedAt`.
    /// - **waiting** — within budget: the rollout holds.
    ///
    /// Only when nothing is failed or waiting does the sweep assign the next
    /// eligible *enrolled* agent (deterministic name order), after proving the
    /// release actually publishes an artifact for that agent's platform.
    func sweepAgentAutoUpdates() async {
        guard !isShutDown, !app.didShutdown else { return }
        guard await app.coordination.acquireSweepLock("agent_auto_update") else {
            app.logger.debug("Skipping auto-update sweep; lock held by another control-plane instance")
            return
        }

        let db = app.db
        let now = Date()
        // Nil on a dev build with no configured target: no *rollout* can run,
        // but assignments an operator made by hand (which supply their own
        // artifact, precisely for builds a release does not serve) still need
        // their convergence bookkeeping, so classification runs regardless.
        let target = autoUpdateTarget
        let canonicalTarget = target.map(AgentVersionTarget.canonical)

        do {
            // Enrolled agents (candidates for the next assignment) plus anyone
            // already carrying one — an operator's manual update assigns the
            // same field without requiring enrollment (STR-145), and it needs
            // the same convergence bookkeeping.
            let candidates = try await Agent.query(on: db)
                .group(.or) { group in
                    group
                        .filter(\.$autoUpdate == true)
                        .filter(\.$updateDesiredVersion != nil)
                }
                .sort(\.$name)
                .all()

            var rolloutHalted = false
            var waitingOnAgent = false

            for agent in candidates {
                guard let assigned = agent.updateDesiredVersion else { continue }

                // The deployment target moved past this assignment
                // (mid-rollout upgrade): reset everything, including a
                // failure — the old target's halt must not block the new one.
                // Only for rollout assignments: a manual one names a version
                // the operator chose, which the deployment target has no
                // opinion about.
                guard
                    agent.updateAssignmentSource == .manual
                        || canonicalTarget == nil
                        || AgentVersionTarget.canonical(assigned) == canonicalTarget
                else {
                    agent.clearUpdateAssignment()
                    try await agent.save(on: db)
                    continue
                }

                // Converged: the agent re-registered at the target (or was
                // updated by hand, which counts just the same).
                if !AgentVersionTarget.updateAvailable(agentVersion: agent.version, target: assigned) {
                    agent.clearUpdateAssignment()
                    try await agent.save(on: db)
                    Telemetry.agentAutoUpdateConverged()
                    app.logger.notice(
                        "Agent auto-update converged",
                        metadata: [
                            "strato.agent.name": .string(agent.name),
                            "version": .string(agent.version),
                        ])
                    continue
                }

                if agent.updateFailureReason != nil {
                    // A *rollout* failure halts the fleet until an operator
                    // intervenes: the next agent would most likely hit the same
                    // bad artifact. A manual one does not. It is one operator's
                    // action on one agent — possibly not even an enrolled one —
                    // and letting it stop every other agent's auto-update means
                    // a single failed "update now" wedges the fleet with no
                    // automatic way out (the assignment is exempt from the
                    // stale reset by design, and the agent that would clear it
                    // by converging is the one that just died). Cancelling the
                    // assignment is the operator's escape; until then this
                    // agent simply holds its own failure.
                    if agent.updateAssignmentSource != .manual {
                        rolloutHalted = true
                    }
                    continue
                }

                // Parked earlier (nil clock, see below): the assignment keeps
                // riding the syncs, but the rollout no longer waits on it.
                guard let attemptedAt = agent.updateAttemptedAt else { continue }
                let age = now.timeIntervalSince(attemptedAt)

                if agent.updateBlockedReason != nil {
                    if age > Self.autoUpdateHealthBudgetSeconds {
                        agent.updateAttemptedAt = nil
                        try await agent.save(on: db)
                        Telemetry.agentAutoUpdateParked()
                        app.logger.notice(
                            "Agent auto-update parked: blocked past the health budget; rollout advances without it",
                            metadata: [
                                "strato.agent.name": .string(agent.name),
                                "targetVersion": .string(assigned),
                                "blockedReason": .string(agent.updateBlockedReason ?? ""),
                            ])
                    } else {
                        waitingOnAgent = true
                    }
                    continue
                }

                if age > Self.autoUpdateHealthBudgetSeconds {
                    // Silence past the budget: the agent neither converged
                    // nor explained itself — most likely it attempted the
                    // update and never came back.
                    let manual = agent.updateAssignmentSource == .manual
                    agent.recordUpdateFailure(
                        "did not re-register at \(assigned) within \(Int(Self.autoUpdateHealthBudgetSeconds))s of assignment"
                    )
                    try await agent.save(on: db)
                    Telemetry.agentAutoUpdateFailed(reason: "health_budget")
                    app.logger.error(
                        manual
                            ? "Agent update failed: agent went silent past the health budget"
                            : "Agent auto-update failed: agent went silent past the health budget; rollout halted",
                        metadata: [
                            "strato.agent.name": .string(agent.name),
                            "targetVersion": .string(assigned),
                        ])
                    rolloutHalted = rolloutHalted || !manual
                } else {
                    waitingOnAgent = true
                }
            }

            guard !rolloutHalted && !waitingOnAgent else { return }
            // Bookkeeping is done; advancing the fleet needs a target version.
            guard let target else { return }

            // Nothing in flight and nothing failed: assign the next agent.
            // Eligibility mirrors the update endpoint's checks, minus the
            // hosted-workload guard — that precondition is evaluated live on
            // the agent, which is the only side that actually knows.
            let next = candidates.first { agent in
                agent.autoUpdate
                    && agent.updateDesiredVersion == nil
                    && AgentVersionTarget.updateAvailable(agentVersion: agent.version, target: target)
                    && agent.isOnline
                    && agent.hostOperatingSystem != nil
                    && agent.cpuArchitecture != nil
            }
            guard let next, let nextId = next.id else { return }

            // Prove the release serves this agent's platform before assigning
            // — an unresolvable artifact would leave the agent silently
            // unconverged until the budget halted the whole rollout.
            do {
                _ = try await app.agentArtifactResolver.resolve(
                    version: target,
                    operatingSystem: next.hostOperatingSystem ?? .linux,
                    architecture: next.cpuArchitecture ?? .arm64
                )
            } catch {
                app.logger.warning(
                    "Agent auto-update artifact unresolvable; not assigning (retries next sweep)",
                    metadata: [
                        "strato.agent.name": .string(next.name),
                        "targetVersion": .string(target),
                        "error": .string(String(describing: error)),
                    ])
                return
            }

            next.assignUpdate(version: target, source: .rollout, at: now)
            try await next.save(on: db)
            Telemetry.agentAutoUpdateAssigned()
            app.logger.notice(
                "Agent auto-update assigned",
                metadata: [
                    "strato.agent.name": .string(next.name),
                    "currentVersion": .string(next.version),
                    "targetVersion": .string(target),
                ])
            // Ring now for low latency; the agent's unconditional refetch is
            // the correctness backstop.
            await app.agentService.syncDesiredState(agentId: nextId.uuidString)
        } catch {
            app.logger.error("Agent auto-update sweep failed: \(error)")
        }
    }

}
