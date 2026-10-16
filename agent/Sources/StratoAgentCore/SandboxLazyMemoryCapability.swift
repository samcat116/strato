import Foundation

/// Compatibility scope for a future live restore receipt. This local type does
/// not change shared schemas. Digests bind the binary, kernel boot, seccomp/jail,
/// snapshot/CPU class and explicit trust class
// strings alone grant no support.
struct SandboxLazyMemoryProofScope: Codable, Sendable, Equatable {
    let firecrackerDigest: String
    let kernelBootID: UUID
    let agentSessionID: UUID
    let isolationDigest: String
    let snapshotCompatibilityDigest: String
    let trustClass: String
}

/// Only the future live runner may produce usable receipts. Persisted/mocked
/// receipts are untrusted until revalidated after agent restart. No production
/// runner exists yet and File-only selection does not consult this evaluator.
struct SandboxLazyMemoryProof: Sendable {
    enum Origin: Sendable { case fixture, liveRunner }
    enum Check: String, CaseIterable, Sendable {
        case kernelFaultAPI, eventRemove, registeredCopy, descriptorPeerAndLayout
        case snapshotLoadAndGuestRead, privateGuestWrite, cleanGuestSharingPSS
        case handlerFailureIsolation, cancellationCleanup, fileFallback, restartRecovery
    }
    let origin: Origin
    let scope: SandboxLazyMemoryProofScope
    let observedAt: Date
    let expiresAt: Date
    let evidenceDigest: String
    let checks: Set<Check>
}

enum SandboxLazyMemoryCapabilityProof {
    enum Rejection: Error, Equatable { case missing, fixture, scopeMismatch, expired, malformed, incomplete }

    /// Validates a candidate receipt, not a health advertisement. Activation
    /// remains blocked separately by absent transport and lifecycle guarantees.
    static func validateCandidate(_ proof: SandboxLazyMemoryProof?, scope: SandboxLazyMemoryProofScope, now: Date)
        throws
    {
        guard let proof else { throw Rejection.missing }
        guard proof.origin == .liveRunner else { throw Rejection.fixture }
        guard proof.scope == scope else { throw Rejection.scopeMismatch }
        guard proof.observedAt <= now, proof.expiresAt > now,
            proof.expiresAt.timeIntervalSince(proof.observedAt) > 0,
            proof.expiresAt.timeIntervalSince(proof.observedAt) <= 3600
        else { throw Rejection.expired }
        for digest in [
            scope.firecrackerDigest, scope.isolationDigest, scope.snapshotCompatibilityDigest, proof.evidenceDigest,
        ] {
            guard digest.utf8.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else {
                throw Rejection.malformed
            }
        }
        guard !scope.trustClass.isEmpty, scope.trustClass.utf8.count <= 256 else { throw Rejection.malformed }
        guard proof.checks == Set(SandboxLazyMemoryProof.Check.allCases) else { throw Rejection.incomplete }
    }
}
