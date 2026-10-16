import Foundation
import Testing
@testable import StratoShared

@Suite("Sandbox suspension wire contract")
struct SandboxSuspensionEvidenceTests {
    @Test func distinctGoalRequiresDestroyedState() {
        #expect(!DesiredSandboxStatus.suspended.isSatisfied(by: .stopped))
        #expect(!DesiredSandboxStatus.suspended.isSatisfied(by: .running))
        #expect(!DesiredSandboxStatus.suspended.isSatisfied(by: .exited))
        #expect(DesiredSandboxStatus.suspended.isSatisfied(by: .suspended))
        #expect(!DesiredSandboxStatus.running.isSatisfied(by: .suspended))
    }

    @Test(arguments: [
        "valid", "old", "future", "running", "paused", "failure", "progress", "unverified", "alive", "oversize",
        "empty", "newIntent",
    ])
    func releaseRequiresCurrentDurableOwnerEvidence(_ scenario: String) {
        let evidence = SandboxSuspensionEvidence(
            checkpointId: UUID(), generation: scenario == "old" ? 3 : scenario == "future" ? 5 : 4,
            storageBytes: scenario == "empty" ? 0 : scenario == "oversize" ? 101 : 100,
            vmmDestroyed: scenario != "alive", verified: scenario != "unverified")
        let report = ObservedSandboxState(
            sandboxId: UUID(), status: scenario == "running" ? .running : scenario == "paused" ? .stopped : .suspended,
            observedGeneration: 4, convergencePhase: scenario == "progress" ? "destroying" : nil,
            failedGeneration: scenario == "failure" ? 4 : nil, suspension: evidence)
        #expect(
            evidence.permitsComputeRelease(
                for: report, desiredGeneration: 4,
                desiredStatus: scenario == "newIntent" ? .running : .suspended, admittedBytes: 100)
                == (scenario == "valid"))
    }

    @Test func evidenceAndBudgetSurviveWireRoundTrip() throws {
        let evidence = SandboxSuspensionEvidence(
            checkpointId: UUID(), generation: 8, storageBytes: 100,
            vmmDestroyed: true, verified: true, restoreDurationMilliseconds: 123)
        let report = ObservedSandboxState(
            sandboxId: UUID(), status: .suspended, observedGeneration: 8,
            suspension: evidence, suspensionStorageEstimateBytes: 120)
        let decoded = try WireProtocol.makeDecoder().decode(
            ObservedSandboxState.self,
            from: WireProtocol.makeEncoder().encode(report))
        #expect(decoded.suspension == evidence)
        #expect(decoded.suspensionStorageEstimateBytes == 120)
    }
}
