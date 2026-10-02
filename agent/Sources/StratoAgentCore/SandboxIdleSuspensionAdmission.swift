import Foundation
import StratoShared

/// Trusted local observation, deliberately not a wire message. The sampler
/// must establish both guest/network coverage and user stream coverage; internal
/// log forwarding does not establish either and never increments user streams.
public struct SandboxIdleActivityObservation: Sendable {
    public let observedAt: Date
    public let lastActiveAt: Date
    public let residentSince: Date
    public let activeUserStreams: Int?
    public let pendingUserCommands: Int?
    public let guestAndNetworkActivityKnown: Bool

    public init(
        observedAt: Date, lastActiveAt: Date, residentSince: Date,
        activeUserStreams: Int?, pendingUserCommands: Int? = nil, guestAndNetworkActivityKnown: Bool
    ) {
        self.observedAt = observedAt
        self.lastActiveAt = lastActiveAt
        self.residentSince = residentSince
        self.activeUserStreams = activeUserStreams
        self.pendingUserCommands = pendingUserCommands
        self.guestAndNetworkActivityKnown = guestAndNetworkActivityKnown
    }

    public func evidence(
        sandboxID: UUID, agentIncarnation: UUID, activityGeneration: UInt64,
        lastLocalActivity: Date?, localResidentSince: Date? = nil,
        activeExecSessions: Int, pendingCommands: Int,
        supportsFullSnapshot: Bool, snapshotOrRestoreInProgress: Bool
    ) -> SandboxIdlePolicy.Evidence {
        let sessions: Int?
        if let streams = activeUserStreams, streams >= 0, activeExecSessions >= 0,
            streams <= Int.max - activeExecSessions
        {
            sessions = streams + activeExecSessions
        } else {
            sessions = nil
        }
        let commands: Int?
        if let queued = pendingUserCommands, queued >= 0, pendingCommands >= 0,
            queued <= Int.max - pendingCommands
        {
            commands = queued + pendingCommands
        } else {
            commands = nil
        }
        return .init(
            sandboxID: sandboxID, agentIncarnation: agentIncarnation,
            activityGeneration: activityGeneration, observedAt: observedAt,
            lastActiveAt: max(lastActiveAt, lastLocalActivity ?? lastActiveAt),
            residentSince: max(residentSince, localResidentSince ?? residentSince),
            supportsFullSnapshot: supportsFullSnapshot,
            activeSessions: sessions, pendingCommands: commands,
            snapshotOrRestoreInProgress: snapshotOrRestoreInProgress,
            guestAndNetworkActivityKnown: guestAndNetworkActivityKnown)
    }

}

/// Eligibility claim only. STR-312's suspension guard still owns command
/// admission and the atomic destruction commit. Stored evidence is never
/// restored from a journal: restart/reconnect starts with unknown activity.
public struct SandboxIdleSuspensionAdmission: Sendable {
    private var policy = SandboxIdlePolicy()
    private var claimed: SandboxIdlePolicy.Evidence?

    public init() {}

    public mutating func prepare(
        policy: SandboxIdlePolicy, evidence: SandboxIdlePolicy.Evidence?, at now: Date
    ) -> SandboxIdlePolicy.Verdict {
        self.policy = policy
        claimed = nil
        guard policy.enabled else { return .disabled }
        guard let evidence else { return .unknownActivity }
        let verdict = policy.evaluate(evidence, at: now)
        if verdict == .eligible { claimed = evidence }
        return verdict
    }

    /// Only used after STR-312 proves a prepared v5 freeze and validates CP
    /// ownership. Snapshot time is not new workload activity; epochs still bind.
    public func permitsFrozenDestruction(evidence: SandboxIdlePolicy.Evidence?) -> Bool {
        guard let claimed, let evidence else { return false }
        return claimed.sandboxID == evidence.sandboxID && claimed.agentIncarnation == evidence.agentIncarnation
            && claimed.activityGeneration == evidence.activityGeneration
            && claimed.lastActiveAt == evidence.lastActiveAt && claimed.residentSince == evidence.residentSince
            && evidence.activeSessions == 0 && evidence.pendingCommands == 0
            && evidence.guestAndNetworkActivityKnown
    }

    public func permitsDestruction(evidence: SandboxIdlePolicy.Evidence?, at now: Date) -> Bool {
        guard let claimed, let evidence else { return false }
        return policy.canCommitSuspension(claimed: claimed, current: evidence, at: now)
    }
}
