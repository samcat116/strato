import Foundation
import Vapor
import StratoShared
import NIOWebSocket
import Fluent
import NIOCore
import NIOConcurrencyHelpers
import SQLKit
import Tracing
import Metrics

/// Owns periodic fleet-health, convergence, retention, and finalization sweeps.
extension AgentService {
    // MARK: - Heartbeat Monitoring

    /// Whether the heartbeat loop is currently armed. Test seam for verifying that
    /// the shutdown hook tears it down.
    var isHeartbeatActive: Bool {
        heartbeatTask != nil
    }

    func startHeartbeatMonitoring() {
        // Don't (re)arm the loop if shutdown already raced ahead of init.
        guard !isShutDown else { return }
        heartbeatTask = Task {
            var tick = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: heartbeatInterval)
                    tick &+= 1

                    // Shutdown cancels mid-tick and awaits the loop; checking
                    // between steps keeps the remaining app-touching work (and
                    // shutdown's wait) as short as possible. The application
                    // check is the last line of defense for a loop that
                    // somehow outlives its app: every step below touches
                    // app.db or app storage, which is a process-killing fatal
                    // error (not a throw) after core teardown.
                    try self.checkTickPreconditions()

                    // Check for stale agents
                    await checkStaleAgents()

                    try self.checkTickPreconditions()

                    // Probe (and re-arm if dead) this replica's pub/sub
                    // subscriptions — a dropped Valkey connection loses them
                    // silently and RediStack does not restore them.
                    await app.replicaBridge.verifySubscriptions()

                    try self.checkTickPreconditions()

                    // Degrade workloads that missed their convergence deadline
                    // (STR-147). Lock-free — see `sweepStuckConvergence`.
                    await sweepStuckConvergence()

                    try self.checkTickPreconditions()

                    // Surface desired/observed divergence when no mutation is
                    // outstanding (STR-123). Each row carries its own
                    // compare-and-swap warning claim across replicas.
                    await sweepSteadyStateDivergence()

                    try self.checkTickPreconditions()

                    // Release volumes still naming a VM that no longer exists
                    // (STR-129).
                    await sweepStrandedVolumeAttachments()

                    try self.checkTickPreconditions()

                    // Reap workloads whose finalizers all cleared but whose row
                    // outlived the process that owed the removal (STR-144).
                    await sweepOrphanedTerminatingResources()

                    try self.checkTickPreconditions()

                    // Delete sandboxes past their TTL, and reap terminal
                    // sandbox records past the retention window (issue #424).
                    await sweepExpiredSandboxes()

                    try self.checkTickPreconditions()

                    // Delete snapshot artifacts past their retention deadline
                    // (STR-150) — the `ttlSecondsAfterFinished` answer durable
                    // artifact objects need and fire-and-forget RPCs did not.
                    await SnapshotRetentionSweep.run(app: app)

                    try self.checkTickPreconditions()

                    // Advance the agent auto-update rollout one agent at a
                    // time (issue #434).
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
    func checkTickPreconditions() throws {
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
                        metadata: ["agentName": .string(agent.name)])
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
                    metadata: ["agentName": .string(agent.name)])
                await warnIfSiteNetworkController(agent)
            }
        } catch {
            app.logger.error("Stale-agent sweep failed: \(error)")
        }
    }

    /// Raises the alarm when the node that just went quiet is some site's
    /// designated network controller.
    ///
    /// This is the highest-value signal in the site-authority area: nothing
    /// else in the site can author topology while it is gone, so *every* new
    /// networked workload there is about to be refused, and already-running
    /// ones keep running — which is exactly what makes the outage easy to miss
    /// (issue #833). Best effort: a failure here must not abort the sweep.
    func warnIfSiteNetworkController(_ agent: Agent) async {
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
                        "agentName": .string(agent.name),
                        "site": .string(site.name),
                        "graceSeconds": .stringConvertible(offlineGrace),
                    ])
            }
        } catch {
            app.logger.warning(
                "Failed to check whether the stale agent is a site's network controller",
                metadata: ["agentName": .string(agent.name), "error": .string("\(error)")])
        }
    }

    /// Marks a VM or sandbox `degraded` once its convergence deadline passes
    /// with the outstanding mutations still unconverged (ADR 0001 stage 4,
    /// STR-147).
    ///
    /// This is what the stuck-*operation* sweep was for lifecycle mutations,
    /// now that they keep no operation row: the deadline every accepted
    /// mutation stamps replaces the row's `created_at` plus its per-kind
    /// budget, and the resource's own `conditions.degraded` replaces the
    /// verdict.
    ///
    /// **Deliberately not a cluster singleton.** Marking degraded is idempotent
    /// (`recordFailure` no-ops once `failedGeneration == generation`) and
    /// commutative (every replica computes the same verdict from the same
    /// row), so two replicas sweeping the same resource cost one wasted write
    /// at worst — where the operation sweep genuinely needed the lock, because
    /// its verdict was a state transition two writers could disagree about.
    /// One less thing whose correctness depends on Valkey, which is the point
    /// of ADR 0001's multi-replica argument.
    ///
    /// Internal rather than private so tests can drive a pass directly.
    func sweepStuckConvergence() async {
        guard !isShutDown, !app.didShutdown else { return }

        let db = app.db
        let now = Date()

        do {
            try await degradeOverdue(VM.self, now: now, on: db)
            try await degradeOverdue(Sandbox.self, now: now, on: db)
            // Volumes joined the same backstop in STR-148, replacing the
            // status-and-timestamp sweep that used to guess which transitional
            // status had been abandoned. Snapshot artifacts followed in
            // STR-150, replacing the RPC timeouts that used to decide a
            // capture's fate.
            try await degradeOverdue(Volume.self, now: now, on: db)
            try await degradeOverdue(VolumeSnapshot.self, now: now, on: db)
            try await degradeOverdue(VMSnapshot.self, now: now, on: db)
            try await degradeOverdue(SandboxSnapshot.self, now: now, on: db)
        } catch {
            app.logger.error("Stuck-convergence sweep failed: \(error)")
        }
        await app.vmCommandExecutionService.sweepStuck(now: now)
    }

    /// Fixed grace before a resting desired/observed mismatch becomes
    /// operationally divergent. Kept longer than ordinary report jitter and
    /// short agent outages, while remaining alertable within one quarter-hour.
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

    struct DivergedWorkloadRow: Decodable {
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

    struct DivergenceClaim: Decodable { let id: UUID }

    func divergentVMRows(
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

    func divergentSandboxRows(
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

    func claimVMDivergence(
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

    func claimSandboxDivergence(
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

    func logDivergence(_ row: DivergedWorkloadRow, kind: String) {
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

    /// One workload kind's overdue rows. The deadline is the only column the
    /// query filters on — no kind lookup, which is exactly what stamping a
    /// deadline instead of a `lastMutationKind` bought.
    func degradeOverdue<R: ConvergingResource>(
        _ type: R.Type, now: Date, on db: any Database
    ) async throws {
        let overdue = try await R.overdueForConvergence(at: now, on: db)

        for resource in overdue {
            guard let id = resource.id else { continue }
            // Claim the timeout before doing anything with it. Clearing the
            // deadline is the claim, so of two replicas sweeping the same row
            // exactly one proceeds — which is what lets this run everywhere
            // without a lock while still emitting one completion webhook.
            switch try await resource.claimConvergenceTimeout(on: db) {
            case .claimed:
                break
            case .superseded(let actualGeneration):
                Telemetry.desiredStateWriteConflict(
                    resourceKind: R.operationResourceKind.rawValue, writer: "stuck_convergence")
                app.logger.warning(
                    "Dropped a convergence timeout after newer desired state superseded it",
                    metadata: [
                        "resourceKind": .string(R.operationResourceKind.rawValue),
                        "resourceId": .string(id.uuidString),
                        "expectedGeneration": .stringConvertible(resource.generation),
                        "actualGeneration": .stringConvertible(actualGeneration),
                    ])
                continue
            case .alreadyClaimed, .missing:
                continue
            }

            // The deadline is a backstop, not the verdict: a resource that
            // converged between the query and here (or whose deadline the
            // applier has not cleared yet) is left alone — the claim above has
            // already dropped the deadline, which is all that was owed. A
            // terminating resource never reports converged — it is on its way
            // out, not converging on anything — so a stuck delete falls through
            // and degrades, which is what a delete blocked on a finalizer
            // should look like.
            // Nothing to save: the claim already cleared the deadline in SQL,
            // and writing the whole row from a model read before the claim
            // would put this sweep's stale snapshot over a concurrent report.
            guard !resource.isConverged else { continue }

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

            let outcome = try await ResourceConvergence.recordFailure(
                resource, mutation: mutation,
                reason: "Timed out: the agent did not converge to generation "
                    + "\(resource.generation) before the deadline",
                telemetryReason: "stuck_convergence", on: db)
            if case .superseded(let actualGeneration) = outcome {
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
    func reapOrphanedTerminatingSnapshots<A: SnapshotArtifactResource>(
        _ type: A.Type, kind: String, on db: any Database
    ) async throws {
        let terminating = try await A.terminating(on: db).filter { $0.finalizers.isEmpty }
        await reapOrphanedTerminating(terminating, kind: kind, on: db)
    }

    /// Drives one kind's orphans through the ordinary clear path — clearing an
    /// already-cleared token on an empty list reaps — so the sweep shares the
    /// reap claim and per-kind teardown instead of re-spelling either.
    func reapOrphanedTerminating<R: FinalizableResource>(
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
        guard let raw = configuration.int(.sandboxRetentionHours) else { return nil }
        return raw > 0 ? raw : nil
    }

    /// Why the expiry sweep is deleting a sandbox. Both reasons end in the
    /// same deletion; they differ only in what started the clock.
    enum SandboxExpiryReason {
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
    func expireSandbox(_ sandbox: Sandbox, reason: SandboxExpiryReason, on db: Database) async {
        guard let sandboxID = sandbox.id else { return }

        var onlineAgentID: String?
        if let agentId = sandbox.hypervisorId, let agent = await getAgentInfo(agentId), agent.status == .online {
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
                    "sandboxId": .string(sandboxID.uuidString),
                    "reason": .string(reason.description),
                    "mutationId": .string(accepted.mutationID.uuidString),
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
                metadata: ["sandboxId": .string(sandboxID.uuidString)])
        }
    }
}
