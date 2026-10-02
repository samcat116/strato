import Foundation
import Logging
import StratoAgentCore
import StratoShared
import Testing

@Suite("automatic suspension eligibility and lifecycle fence")
struct SandboxIdleSuspensionAdmissionTests {
    let now = Date(timeIntervalSince1970: 10_000)

    func policy() -> SandboxIdlePolicy {
        var policy = SandboxIdlePolicy()
        policy.enabled = true
        return policy
    }

    func evidence() -> SandboxIdlePolicy.Evidence {
        .init(
            sandboxID: UUID(), agentIncarnation: UUID(), activityGeneration: 0,
            observedAt: now, lastActiveAt: now.addingTimeInterval(-600),
            residentSince: now.addingTimeInterval(-600), supportsFullSnapshot: true,
            activeSessions: 0, pendingCommands: 0, snapshotOrRestoreInProgress: false,
            guestAndNetworkActivityKnown: true)
    }

    @Test func missingPreparedClaimAndMissingSourcesCannotDestroy() {
        var admission = SandboxIdleSuspensionAdmission()
        let sample = evidence()
        #expect(!admission.permitsDestruction(evidence: sample, at: now))
        #expect(admission.prepare(policy: policy(), evidence: nil, at: now) == .unknownActivity)
        #expect(!admission.permitsDestruction(evidence: sample, at: now))
        #expect(admission.prepare(policy: SandboxIdlePolicy(), evidence: sample, at: now) == .disabled)
        #expect(!admission.permitsDestruction(evidence: sample, at: now))
    }

    @Test func idleClaimCannotOutliveSignalCoverageOrFreshness() {
        var admission = SandboxIdleSuspensionAdmission()
        let sample = evidence()
        #expect(admission.prepare(policy: policy(), evidence: sample, at: now) == .eligible)
        #expect(admission.permitsDestruction(evidence: sample, at: now))
        #expect(!admission.permitsDestruction(evidence: nil, at: now))
        #expect(!admission.permitsDestruction(evidence: sample, at: now.addingTimeInterval(31)))
        var current = sample
        current.activeSessions = nil
        #expect(!admission.permitsDestruction(evidence: current, at: now))
        current = sample
        current.guestAndNetworkActivityKnown = false
        #expect(!admission.permitsDestruction(evidence: current, at: now))
    }

    @Test func pendingHandshakeBeforeFirstAwaitInvalidatesBothGuards() throws {
        var lifecycle = SandboxSuspensionGuard()
        lifecycle.updateIntent(generation: 4, desiredRunning: true)
        var admission = SandboxIdleSuspensionAdmission()
        var sample = evidence()
        sample.activityGeneration = lifecycle.activityEpoch
        #expect(admission.prepare(policy: policy(), evidence: sample, at: now) == .eligible)
        let ticket = try lifecycle.beginSuspension(generation: 4, automatic: true)
        let pending = lifecycle.beginActivity()
        sample.activityGeneration = lifecycle.activityEpoch
        sample.pendingCommands = lifecycle.pendingActivityCount
        #expect(!admission.permitsDestruction(evidence: sample, at: now))
        #expect(throws: SandboxSuspensionGuard.GateError.stale) {
            try lifecycle.commitDestruction(ticket)
        }
        lifecycle.endActivity(pending)
        sample.pendingCommands = 0
        #expect(!admission.permitsDestruction(evidence: sample, at: now))
        lifecycle.finish(ticket)
    }

    @Test func activityAfterDestructionUsesExistingLifecycleRestoreVerdict() throws {
        var lifecycle = SandboxSuspensionGuard()
        lifecycle.updateIntent(generation: 4, desiredRunning: true)
        var admission = SandboxIdleSuspensionAdmission()
        var sample = evidence()
        sample.activityGeneration = lifecycle.activityEpoch
        #expect(admission.prepare(policy: policy(), evidence: sample, at: now) == .eligible)
        let ticket = try lifecycle.beginSuspension(generation: 4, automatic: true)
        #expect(admission.permitsDestruction(evidence: sample, at: now))
        try lifecycle.commitDestruction(ticket)
        let pending = lifecycle.beginActivity()
        #expect(lifecycle.needsRestore(after: ticket))
        lifecycle.endActivity(pending)
        #expect(lifecycle.needsRestore(after: ticket))
        lifecycle.finish(ticket)
    }

    @Test func userStreamsBusyBackendsAndConcurrentSnapshotsDoNotPrepare() {
        for exclusion in 0..<5 {
            var sample = evidence()
            switch exclusion {
            case 0: sample.activeSessions = 1
            case 1: sample.pendingCommands = 1
            case 2: sample.snapshotOrRestoreInProgress = true
            case 3: sample.supportsFullSnapshot = false
            default: sample.guestAndNetworkActivityKnown = false
            }
            var admission = SandboxIdleSuspensionAdmission()
            #expect(admission.prepare(policy: policy(), evidence: sample, at: now) != .eligible)
            #expect(!admission.permitsDestruction(evidence: evidence(), at: now))
        }
    }

    @Test func reconnectRestartAndRestoreResidencyInvalidateClaims() {
        var admission = SandboxIdleSuspensionAdmission()
        let sample = evidence()
        #expect(admission.prepare(policy: policy(), evidence: sample, at: now) == .eligible)
        var current = sample
        current.agentIncarnation = UUID()
        #expect(!admission.permitsDestruction(evidence: current, at: now))
        current = sample
        current.residentSince = now
        #expect(!admission.permitsDestruction(evidence: current, at: now))
        // The runtime clears claims and observations on reconnect; even a new
        // quiet report cannot reuse the previous incarnation's prepared claim.
        admission = SandboxIdleSuspensionAdmission()
        #expect(!admission.permitsDestruction(evidence: sample, at: now))
    }
}

