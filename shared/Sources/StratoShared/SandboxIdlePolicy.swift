import Foundation

/// STR-313 eligibility only. The suspended lifecycle owns checkpoint durability,
/// stopping, restoration, and artifact retention; this value never performs them.
public struct SandboxIdlePolicy: Sendable, Equatable {
    public var enabled = false
    public var idleSeconds: TimeInterval = 300
    public var minimumResidencySeconds: TimeInterval = 60
    public var maximumEvidenceAgeSeconds: TimeInterval = 30
    public var restoreTimeoutSeconds: TimeInterval = 120
    public var excludedSandboxIDs: Set<UUID> = []

    public init() {}

    public enum Verdict: Sendable, Equatable {
        case disabled, invalidConfiguration, excluded, unsupportedBackend
        case unknownActivity, busy, minimumResidency, recentlyActive, eligible
    }

    /// Evidence must cover the guest and network, not merely control-plane API
    /// traffic. Producers leave unknown counters/signals nil after reconnect or
    /// restart until they can authoritatively measure the current guest.
    public struct Evidence: Sendable, Equatable {
        public var sandboxID: UUID
        public var agentIncarnation: UUID
        public var activityGeneration: UInt64
        public var observedAt: Date
        public var lastActiveAt: Date
        public var residentSince: Date
        public var supportsFullSnapshot: Bool
        public var activeSessions: Int?
        public var pendingCommands: Int?
        public var snapshotOrRestoreInProgress: Bool?
        public var guestAndNetworkActivityKnown: Bool

        public init(
            sandboxID: UUID, agentIncarnation: UUID, activityGeneration: UInt64,
            observedAt: Date, lastActiveAt: Date, residentSince: Date,
            supportsFullSnapshot: Bool, activeSessions: Int?, pendingCommands: Int?,
            snapshotOrRestoreInProgress: Bool?, guestAndNetworkActivityKnown: Bool
        ) {
            self.sandboxID = sandboxID
            self.agentIncarnation = agentIncarnation
            self.activityGeneration = activityGeneration
            self.observedAt = observedAt
            self.lastActiveAt = lastActiveAt
            self.residentSince = residentSince
            self.supportsFullSnapshot = supportsFullSnapshot
            self.activeSessions = activeSessions
            self.pendingCommands = pendingCommands
            self.snapshotOrRestoreInProgress = snapshotOrRestoreInProgress
            self.guestAndNetworkActivityKnown = guestAndNetworkActivityKnown
        }
    }

    public func evaluate(_ evidence: Evidence, at now: Date) -> Verdict {
        guard enabled else { return .disabled }
        guard
            [idleSeconds, minimumResidencySeconds, maximumEvidenceAgeSeconds, restoreTimeoutSeconds]
                .allSatisfy({ $0.isFinite && $0 > 0 })
        else { return .invalidConfiguration }
        guard !excludedSandboxIDs.contains(evidence.sandboxID) else { return .excluded }
        guard evidence.supportsFullSnapshot else { return .unsupportedBackend }
        guard evidence.guestAndNetworkActivityKnown,
            let sessions = evidence.activeSessions, sessions >= 0,
            let commands = evidence.pendingCommands, commands >= 0,
            let snapshotBusy = evidence.snapshotOrRestoreInProgress,
            evidence.observedAt <= now,
            now.timeIntervalSince(evidence.observedAt) <= maximumEvidenceAgeSeconds,
            evidence.lastActiveAt <= evidence.observedAt,
            evidence.residentSince <= evidence.observedAt
        else { return .unknownActivity }
        guard sessions == 0, commands == 0, !snapshotBusy else { return .busy }
        guard now.timeIntervalSince(evidence.residentSince) >= minimumResidencySeconds else {
            return .minimumResidency
        }
        guard now.timeIntervalSince(evidence.lastActiveAt) >= idleSeconds else { return .recentlyActive }
        return .eligible
    }

    /// Invoke at the checkpoint/stop boundary under the lifecycle's command
    /// admission guard. A successful result alone is not a lock: new commands
    /// must invalidate the claim before admission can release that guard.
    public func canCommitSuspension(
        claimed: Evidence, current: Evidence, at now: Date
    ) -> Bool {
        claimed.sandboxID == current.sandboxID
            && claimed.agentIncarnation == current.agentIncarnation
            && claimed.activityGeneration == current.activityGeneration
            && claimed.lastActiveAt == current.lastActiveAt
            && claimed.residentSince == current.residentSince
            && evaluate(claimed, at: claimed.observedAt) == .eligible
            && evaluate(current, at: now) == .eligible
    }
}
