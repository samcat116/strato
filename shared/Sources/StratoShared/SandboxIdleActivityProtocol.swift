import Foundation
import SwiftProtobuf

/// Wire 69 policy provenance. Missing provenance remains an explicit/manual
/// lifecycle request; malformed automatic provenance must never become manual.
public typealias SandboxAutomaticSuspensionFence = Strato_Agent_V1_SandboxAutomaticSuspensionFence
extension Strato_Agent_V1_SandboxAutomaticSuspensionFence: Codable {

    public init(
        operationId: UUID, generation: Int64, activityRevision: Int64, admissionToken: UUID,
        guestProtocolVersion: Int
    ) {
        self.init()
        self._jsonOperationId = operationId
        self._jsonGeneration = generation
        self._jsonActivityRevision = activityRevision
        self._jsonAdmissionToken = admissionToken
        self._jsonGuestProtocolVersion = guestProtocolVersion
    }

    public var isValid: Bool {
        _jsonGeneration > 0 && _jsonActivityRevision >= 0
            && _jsonGuestProtocolVersion == SandboxGuestControlProtocol.idlePolicyVersion
    }

    private enum CodingKeys: String, CodingKey {
        case operationId; case generation; case activityRevision; case admissionToken; case guestProtocolVersion
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonOperationId = try container.decode(UUID.self, forKey: .operationId)
        self._jsonGeneration = try container.decode(Int64.self, forKey: .generation)
        self._jsonActivityRevision = try container.decode(Int64.self, forKey: .activityRevision)
        self._jsonAdmissionToken = try container.decode(UUID.self, forKey: .admissionToken)
        self._jsonGuestProtocolVersion = try container.decode(Int.self, forKey: .guestProtocolVersion)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonOperationId, forKey: .operationId)
        try container.encode(_jsonGeneration, forKey: .generation)
        try container.encode(_jsonActivityRevision, forKey: .activityRevision)
        try container.encode(_jsonAdmissionToken, forKey: .admissionToken)
        try container.encode(_jsonGuestProtocolVersion, forKey: .guestProtocolVersion)
    }

}

/// Actual guest v5 evidence. This has the guest's snake-case JSON spelling,
/// including when relayed in the agent report. Unknown fields never mean zero.
public typealias SandboxGuestIdleActivity = Strato_Agent_V1_SandboxGuestIdleActivity
extension Strato_Agent_V1_SandboxGuestIdleActivity: Codable {
    public typealias Coverage = Strato_Agent_V1_SandboxGuestIdleCoverage

    public init(
        sandboxId: String, nonce: String, probeId: UUID, monitorIncarnation: UUID,
        sampleSequence: UInt64, activityEpoch: UInt64, quietForMilliseconds: UInt64?,
        coverage: Coverage, trusted: Bool, activeExecSessionIds: [UUID]?, anonymousExecCount: UInt32?,
        pendingExecCount: UInt32?, workloadCpuMicroseconds: UInt64?, workloadReadBytes: UInt64?,
        workloadWriteBytes: UInt64?, externalSocketCount: UInt32?, nicCount: UInt32?
    ) {
        self.init()
        self._jsonSandboxId = sandboxId; self._jsonNonce = nonce; self._jsonProbeId = probeId
        self._jsonMonitorIncarnation = monitorIncarnation; self._jsonSampleSequence = sampleSequence
        self._jsonActivityEpoch = activityEpoch; self._jsonQuietForMilliseconds = quietForMilliseconds
        self._jsonCoverage = coverage; self._jsonTrusted = trusted;
        self._jsonActiveExecSessionIds = activeExecSessionIds
        self._jsonAnonymousExecCount = anonymousExecCount; self._jsonPendingExecCount = pendingExecCount
        self._jsonWorkloadCpuMicroseconds = workloadCpuMicroseconds; self._jsonWorkloadReadBytes = workloadReadBytes
        self._jsonWorkloadWriteBytes = workloadWriteBytes; self._jsonExternalSocketCount = externalSocketCount;
        self._jsonNicCount = nicCount
    }

    public var hasCompleteQuiescentCoverage: Bool {
        _jsonCoverage == .complete && _jsonTrusted && _jsonNicCount == 0 && _jsonExternalSocketCount == 0
            && _jsonAnonymousExecCount == 0 && _jsonPendingExecCount == 0 && _jsonActiveExecSessionIds?.isEmpty == true
            && _jsonWorkloadCpuMicroseconds != nil && _jsonWorkloadReadBytes != nil && _jsonWorkloadWriteBytes != nil
            && _jsonQuietForMilliseconds.map { $0 <= 86_400_000 } == true && isBounded
    }

