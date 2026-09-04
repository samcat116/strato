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

/// Owns serialized observed-state report ingestion and durable status projection.
extension AgentService {
    // MARK: - Observed-state reports (issue #260)

    /// Serialize observed-state report application per agent. `applyObserved-
    /// StateReport` suspends repeatedly (coordination store, per-VM database
    /// writes), so applying each report in an independent task would let actor
    /// reentrancy interleave two reports from the same agent — and a stale
    /// report finishing last could flip `vm.status` backwards and fire
    /// spurious drift telemetry. Chaining on the previous report preserves the
    /// agent's own send order.
    func enqueueObservedStateReport(_ envelope: MessageEnvelope, fromAgentKey agentKey: String) {
        nextReportTailId &+= 1
        let id = nextReportTailId
        let predecessor = reportTails[agentKey]?.task
        let task = Task { [weak self] in
            await predecessor?.value
            await self?.applyObservedStateReport(envelope, fromAgentKey: agentKey)
            await self?.retireReportTail(agentKey: agentKey, id: id)
        }
        reportTails[agentKey] = (id, task)
    }

    /// Drop the chain bookkeeping once the finishing link is still the tail,
    /// so idle agents don't pin their last report task forever.
    func retireReportTail(agentKey: String, id: UInt64) {
        if reportTails[agentKey]?.id == id {
            reportTails.removeValue(forKey: agentKey)
        }
    }

    /// Handle an agent's full observed-state report: verify the authenticated
    /// connection owns the claimed agent, refresh the agent row's resources and
    /// liveness (mirroring the heartbeat path), then hand the workload contents
    /// to `ObservedStateApplier`.
    ///
    /// `agentKey` identifies the authenticated connection, mirroring the
    /// heartbeat's ownership check. Callers outside tests should go through
    /// `enqueueObservedStateReport` so same-agent reports apply in order.
    func applyObservedStateReport(_ envelope: MessageEnvelope, fromAgentKey agentKey: String) async {
        let report: ObservedStateReport
        do {
            report = try envelope.decode(as: ObservedStateReport.self)
        } catch {
            app.logger.error("Failed to decode observed-state report: \(error)")
            return
        }

        guard let agentUUID = UUID(uuidString: report.agentId),
            let agent = try? await Agent.find(agentUUID, on: app.db)
        else {
            app.logger.warning(
                "Observed-state report from unknown agent",
                metadata: ["strato.agent.claimed.id": .string(report.agentId)])
            return
        }
        guard agent.identity.key == agentKey else {
            app.logger.warning(
                "Observed-state report claims an agentId not owned by the authenticated connection; ignoring",
                metadata: [
                    "strato.agent.claimed.id": .string(report.agentId),
                    "strato.agent.connection.identity": .string(agentKey),
                ])
            return
        }

        // Reports carry the same resource snapshot as heartbeats; keep the
        // scheduler's view fresh from whichever arrives without re-saving an
        // identical row a second time.
        var agentChanged = applyPeriodicAgentState(
            report.resources,
            dependencyObservations: nil,
            hostResourceTelemetry: report.hostResourceTelemetry,
            to: agent)
        let previousBlockedReason = agent.updateBlockedReason
        let previousFailureReason = agent.updateFailureReason
        applyReportedUpdateStatus(report.agentUpdateStatus, to: agent)
        if agent.updateBlockedReason != previousBlockedReason
            || agent.updateFailureReason != previousFailureReason
        {
            agentChanged = true
            agent.lastHeartbeat = Date()
        }
        if applyReportedTeardownRefusal(report.teardownRefusal, to: agent) {
            agentChanged = true
        }
        if applyReportedManifestStatus(report.manifestStatus, to: agent) {
            agentChanged = true
        }
        if agentChanged {
            do {
                try await agent.save(on: app.db)
            } catch {
                app.logger.warning(
                    "Failed to persist agent resources from observed-state report: \(error)",
                    metadata: ["strato.agent.id": .string(report.agentId)])
            }
        }

        // The report arrived over this process's socket: refresh presence
        // alongside, mirroring the heartbeat path.
        await refreshAgentPresenceIfNeeded(agentKey: agentKey)

        // Storage inventory has its own completeness contract and transaction.
        // A malformed or unavailable disk snapshot must not prevent valid VM,
        // sandbox, volume, or network observations in this report from applying.
        if let storageDevices = report.storageDevices {
            do {
                try await StorageDeviceInventoryReconciler(application: app).apply(
                    storageDevices,
                    for: agent,
                    receivedAt: Date())
            } catch {
                app.logger.error(
                    "Failed to apply storage-device inventory: \(error)",
                    metadata: ["strato.agent.id": .string(report.agentId)])
            }
        }

        do {
            let outcome = try await app.observedStateApplier.apply(report)
            // Level-triggered, and recorded here because this is where the
            // agent's name is: the withheld-teardown counter only fires at the
            // transition, so on its own it can't answer whether a host is
            // still holding workloads the control plane failed to describe.
            for (reason, count) in outcome.heldByReason {
                Telemetry.workloadClaimsHeld(agentName: agent.name, reason: reason, count: count)
            }
            await recordVolumeIOTelemetry(report: report, agentName: agent.name)
            // A newly authorized teardown (STR-98) is worth a sync right away:
            // until the tombstone reaches the agent it keeps holding — and
            // re-reporting — a workload nothing describes.
            if outcome.authorizedTeardown || outcome.desiredStateChanged {
                await syncDesiredState(agentId: report.agentId)
            }
        } catch {
            app.logger.error(
                "Failed to apply observed-state report: \(error)",
                metadata: ["strato.agent.id": .string(report.agentId)])
        }
    }

