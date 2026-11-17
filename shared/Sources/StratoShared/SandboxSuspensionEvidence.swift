import Foundation
import SwiftProtobuf

/// Authenticated owner evidence; no filesystem path or arbitrary artifact name crosses the wire.
public typealias SandboxSuspensionEvidence = Strato_Agent_V1_SandboxSuspensionEvidence
extension Strato_Agent_V1_SandboxSuspensionEvidence: Codable {

    public init(
        checkpointId: UUID, generation: Int64, storageBytes: Int64,
        vmmDestroyed: Bool, verified: Bool, restoreDurationMilliseconds: Int64? = nil
    ) {
        self.init()
        self._jsonCheckpointId = checkpointId
        self._jsonGeneration = generation
        self._jsonStorageBytes = storageBytes
        self._jsonVmmDestroyed = vmmDestroyed
        self._jsonVerified = verified
        self._jsonRestoreDurationMilliseconds = restoreDurationMilliseconds
    }

    public func permitsComputeRelease(
        for observation: ObservedSandboxState, desiredGeneration: Int64,
        desiredStatus: DesiredSandboxStatus, admittedBytes: Int64
    ) -> Bool {
        _jsonVerified && _jsonVmmDestroyed && _jsonStorageBytes > 0 && _jsonStorageBytes <= admittedBytes
            && _jsonGeneration == desiredGeneration && observation._jsonObservedGeneration == desiredGeneration
            && desiredStatus == .suspended && observation._jsonStatus == .suspended
            && observation._jsonConvergencePhase == nil && observation._jsonLastError == nil
            && observation._jsonFailedGeneration != desiredGeneration
    }

    private enum CodingKeys: String, CodingKey {
        case checkpointId; case generation; case storageBytes; case vmmDestroyed; case verified;
        case restoreDurationMilliseconds
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonCheckpointId = try container.decode(UUID.self, forKey: .checkpointId)
        self._jsonGeneration = try container.decode(Int64.self, forKey: .generation)
        self._jsonStorageBytes = try container.decode(Int64.self, forKey: .storageBytes)
        self._jsonVmmDestroyed = try container.decode(Bool.self, forKey: .vmmDestroyed)
        self._jsonVerified = try container.decode(Bool.self, forKey: .verified)
        self._jsonRestoreDurationMilliseconds = try container.decodeIfPresent(
            Int64.self, forKey: .restoreDurationMilliseconds)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonCheckpointId, forKey: .checkpointId)
        try container.encode(_jsonGeneration, forKey: .generation)
        try container.encode(_jsonStorageBytes, forKey: .storageBytes)
        try container.encode(_jsonVmmDestroyed, forKey: .vmmDestroyed)
        try container.encode(_jsonVerified, forKey: .verified)
        try container.encodeIfPresent(_jsonRestoreDurationMilliseconds, forKey: .restoreDurationMilliseconds)
    }

}
