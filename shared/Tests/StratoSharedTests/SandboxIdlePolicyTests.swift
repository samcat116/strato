import Foundation
import Testing
import StratoShared

@Suite("Sandbox idle eligibility (STR-313)")
struct SandboxIdlePolicyTests {
    let now = Date(timeIntervalSince1970: 10_000)

    func evidence() -> SandboxIdlePolicy.Evidence {
        .init(
            sandboxID: UUID(), agentIncarnation: UUID(), activityGeneration: 1,
            observedAt: now, lastActiveAt: now.addingTimeInterval(-300),
            residentSince: now.addingTimeInterval(-600), supportsFullSnapshot: true,
            activeSessions: 0, pendingCommands: 0, snapshotOrRestoreInProgress: false,
            guestAndNetworkActivityKnown: true
        )
    }

    func policy() -> SandboxIdlePolicy {
        var policy = SandboxIdlePolicy()
        policy.enabled = true
        return policy
    }

    @Test func automaticReclamationRequiresExplicitEnablement() {
        #expect(SandboxIdlePolicy().evaluate(evidence(), at: now) == .disabled)
        #expect(policy().evaluate(evidence(), at: now) == .eligible)
    }

    @Test func clocksAreInclusiveAndSeparate() {
        var sample = evidence()
        sample.lastActiveAt = now.addingTimeInterval(-299)
        #expect(policy().evaluate(sample, at: now) == .recentlyActive)
        sample.lastActiveAt = now.addingTimeInterval(-300)
        sample.residentSince = now.addingTimeInterval(-59)
        #expect(policy().evaluate(sample, at: now) == .minimumResidency)
        sample.residentSince = now.addingTimeInterval(-60)
        #expect(policy().evaluate(sample, at: now) == .eligible)
    }

    @Test func exclusionsAndUnsupportedBackends() {
        var sample = evidence()
        var configuration = policy()
        configuration.excludedSandboxIDs.insert(sample.sandboxID)
        #expect(configuration.evaluate(sample, at: now) == .excluded)
        sample.supportsFullSnapshot = false
        #expect(policy().evaluate(sample, at: now) == .unsupportedBackend)
    }

    @Test func activeSessionsCommandsAndLifecycleWorkPreventSuspension() {
        var sample = evidence()
        sample.activeSessions = 1
        #expect(policy().evaluate(sample, at: now) == .busy)
        sample.activeSessions = 0
        sample.pendingCommands = 1
        #expect(policy().evaluate(sample, at: now) == .busy)
        sample.pendingCommands = 0
        sample.snapshotOrRestoreInProgress = true
        #expect(policy().evaluate(sample, at: now) == .busy)
    }

    @Test func absenceOfAnyAuthoritativeSignalIsUnknown() {
        var sample = evidence()
        sample.activeSessions = nil
        #expect(policy().evaluate(sample, at: now) == .unknownActivity)
        sample = evidence()
        sample.pendingCommands = nil
        #expect(policy().evaluate(sample, at: now) == .unknownActivity)
        sample = evidence()
        sample.snapshotOrRestoreInProgress = nil
        #expect(policy().evaluate(sample, at: now) == .unknownActivity)
        sample = evidence()
        sample.guestAndNetworkActivityKnown = false
        #expect(policy().evaluate(sample, at: now) == .unknownActivity)
    }

    @Test func staleFutureAndInvalidEvidenceCannotAuthorizeSuspension() {
        var sample = evidence()
        sample.observedAt = now.addingTimeInterval(-31)
        #expect(policy().evaluate(sample, at: now) == .unknownActivity)
        sample = evidence()
        sample.observedAt = now.addingTimeInterval(1)
        #expect(policy().evaluate(sample, at: now) == .unknownActivity)
        sample = evidence()
        sample.lastActiveAt = now.addingTimeInterval(1)
        #expect(policy().evaluate(sample, at: now) == .unknownActivity)
        sample = evidence()
        sample.activeSessions = -1
        #expect(policy().evaluate(sample, at: now) == .unknownActivity)
    }

    @Test func activityAndAgentRestartInvalidateCheckpointClaims() {
        let claimed = evidence()
        var current = claimed
        #expect(policy().canCommitSuspension(claimed: claimed, current: current, at: now))
        current.activityGeneration += 1
        #expect(!policy().canCommitSuspension(claimed: claimed, current: current, at: now))
        current = claimed
        current.agentIncarnation = UUID()
        #expect(!policy().canCommitSuspension(claimed: claimed, current: current, at: now))
        current = claimed
        current.pendingCommands = 1
        #expect(!policy().canCommitSuspension(claimed: claimed, current: current, at: now))
        current = claimed
        current.lastActiveAt = now
        #expect(!policy().canCommitSuspension(claimed: claimed, current: current, at: now))
    }

    @Test func invalidConfigurationFailsClosed() {
        for value in [0.0, -1, .infinity, .nan] {
            var configuration = policy()
            configuration.idleSeconds = value
            #expect(configuration.evaluate(evidence(), at: now) == .invalidConfiguration)
            configuration = policy()
            configuration.restoreTimeoutSeconds = value
            #expect(configuration.evaluate(evidence(), at: now) == .invalidConfiguration)
        }
    }
}