    /// Build bounded, agent-level I/O aggregates from the same authoritative
    /// full volume report that drove convergence. Unknown/spoofed volume ids do
    /// not enter metrics: only rows currently placed on this agent are sampled.
    private func recordVolumeIOTelemetry(report: ObservedStateReport, agentName: String) async {
        guard let observedVolumes = report.volumes else { return }
        do {
            let volumes = try await VolumeService.volumes(onAgent: report.agentId, on: app.db)
            let observedByID = Dictionary(
                observedVolumes.map { ($0.volumeId, $0) },
                uniquingKeysWith: { first, _ in first })
            let samples = volumes.map { volume in
                let observed = volume.id.flatMap { observedByID[$0] }
                return Telemetry.VolumeIOSample(
                    configured: volume.ioLimits,
                    applied: observed?.ioLimits,
                    observedRate: observed?.ioObservedRate)
            }
            Telemetry.recordVolumeIO(agentName: agentName, samples: samples)
        } catch {
            app.logger.warning(
                "Failed to record volume I/O telemetry: \(error)",
                metadata: ["strato.agent.id": .string(report.agentId)])
        }
    }

    /// Folds an agent's teardown refusal (STR-98 phase 2) into its row,
    /// mutating the in-memory model for the caller's save.
    ///
    /// A refusal means the agent declined to converge teardowns a sync
    /// authorized because they would have taken out too much of the host at
    /// once. That is a standing condition, not an event: it repeats on every
    /// sync until either the batch shrinks or an operator intervenes, so it
    /// lives on the row where the UI can show it rather than only in a log.
    ///
    /// The log line and the counter are deduped on `syncId`, because the
    /// refusal rides along on *every* observed report — heartbeats included —
    /// while the agent's guard stands. Logging per report would turn one stuck
    /// refusal into thousands of `error` lines a day, which is exactly how an
    /// error level stops meaning anything. Per refused sync is the honest
    /// count; the row keeps `teardownRefusedAt` fresh either way, so the UI
    /// still shows the condition as current.
    /// Returns whether the row actually changed, so a heartbeat carrying a
    /// refusal it has already recorded costs no write.
    func applyReportedTeardownRefusal(
        _ refusal: ObservedTeardownRefusal?, to agent: Agent
    ) -> Bool {
        guard let refusal else {
            reportedTeardownRefusalSyncIds.removeValue(forKey: agent.name)
            guard agent.teardownRefusalReason != nil || agent.teardownRefusedAt != nil else {
                return false
            }
            agent.teardownRefusalReason = nil
            agent.teardownRefusedAt = nil
            return true
        }
        guard reportedTeardownRefusalSyncIds[agent.name] != refusal.syncId else {
            // Same refused sync, re-reported on a heartbeat. Already logged,
            // already counted, already on the row.
            return agent.teardownRefusalReason != refusal.reason
        }
        reportedTeardownRefusalSyncIds[agent.name] = refusal.syncId
        app.logger.error(
            "Agent refused a sync's workload teardowns",
            metadata: [
                "strato.agent.name": .string(agent.name),
                "syncId": .string(refusal.syncId),
                "requestedTeardowns": .stringConvertible(refusal.requestedTeardowns),
                "presentWorkloads": .stringConvertible(refusal.presentWorkloads),
                "reason": .string(refusal.reason),
            ])
        Telemetry.agentTeardownRefused()
        agent.teardownRefusalReason = refusal.reason
        agent.teardownRefusedAt = Date()
        return true
    }