    public var isBounded: Bool {
        _jsonSandboxId.utf8.count <= 256 && _jsonNonce.utf8.count <= 256
            && !_jsonSandboxId.isEmpty && !_jsonNonce.isEmpty
            && _jsonSampleSequence > 0 && _jsonSampleSequence <= UInt64(Int64.max)
            && _jsonActivityEpoch <= UInt64(Int64.max)
            && (_jsonActiveExecSessionIds.map { $0.count <= 4096 && Set($0).count == $0.count } ?? true)
    }

    enum CodingKeys: String, CodingKey {
        case sandboxId = "sandbox_id", nonce, probeId = "probe_id", monitorIncarnation = "monitor_incarnation"
        case sampleSequence = "sample_sequence", activityEpoch = "activity_epoch", quietForMilliseconds =
            "quiet_for_milliseconds"
        case coverage, trusted, activeExecSessionIds = "active_exec_session_ids", anonymousExecCount =
            "anonymous_exec_count"
        case pendingExecCount = "pending_exec_count", workloadCpuMicroseconds = "workload_cpu_microseconds"
        case workloadReadBytes = "workload_read_bytes", workloadWriteBytes = "workload_write_bytes"
        case externalSocketCount = "external_socket_count", nicCount = "nic_count"
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonSandboxId = try container.decode(String.self, forKey: .sandboxId)
        self._jsonNonce = try container.decode(String.self, forKey: .nonce)
        self._jsonProbeId = try container.decode(UUID.self, forKey: .probeId)
        self._jsonMonitorIncarnation = try container.decode(UUID.self, forKey: .monitorIncarnation)
        self._jsonSampleSequence = try container.decode(UInt64.self, forKey: .sampleSequence)
        self._jsonActivityEpoch = try container.decode(UInt64.self, forKey: .activityEpoch)
        self._jsonQuietForMilliseconds = try container.decodeIfPresent(UInt64.self, forKey: .quietForMilliseconds)
        self._jsonCoverage = try container.decode(Coverage.self, forKey: .coverage)
        self._jsonTrusted = try container.decode(Bool.self, forKey: .trusted)
        self._jsonActiveExecSessionIds = try container.decodeIfPresent([UUID].self, forKey: .activeExecSessionIds)
        self._jsonAnonymousExecCount = try container.decodeIfPresent(UInt32.self, forKey: .anonymousExecCount)
        self._jsonPendingExecCount = try container.decodeIfPresent(UInt32.self, forKey: .pendingExecCount)
        self._jsonWorkloadCpuMicroseconds = try container.decodeIfPresent(UInt64.self, forKey: .workloadCpuMicroseconds)
        self._jsonWorkloadReadBytes = try container.decodeIfPresent(UInt64.self, forKey: .workloadReadBytes)
        self._jsonWorkloadWriteBytes = try container.decodeIfPresent(UInt64.self, forKey: .workloadWriteBytes)
        self._jsonExternalSocketCount = try container.decodeIfPresent(UInt32.self, forKey: .externalSocketCount)
        self._jsonNicCount = try container.decodeIfPresent(UInt32.self, forKey: .nicCount)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonSandboxId, forKey: .sandboxId)
        try container.encode(_jsonNonce, forKey: .nonce)
        try container.encode(_jsonProbeId, forKey: .probeId)
        try container.encode(_jsonMonitorIncarnation, forKey: .monitorIncarnation)
        try container.encode(_jsonSampleSequence, forKey: .sampleSequence)
        try container.encode(_jsonActivityEpoch, forKey: .activityEpoch)
        try container.encodeIfPresent(_jsonQuietForMilliseconds, forKey: .quietForMilliseconds)
        try container.encode(_jsonCoverage, forKey: .coverage)
        try container.encode(_jsonTrusted, forKey: .trusted)
        try container.encodeIfPresent(_jsonActiveExecSessionIds, forKey: .activeExecSessionIds)
        try container.encodeIfPresent(_jsonAnonymousExecCount, forKey: .anonymousExecCount)
        try container.encodeIfPresent(_jsonPendingExecCount, forKey: .pendingExecCount)
        try container.encodeIfPresent(_jsonWorkloadCpuMicroseconds, forKey: .workloadCpuMicroseconds)
        try container.encodeIfPresent(_jsonWorkloadReadBytes, forKey: .workloadReadBytes)
        try container.encodeIfPresent(_jsonWorkloadWriteBytes, forKey: .workloadWriteBytes)
        try container.encodeIfPresent(_jsonExternalSocketCount, forKey: .externalSocketCount)
        try container.encodeIfPresent(_jsonNicCount, forKey: .nicCount)
    }

}

