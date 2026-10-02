import Foundation
import Testing
@testable import StratoAgentCore

@Suite("Lazy restore candidate evidence rejection")
struct SandboxLazyMemoryCapabilityTests {
    private let now = Date(timeIntervalSince1970: 10000)
    private func scope(boot: UUID = UUID(), agentSession: UUID = UUID()) -> SandboxLazyMemoryProofScope {
        .init(
            firecrackerDigest: String(repeating: "a", count: 64), kernelBootID: boot, agentSessionID: agentSession,
            isolationDigest: String(repeating: "b", count: 64),
            snapshotCompatibilityDigest: String(repeating: "c", count: 64), trustClass: "fixture")
    }
    private func proof(
        scope: SandboxLazyMemoryProofScope, origin: SandboxLazyMemoryProof.Origin = .liveRunner,
        expiry: Date? = nil, checks: Set<SandboxLazyMemoryProof.Check>? = nil
    ) -> SandboxLazyMemoryProof {
        .init(
            origin: origin, scope: scope, observedAt: now.addingTimeInterval(-1),
            expiresAt: expiry ?? now.addingTimeInterval(60),
            evidenceDigest: String(repeating: "d", count: 64),
            checks: checks ?? Set(SandboxLazyMemoryProof.Check.allCases))
    }
    @Test func rejectsMissingMockExpiredAndRebootEvidence() throws {
        let scope = scope()
        #expect(throws: SandboxLazyMemoryCapabilityProof.Rejection.missing) {
            try SandboxLazyMemoryCapabilityProof.validateCandidate(nil, scope: scope, now: now)
        }
        #expect(throws: SandboxLazyMemoryCapabilityProof.Rejection.fixture) {
            try SandboxLazyMemoryCapabilityProof.validateCandidate(
                proof(scope: scope, origin: .fixture), scope: scope, now: now)
        }
        #expect(throws: SandboxLazyMemoryCapabilityProof.Rejection.expired) {
            try SandboxLazyMemoryCapabilityProof.validateCandidate(
                proof(scope: scope, expiry: now), scope: scope, now: now)
        }
        #expect(throws: SandboxLazyMemoryCapabilityProof.Rejection.scopeMismatch) {
            try SandboxLazyMemoryCapabilityProof.validateCandidate(proof(scope: scope), scope: self.scope(), now: now)
        }
    }
    @Test func rejectsAgentRestartBadDigestsAndUnboundedLifetime() throws {
        let scope = scope()
        let restarted = self.scope(boot: scope.kernelBootID)
        #expect(throws: SandboxLazyMemoryCapabilityProof.Rejection.scopeMismatch) {
            try SandboxLazyMemoryCapabilityProof.validateCandidate(proof(scope: scope), scope: restarted, now: now)
        }
        let invalid = SandboxLazyMemoryProofScope(
            firecrackerDigest: "kernel-version-is-not-a-digest",
            kernelBootID: scope.kernelBootID, agentSessionID: scope.agentSessionID,
            isolationDigest: scope.isolationDigest, snapshotCompatibilityDigest: scope.snapshotCompatibilityDigest,
            trustClass: scope.trustClass)
        #expect(throws: SandboxLazyMemoryCapabilityProof.Rejection.malformed) {
            try SandboxLazyMemoryCapabilityProof.validateCandidate(proof(scope: invalid), scope: invalid, now: now)
        }
        #expect(throws: SandboxLazyMemoryCapabilityProof.Rejection.expired) {
            try SandboxLazyMemoryCapabilityProof.validateCandidate(
                proof(scope: scope, expiry: now.addingTimeInterval(3601)), scope: scope, now: now)
        }
    }

    @Test func everyRuntimeProofRequiredAndProductionStillDisabled() throws {
        let scope = scope()
        for check in SandboxLazyMemoryProof.Check.allCases {
            var checks = Set(SandboxLazyMemoryProof.Check.allCases)
            checks.remove(check)
            #expect(throws: SandboxLazyMemoryCapabilityProof.Rejection.incomplete) {
                try SandboxLazyMemoryCapabilityProof.validateCandidate(
                    proof(scope: scope, checks: checks), scope: scope, now: now)
            }
        }
        // This synthetically complete receipt tests only evaluator semantics.
        // It is not evidence that this environment supports any runtime check.
        try SandboxLazyMemoryCapabilityProof.validateCandidate(proof(scope: scope), scope: scope, now: now)
        #expect(
            try SandboxRestoreMemoryPreparation.prepare(filePath: "memory").fallbackReason.contains("uffd-disabled"))
    }
}
