import Foundation
import SwiftProtobuf

/// STR-313 eligibility only. The suspended lifecycle owns checkpoint durability,
/// stopping, restoration, and artifact retention; this value never performs them.
public typealias SandboxIdlePolicy = Strato_Agent_V1_SandboxIdlePolicy
extension Strato_Agent_V1_SandboxIdlePolicy: Codable {

    public static var defaults: Self {
        .with { value in
            value.enabled = false
            value.idleSeconds = 300
            value.minimumResidencySeconds = 60
            value.maximumEvidenceAgeSeconds = 30
            value.restoreTimeoutSeconds = 120
            value.excludedSandboxIDs = .init()
        }
    }

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
            [
                _jsonIdleSeconds, _jsonMinimumResidencySeconds, _jsonMaximumEvidenceAgeSeconds,
                _jsonRestoreTimeoutSeconds,
            ]
            .allSatisfy({ $0.isFinite && $0 > 0 })
        else { return .invalidConfiguration }
        guard !_jsonExcludedSandboxIDs.contains(evidence.sandboxID) else { return .excluded }
        guard evidence.supportsFullSnapshot else { return .unsupportedBackend }
        guard evidence.guestAndNetworkActivityKnown,
            let sessions = evidence.activeSessions, sessions >= 0,
            let commands = evidence.pendingCommands, commands >= 0,
            let snapshotBusy = evidence.snapshotOrRestoreInProgress,
            evidence.observedAt <= now,
            now.timeIntervalSince(evidence.observedAt) <= _jsonMaximumEvidenceAgeSeconds,
            evidence.lastActiveAt <= evidence.observedAt,
            evidence.residentSince <= evidence.observedAt
        else { return .unknownActivity }
        guard sessions == 0, commands == 0, !snapshotBusy else { return .busy }
        guard now.timeIntervalSince(evidence.residentSince) >= _jsonMinimumResidencySeconds else {
            return .minimumResidency
        }
        guard now.timeIntervalSince(evidence.lastActiveAt) >= _jsonIdleSeconds else { return .recentlyActive }
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

    private enum CodingKeys: String, CodingKey {
        case enabled; case idleSeconds; case minimumResidencySeconds; case maximumEvidenceAgeSeconds;
        case restoreTimeoutSeconds; case excludedSandboxIDs
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decode(Bool.self, forKey: .enabled)
        self._jsonIdleSeconds = try container.decode(TimeInterval.self, forKey: .idleSeconds)
        self._jsonMinimumResidencySeconds = try container.decode(TimeInterval.self, forKey: .minimumResidencySeconds)
        self._jsonMaximumEvidenceAgeSeconds = try container.decode(
            TimeInterval.self, forKey: .maximumEvidenceAgeSeconds)
        self._jsonRestoreTimeoutSeconds = try container.decode(TimeInterval.self, forKey: .restoreTimeoutSeconds)
        self._jsonExcludedSandboxIDs = try container.decode(Set<UUID>.self, forKey: .excludedSandboxIDs)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(_jsonIdleSeconds, forKey: .idleSeconds)
        try container.encode(_jsonMinimumResidencySeconds, forKey: .minimumResidencySeconds)
        try container.encode(_jsonMaximumEvidenceAgeSeconds, forKey: .maximumEvidenceAgeSeconds)
        try container.encode(_jsonRestoreTimeoutSeconds, forKey: .restoreTimeoutSeconds)
        try container.encode(_jsonExcludedSandboxIDs, forKey: .excludedSandboxIDs)
    }

    var _jsonIdleSeconds: TimeInterval {
        get { idleSeconds }
        set { let value = newValue; idleSeconds = value }
    }
    var _jsonMinimumResidencySeconds: TimeInterval {
        get { minimumResidencySeconds }
        set { let value = newValue; minimumResidencySeconds = value }
    }
    var _jsonMaximumEvidenceAgeSeconds: TimeInterval {
        get { maximumEvidenceAgeSeconds }
        set { let value = newValue; maximumEvidenceAgeSeconds = value }
    }
    var _jsonRestoreTimeoutSeconds: TimeInterval {
        get { restoreTimeoutSeconds }
        set { let value = newValue; restoreTimeoutSeconds = value }
    }
    var _jsonExcludedSandboxIDs: Set<UUID> {
        get {
            Set(
                excludedSandboxIDs.values.map {
                    UUID(uuidString: $0) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
                })
        }
        set {
            let value = newValue;
            excludedSandboxIDs = Strato_Agent_V1_SandboxIdlePolicyExcludedSandboxIDsSection.with {
                $0.values = Array(value).map { $0.uuidString }
            }
        }
    }
}