public struct SandboxIdleGuestRequest: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case activity = "get_idle_activity", prepare = "prepare_idle", query = "query_idle", release = "release_idle"
    }
    public let type: Kind
    public let probeId: UUID?
    public let operationId: UUID?
    public let admissionToken: UUID?
    public let expectedActivityEpoch: UInt64?
    public let minimumQuietMilliseconds: UInt64?
    public init(
        type: Kind, probeId: UUID? = nil, operationId: UUID? = nil,
        admissionToken: UUID? = nil, expectedActivityEpoch: UInt64? = nil, minimumQuietMilliseconds: UInt64? = nil
    ) {
        self.type = type; self.probeId = probeId; self.operationId = operationId
        self.admissionToken = admissionToken; self.expectedActivityEpoch = expectedActivityEpoch
        self.minimumQuietMilliseconds = minimumQuietMilliseconds
    }
    enum CodingKeys: String, CodingKey {
        case type, probeId = "probe_id", operationId = "operation_id"
        case admissionToken = "admission_token", expectedActivityEpoch = "expected_activity_epoch",
            minimumQuietMilliseconds = "minimum_quiet_milliseconds"
    }
}

public struct SandboxIdleGuestResponse: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case activity = "idle_activity", fence = "idle_fence", error = "idle_error"
    }
    public enum State: String, Codable, Sendable { case prepared, released, absent }
    public let type: Kind
    public let sandboxId: String
    public let nonce: String
    public let activity: SandboxGuestIdleActivity?
    public let operationId: UUID?
    public let admissionToken: UUID?
    public let state: State?
    public let message: String?
    public init(
        type: Kind, sandboxId: String, nonce: String, activity: SandboxGuestIdleActivity? = nil,
        operationId: UUID? = nil, admissionToken: UUID? = nil, state: State? = nil, message: String? = nil
    ) {
        self.type = type; self.sandboxId = sandboxId; self.nonce = nonce; self.activity = activity
        self.operationId = operationId; self.admissionToken = admissionToken; self.state = state; self.message = message
    }
    public func matches(sandboxId: String, nonce: String) -> Bool {
        self.sandboxId == sandboxId && self.nonce == nonce && self.sandboxId.utf8.count <= 256
            && self.nonce.utf8.count <= 256
            && (message?.utf8.count ?? 0) <= 4096
    }
    enum CodingKeys: String, CodingKey {
        case type, sandboxId = "sandbox_id", nonce, activity, operationId = "operation_id"
        case admissionToken = "admission_token", state, message
    }
}

/// Ordered, owner-authenticated report. Receipt time is assigned by PostgreSQL;
/// guest/agent wall clocks do not establish activity freshness.
public typealias SandboxIdleActivityReport = Strato_Agent_V1_SandboxIdleActivityReport
extension Strato_Agent_V1_SandboxIdleActivityReport: Codable {

    public init(
        agentIncarnation: UUID, connectionEpoch: UUID, residencyEpoch: UUID, sequence: UInt64,
        generation: Int64, activityEpoch: UInt64, evidenceAgeMilliseconds: UInt64, residentForMilliseconds: UInt64,
        guest: SandboxGuestIdleActivity?, activeExecSessionIds: [UUID]?, pendingCommandCount: Int?,
        snapshotOrRestoreInProgress: Bool?, idleFenceSupported: Bool,
        hostQuietMilliseconds: UInt64? = nil, policy: SandboxIdlePolicy? = nil, hostPendingCommandCount: Int? = nil,
        controlPlaneActivityRevision: Int64? = nil
    ) {
        self.init()
        self._jsonAgentIncarnation = agentIncarnation; self._jsonConnectionEpoch = connectionEpoch;
        self._jsonResidencyEpoch = residencyEpoch
        self._jsonSequence = sequence; self._jsonGeneration = generation; self._jsonActivityEpoch = activityEpoch
        self._jsonEvidenceAgeMilliseconds = evidenceAgeMilliseconds;
        self._jsonResidentForMilliseconds = residentForMilliseconds
        self._jsonGuest = guest; self._jsonActiveExecSessionIds = activeExecSessionIds;
        self._jsonPendingCommandCount = pendingCommandCount
        self._jsonSnapshotOrRestoreInProgress = snapshotOrRestoreInProgress;
        self._jsonIdleFenceSupported = idleFenceSupported
        self._jsonHostQuietMilliseconds = hostQuietMilliseconds; self._jsonPolicy = policy
        self._jsonHostPendingCommandCount = hostPendingCommandCount
        self._jsonControlPlaneActivityRevision = controlPlaneActivityRevision
    }
    public var isCompleteQuiet: Bool {
        _jsonIdleFenceSupported && _jsonGuest?.hasCompleteQuiescentCoverage == true
            && _jsonActiveExecSessionIds?.isEmpty == true && _jsonPendingCommandCount == 0
            && _jsonHostPendingCommandCount == 0
            && _jsonSnapshotOrRestoreInProgress == false
            && _jsonEvidenceAgeMilliseconds <= 30_000 && _jsonSequence > 0 && _jsonSequence <= UInt64(Int64.max)
            && _jsonGeneration > 0
    }
    public func isNewer(than old: Self) -> Bool {
        _jsonAgentIncarnation == old._jsonAgentIncarnation && _jsonConnectionEpoch == old._jsonConnectionEpoch
            && _jsonResidencyEpoch == old._jsonResidencyEpoch && _jsonSequence > old._jsonSequence
            && _jsonActivityEpoch >= old._jsonActivityEpoch
            && _jsonGeneration >= old._jsonGeneration
    }