    /// Folds an agent's self-reported manifest status (STR-138) into its row,
    /// mutating the in-memory model for the caller's save.
    ///
    /// The manifest is the agent's only memory of what it is running. When it
    /// cannot be read the agent quarantines itself — zero advertised capacity,
    /// no convergence — and that is a standing condition an operator has to
    /// resolve on the host, so it lives on the row where the UI shows it
    /// rather than in a log line on a node nobody is looking at.
    ///
    /// Returns whether the row actually changed, so the reports that re-assert
    /// an unchanged condition on every heartbeat cost no write. The gauge is
    /// recorded on every report, changed or not: it answers "is this still
    /// happening", which a transition-only signal cannot.
    func applyReportedManifestStatus(
        _ status: ObservedManifestStatus?, to agent: Agent
    ) -> Bool {
        Telemetry.agentManifestUnreadable(
            agentName: agent.name, unreadable: status.map { !$0.inventoryComplete } ?? false)

        guard let status else {
            guard
                agent.manifestStatusReason != nil || agent.manifestStatusAt != nil
                    || agent.manifestInventoryComplete != nil
            else { return false }
            app.logger.notice(
                "Agent's workload manifest is healthy again",
                metadata: ["strato.agent.name": .string(agent.name)])
            agent.manifestStatusReason = nil
            agent.manifestStatusAt = nil
            agent.manifestInventoryComplete = nil
            return true
        }

        guard
            agent.manifestStatusReason != status.reason
                || agent.manifestInventoryComplete != status.inventoryComplete
        else {
            // Same condition, re-reported on a heartbeat: already logged,
            // already on the row.
            return false
        }
        app.logger.error(
            status.inventoryComplete
                ? "Agent is holding workloads its build cannot route"
                : "Agent cannot read its workload manifest; it is quarantined and placing nothing",
            metadata: [
                "strato.agent.name": .string(agent.name),
                "quarantinedEntries": .stringConvertible(status.quarantinedEntries),
                "reason": .string(status.reason),
            ])
        agent.manifestStatusReason = status.reason
        agent.manifestStatusAt = Date()
        agent.manifestInventoryComplete = status.inventoryComplete
        return true
    }

    /// Folds an agent's self-reported update status (issue #434) into its
    /// row, mutating the in-memory model for the caller's save. Reports about
    /// a version other than the row's current assignment are ignored — a
    /// stale in-flight report must not be attributed to a newer rollout
    /// target.
    func applyReportedUpdateStatus(_ status: ObservedAgentUpdateStatus?, to agent: Agent) {
        guard let status else {
            // Nothing in the way (or nothing desired): clear a stale blocked
            // reason so the API stops surfacing it. Failures stay — they are
            // rollout state, resolved by convergence or operator action.
            agent.updateBlockedReason = nil
            return
        }
        guard let assigned = agent.updateDesiredVersion,
            AgentVersionTarget.canonical(status.targetVersion) == AgentVersionTarget.canonical(assigned)
        else { return }

        switch status.disposition {
        case ObservedAgentUpdateStatus.dispositionFailed:
            // Terminal for this artifact and process lifetime: record the real
            // error instead of waiting out the budget (and, for a rollout
            // assignment, halt on it).
            agent.updateBlockedReason = nil
            if agent.updateFailureReason != status.reason {
                agent.recordUpdateFailure(status.reason)
                app.logger.error(
                    "Agent reported its assigned update failed",
                    metadata: [
                        "strato.agent.name": .string(agent.name),
                        "targetVersion": .string(status.targetVersion),
                        "reason": .string(status.reason),
                    ])
                Telemetry.agentAutoUpdateFailed(reason: "agent_reported")
            }
        default:
            // `blocked`, and — conservatively — any disposition this build
            // does not know yet.
            if agent.updateBlockedReason != status.reason {
                agent.updateBlockedReason = status.reason
                app.logger.info(
                    "Agent reported its assigned update as blocked",
                    metadata: [
                        "strato.agent.name": .string(agent.name),
                        "targetVersion": .string(status.targetVersion),
                        "reason": .string(status.reason),
                    ])
            }
        }
    }
}
