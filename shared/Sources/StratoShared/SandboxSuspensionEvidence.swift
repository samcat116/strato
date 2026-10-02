import Foundation

/// Authenticated owner evidence; no filesystem path or arbitrary artifact name crosses the wire.
public struct SandboxSuspensionEvidence: Codable, Equatable, Sendable {
    public let checkpointId: UUID
    public let generation: Int64
    public let storageBytes: Int64
    public let vmmDestroyed: Bool
    public let verified: Bool
    public let restoreDurationMilliseconds: Int64?

    public init(
        checkpointId: UUID, generation: Int64, storageBytes: Int64,
        vmmDestroyed: Bool, verified: Bool, restoreDurationMilliseconds: Int64? = nil
    ) {
        self.checkpointId = checkpointId
        self.generation = generation
        self.storageBytes = storageBytes
        self.vmmDestroyed = vmmDestroyed
        self.verified = verified
        self.restoreDurationMilliseconds = restoreDurationMilliseconds
    }

    public func permitsComputeRelease(
        for observation: ObservedSandboxState, desiredGeneration: Int64,
        desiredStatus: DesiredSandboxStatus, admittedBytes: Int64
    ) -> Bool {
        verified && vmmDestroyed && storageBytes > 0 && storageBytes <= admittedBytes
            && generation == desiredGeneration && observation.observedGeneration == desiredGeneration
            && desiredStatus == .suspended && observation.status == .suspended
            && observation.convergencePhase == nil && observation.lastError == nil
            && observation.failedGeneration != desiredGeneration
    }
}