    private enum CodingKeys: String, CodingKey {
        case agentIncarnation; case connectionEpoch; case residencyEpoch; case sequence; case generation;
        case activityEpoch; case evidenceAgeMilliseconds; case residentForMilliseconds; case guest;
        case activeExecSessionIds; case pendingCommandCount; case hostPendingCommandCount;
        case controlPlaneActivityRevision; case snapshotOrRestoreInProgress; case idleFenceSupported;
        case hostQuietMilliseconds; case policy
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonAgentIncarnation = try container.decode(UUID.self, forKey: .agentIncarnation)
        self._jsonConnectionEpoch = try container.decode(UUID.self, forKey: .connectionEpoch)
        self._jsonResidencyEpoch = try container.decode(UUID.self, forKey: .residencyEpoch)
        self._jsonSequence = try container.decode(UInt64.self, forKey: .sequence)
        self._jsonGeneration = try container.decode(Int64.self, forKey: .generation)
        self._jsonActivityEpoch = try container.decode(UInt64.self, forKey: .activityEpoch)
        self._jsonEvidenceAgeMilliseconds = try container.decode(UInt64.self, forKey: .evidenceAgeMilliseconds)
        self._jsonResidentForMilliseconds = try container.decode(UInt64.self, forKey: .residentForMilliseconds)
        self._jsonGuest = try container.decodeIfPresent(SandboxGuestIdleActivity.self, forKey: .guest)
        self._jsonActiveExecSessionIds = try container.decodeIfPresent([UUID].self, forKey: .activeExecSessionIds)
        self._jsonPendingCommandCount = try container.decodeIfPresent(Int.self, forKey: .pendingCommandCount)
        self._jsonHostPendingCommandCount = try container.decodeIfPresent(Int.self, forKey: .hostPendingCommandCount)
        self._jsonControlPlaneActivityRevision = try container.decodeIfPresent(
            Int64.self, forKey: .controlPlaneActivityRevision)
        self._jsonSnapshotOrRestoreInProgress = try container.decodeIfPresent(
            Bool.self, forKey: .snapshotOrRestoreInProgress)
        self._jsonIdleFenceSupported = try container.decode(Bool.self, forKey: .idleFenceSupported)
        self._jsonHostQuietMilliseconds = try container.decodeIfPresent(UInt64.self, forKey: .hostQuietMilliseconds)
        self._jsonPolicy = try container.decodeIfPresent(SandboxIdlePolicy.self, forKey: .policy)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonAgentIncarnation, forKey: .agentIncarnation)
        try container.encode(_jsonConnectionEpoch, forKey: .connectionEpoch)
        try container.encode(_jsonResidencyEpoch, forKey: .residencyEpoch)
        try container.encode(_jsonSequence, forKey: .sequence)
        try container.encode(_jsonGeneration, forKey: .generation)
        try container.encode(_jsonActivityEpoch, forKey: .activityEpoch)
        try container.encode(_jsonEvidenceAgeMilliseconds, forKey: .evidenceAgeMilliseconds)
        try container.encode(_jsonResidentForMilliseconds, forKey: .residentForMilliseconds)
        try container.encodeIfPresent(_jsonGuest, forKey: .guest)
        try container.encodeIfPresent(_jsonActiveExecSessionIds, forKey: .activeExecSessionIds)
        try container.encodeIfPresent(_jsonPendingCommandCount, forKey: .pendingCommandCount)
        try container.encodeIfPresent(_jsonHostPendingCommandCount, forKey: .hostPendingCommandCount)
        try container.encodeIfPresent(_jsonControlPlaneActivityRevision, forKey: .controlPlaneActivityRevision)
        try container.encodeIfPresent(_jsonSnapshotOrRestoreInProgress, forKey: .snapshotOrRestoreInProgress)
        try container.encode(_jsonIdleFenceSupported, forKey: .idleFenceSupported)
        try container.encodeIfPresent(_jsonHostQuietMilliseconds, forKey: .hostQuietMilliseconds)
        try container.encodeIfPresent(_jsonPolicy, forKey: .policy)
    }

}