@Suite("authoritative idle observation assembly")
struct SandboxIdleActivityObservationTests {
    let now = Date(timeIntervalSince1970: 10_000)

    func observation(streams: Int?) -> SandboxIdleActivityObservation {
        .init(
            observedAt: now, lastActiveAt: now.addingTimeInterval(-600),
            residentSince: now.addingTimeInterval(-600), activeUserStreams: streams, pendingUserCommands: 0,
            guestAndNetworkActivityKnown: true)
    }

    func evidence(
        streams: Int?, exec: Int = 0, pending: Int = 0, localActivity: Date? = nil
    ) -> SandboxIdlePolicy.Evidence {
        observation(streams: streams).evidence(
            sandboxID: UUID(), agentIncarnation: UUID(), activityGeneration: 0,
            lastLocalActivity: localActivity, activeExecSessions: exec, pendingCommands: pending,
            supportsFullSnapshot: true, snapshotOrRestoreInProgress: false)
    }

    func policy() -> SandboxIdlePolicy {
        var policy = SandboxIdlePolicy()
        policy.enabled = true
        return policy
    }

    @Test func onlyUserStreamsAndExecProtectQuietGuests() {
        // Internal log-follow state is deliberately not an input: a quiet
        // guest's automatic forwarding connection is not a user subscription.
        #expect(policy().evaluate(evidence(streams: 0), at: now) == .eligible)
        #expect(policy().evaluate(evidence(streams: 1), at: now) == .busy)
        #expect(policy().evaluate(evidence(streams: 0, exec: 1), at: now) == .busy)
        #expect(policy().evaluate(evidence(streams: 0, pending: 1), at: now) == .busy)
        #expect(policy().evaluate(evidence(streams: nil), at: now) == .unknownActivity)
    }

    @Test func localCommandArrivalCannotBeUndoneByOlderObservation() {
        #expect(policy().evaluate(evidence(streams: 0, localActivity: now), at: now) == .recentlyActive)
        #expect(
            policy().evaluate(evidence(streams: 0, localActivity: now.addingTimeInterval(1)), at: now)
                == .unknownActivity)
    }

    @Test func restoreResidencyCannotBeUndoneByOlderSourceTimestamp() {
        let sample = observation(streams: 0).evidence(
            sandboxID: UUID(), agentIncarnation: UUID(), activityGeneration: 0,
            lastLocalActivity: nil, localResidentSince: now,
            activeExecSessions: 0, pendingCommands: 0,
            supportsFullSnapshot: true, snapshotOrRestoreInProgress: false)
        #expect(sample.residentSince == now)
        #expect(policy().evaluate(sample, at: now) == .minimumResidency)
    }

    @Test func queuedControlPlaneCommandsRequireAnExplicitCoveredSignal() {
        for queued in [Int?.none, 1, -1, Int.max] {
            let observation = SandboxIdleActivityObservation(
                observedAt: now, lastActiveAt: now.addingTimeInterval(-600),
                residentSince: now.addingTimeInterval(-600), activeUserStreams: 0,
                pendingUserCommands: queued, guestAndNetworkActivityKnown: true)
            let sample = observation.evidence(
                sandboxID: UUID(), agentIncarnation: UUID(), activityGeneration: 0,
                lastLocalActivity: nil, activeExecSessions: 0, pendingCommands: 1,
                supportsFullSnapshot: true, snapshotOrRestoreInProgress: false)
            #expect(policy().evaluate(sample, at: now) != .eligible)
            if queued == nil || queued == -1 || queued == Int.max {
                #expect(sample.pendingCommands == nil)
            } else {
                #expect(sample.pendingCommands == 2)
            }
        }
    }

    @Test func invalidAndOverflowingCountersAreUnknown() {
        #expect(policy().evaluate(evidence(streams: -1), at: now) == .unknownActivity)
        #expect(policy().evaluate(evidence(streams: Int.max, exec: 1), at: now) == .unknownActivity)
        #expect(policy().evaluate(evidence(streams: 0, exec: -1), at: now) == .unknownActivity)
    }
}

@Suite("unsupported idle runtime")
struct UnsupportedSandboxIdleRuntimeTests {
    @Test func simulationCannotAuthorizeAutomaticReclamation() async {
        let runtime = MockSandboxRuntime(logger: .init(label: "unsupported-idle-runtime"))
        #expect(
            await runtime.prepareIdleSuspension(sandboxId: UUID().uuidString, policy: SandboxIdlePolicy()) == .disabled)
        var policy = SandboxIdlePolicy()
        policy.enabled = true
        #expect(
            await runtime.prepareIdleSuspension(sandboxId: UUID().uuidString, policy: policy) == .unsupportedBackend)
    }
}
