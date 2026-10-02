import Foundation
import StratoAgentCore
import StratoShared

#if os(Linux)
extension FirecrackerSandboxRuntime {
    func noteIdleActivity(sandboxId: String, at now: Date = Date()) {
        idleLastActivity[sandboxId] = max(idleLastActivity[sandboxId] ?? now, now)
    }

    /// No producer is enabled until the coordinated activity contract lands.
    /// An absent observation remains unknown; API silence and internal log
    /// followers cannot manufacture it. Updates also invalidate STR-312's
    /// activity ticket before any await, including transitions back to idle.
    func observeIdleActivity(sandboxId: String, observation: SandboxIdleActivityObservation) {
        if let previous = idleActivityObservations[sandboxId], observation.observedAt < previous.observedAt {
            return
        }
        let previous = idleActivityObservations[sandboxId]
        idleResidentSince[sandboxId] = idleResidentSince[sandboxId] ?? Date()
        noteIdleActivity(sandboxId: sandboxId, at: observation.lastActiveAt)
        if (previous?.activeUserStreams != observation.activeUserStreams
            && ((previous?.activeUserStreams ?? 0) > 0 || (observation.activeUserStreams ?? 0) > 0))
            || (previous?.pendingUserCommands != observation.pendingUserCommands
                && ((previous?.pendingUserCommands ?? 0) > 0 || (observation.pendingUserCommands ?? 0) > 0))
        {
            noteIdleActivity(sandboxId: sandboxId)
        }
        if previous == nil || previous?.lastActiveAt != observation.lastActiveAt
            || previous?.residentSince != observation.residentSince
            || previous?.activeUserStreams != observation.activeUserStreams
            || previous?.pendingUserCommands != observation.pendingUserCommands
            || previous?.guestAndNetworkActivityKnown != observation.guestAndNetworkActivityKnown
        {
            let token = suspensionGuards[sandboxId, default: SandboxSuspensionGuard()].beginActivity()
            suspensionGuards[sandboxId]?.endActivity(token)
        }
        idleActivityObservations[sandboxId] = observation
    }

    func recordIdleResidency(sandboxId: String, at now: Date = Date()) {
        idleResidentSince[sandboxId] = now
        invalidateIdleActivity(sandboxId: sandboxId)
    }

    func invalidateIdleActivity(sandboxId: String) {
        idleActivityObservations.removeValue(forKey: sandboxId)
        idleSuspensionAdmissions.removeValue(forKey: sandboxId)
        noteIdleActivity(sandboxId: sandboxId)
    }

    func idleSuspensionEvidence(sandboxId: String) -> SandboxIdlePolicy.Evidence? {
        guard let managed = sandboxes[sandboxId], let id = UUID(uuidString: sandboxId),
            let observation = idleActivityObservations[sandboxId],
            let activity = suspensionGuards[sandboxId]
        else { return nil }
        let execCount = execSessions.values.filter { $0.sandboxId == sandboxId }.count
        return observation.evidence(
            sandboxID: id, agentIncarnation: idleActivityIncarnation,
            activityGeneration: activity.activityEpoch, lastLocalActivity: idleLastActivity[sandboxId],
            localResidentSince: idleResidentSince[sandboxId],
            activeExecSessions: execCount, pendingCommands: activity.pendingActivityCount,
            supportsFullSnapshot: managed.jail != nil && managed.warmHeldIdentity == nil
                && managed.guestControlProtocolVersion != nil
                && (managed.spec.network == nil || networkOverridesSupport == true),
            snapshotOrRestoreInProgress: checkpointing.contains(sandboxId))
    }

    func prepareIdleSuspension(sandboxId: String, policy: SandboxIdlePolicy) async -> SandboxIdlePolicy.Verdict {
        guard policy.enabled else {
            idleSuspensionAdmissions.removeValue(forKey: sandboxId)
            return .disabled
        }
        guard !suspending.contains(sandboxId), !checkpointing.contains(sandboxId) else { return .busy }
        idleSuspensionAdmissions.removeValue(forKey: sandboxId)
        guard let managed = sandboxes[sandboxId], idleActivityObservations[sandboxId] != nil else {
            idleSuspensionAdmissions.removeValue(forKey: sandboxId)
            return .unknownActivity
        }
        if managed.spec.network != nil {
            guard let supported = await probeNetworkOverridesSupport() else { return .unknownActivity }
            guard supported else { return .unsupportedBackend }
        }
        do {
            guard try await managed.manager.getInstanceInfo().state == .running else { return .unknownActivity }
        } catch {
            logger.debug("Idle eligibility could not confirm running sandbox: \(sandboxId)")
            return .unknownActivity
        }
        // Actor reentrancy must not publish a claim under a concurrent capture.
        guard !suspending.contains(sandboxId), !checkpointing.contains(sandboxId) else { return .busy }
        var admission = SandboxIdleSuspensionAdmission()
        let verdict = admission.prepare(
            policy: policy, evidence: idleSuspensionEvidence(sandboxId: sandboxId), at: Date())
        if verdict == .eligible {
            idleSuspensionAdmissions[sandboxId] = admission
        } else {
            idleSuspensionAdmissions.removeValue(forKey: sandboxId)
        }
        return verdict
    }
}
#endif
