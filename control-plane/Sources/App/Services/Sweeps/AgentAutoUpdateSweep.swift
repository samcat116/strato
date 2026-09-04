import Foundation
import Fluent
import Metrics
import SQLKit
import StratoShared
import Vapor

extension AgentMaintenanceLoop {
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
    func sweepAgentAutoUpdates(
        at instant: ClusterInstant,
        currentInstant: @Sendable (any Database) async throws -> ClusterInstant = {
            try await ClusterClock.read(on: $0)
        }
    ) async {
        guard !isShutDown, !app.didShutdown else { return }
        guard await app.coordination.acquireSweepLock("agent_auto_update") else {
            app.logger.debug("Skipping auto-update sweep; lock held by another control-plane instance")
            return
        }

        let db = app.db
        let now = instant.date
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
                    && agent.isOnline(at: instant)
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

            // Artifact resolution and every earlier sweep may take time. Use a
            // current database instant for the assignment itself so none of
            // that work consumes the agent's health budget. Recheck liveness
            // against the same instant before committing the assignment.
            let assignmentInstant = try await currentInstant(db)
            guard next.isOnline(at: assignmentInstant) else { return }
            next.assignUpdate(version: target, source: .rollout, at: assignmentInstant)
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
