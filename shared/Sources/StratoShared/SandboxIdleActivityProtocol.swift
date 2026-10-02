import Foundation

/// Wire 69 policy provenance. Missing provenance remains an explicit/manual
/// lifecycle request; malformed automatic provenance must never become manual.
public struct SandboxAutomaticSuspensionFence: Codable, Equatable, Sendable {
    public let operationId: UUID
    public let generation: Int64
    public let activityRevision: Int64
    public let admissionToken: UUID
    public let guestProtocolVersion: Int

    public init(
        operationId: UUID, generation: Int64, activityRevision: Int64, admissionToken: UUID,
        guestProtocolVersion: Int
    ) {
        self.operationId = operationId
        self.generation = generation
        self.activityRevision = activityRevision
        self.admissionToken = admissionToken
        self.guestProtocolVersion = guestProtocolVersion
    }

    public var isValid: Bool {
        generation > 0 && activityRevision >= 0 && guestProtocolVersion == SandboxGuestControlProtocol.idlePolicyVersion
    }
}

/// Actual guest v5 evidence. This has the guest's snake-case JSON spelling,
/// including when relayed in the agent report. Unknown fields never mean zero.
public struct SandboxGuestIdleActivity: Codable, Equatable, Sendable {
    public enum Coverage: String, Codable, Sendable { case complete, unknown }
    public let sandboxId: String
    public let nonce: String
    public let probeId: UUID
    public let monitorIncarnation: UUID
    public let sampleSequence: UInt64
    public let activityEpoch: UInt64
    public let quietForMilliseconds: UInt64?
    public let coverage: Coverage
    public let trusted: Bool
    public let activeExecSessionIds: [UUID]?
    public let anonymousExecCount: UInt32?
    public let pendingExecCount: UInt32?
    public let workloadCpuMicroseconds: UInt64?
    public let workloadReadBytes: UInt64?
    public let workloadWriteBytes: UInt64?
    public let externalSocketCount: UInt32?
    public let nicCount: UInt32?

    public init(
        sandboxId: String, nonce: String, probeId: UUID, monitorIncarnation: UUID,
        sampleSequence: UInt64, activityEpoch: UInt64, quietForMilliseconds: UInt64?,
        coverage: Coverage, trusted: Bool, activeExecSessionIds: [UUID]?, anonymousExecCount: UInt32?,
        pendingExecCount: UInt32?, workloadCpuMicroseconds: UInt64?, workloadReadBytes: UInt64?,
        workloadWriteBytes: UInt64?, externalSocketCount: UInt32?, nicCount: UInt32?
    ) {
        self.sandboxId = sandboxId; self.nonce = nonce; self.probeId = probeId
        self.monitorIncarnation = monitorIncarnation; self.sampleSequence = sampleSequence
        self.activityEpoch = activityEpoch; self.quietForMilliseconds = quietForMilliseconds
        self.coverage = coverage; self.trusted = trusted; self.activeExecSessionIds = activeExecSessionIds
        self.anonymousExecCount = anonymousExecCount; self.pendingExecCount = pendingExecCount
        self.workloadCpuMicroseconds = workloadCpuMicroseconds; self.workloadReadBytes = workloadReadBytes
        self.workloadWriteBytes = workloadWriteBytes; self.externalSocketCount = externalSocketCount;
        self.nicCount = nicCount
    }

    public var hasCompleteQuiescentCoverage: Bool {
        coverage == .complete && trusted && nicCount == 0 && externalSocketCount == 0
            && anonymousExecCount == 0 && pendingExecCount == 0 && activeExecSessionIds?.isEmpty == true
            && workloadCpuMicroseconds != nil && workloadReadBytes != nil && workloadWriteBytes != nil
            && quietForMilliseconds.map { $0 <= 86_400_000 } == true && isBounded
    }

    public var isBounded: Bool {
        sandboxId.utf8.count <= 256 && nonce.utf8.count <= 256
            && !sandboxId.isEmpty && !nonce.isEmpty
            && sampleSequence > 0 && sampleSequence <= UInt64(Int64.max)
            && activityEpoch <= UInt64(Int64.max)
            && (activeExecSessionIds.map { $0.count <= 4096 && Set($0).count == $0.count } ?? true)
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
public struct SandboxIdleActivityReport: Codable, Equatable, Sendable {
    public let agentIncarnation: UUID
    public let connectionEpoch: UUID
    public let residencyEpoch: UUID
    public let sequence: UInt64
    public let generation: Int64
    public let activityEpoch: UInt64
    public let evidenceAgeMilliseconds: UInt64
    public let residentForMilliseconds: UInt64
    public let guest: SandboxGuestIdleActivity?
    public let activeExecSessionIds: [UUID]?
    public let pendingCommandCount: Int?
    public let hostPendingCommandCount: Int?
    public let controlPlaneActivityRevision: Int64?
    public let snapshotOrRestoreInProgress: Bool?
    public let idleFenceSupported: Bool
    public let hostQuietMilliseconds: UInt64?
    public let policy: SandboxIdlePolicy?

    public init(
        agentIncarnation: UUID, connectionEpoch: UUID, residencyEpoch: UUID, sequence: UInt64,
        generation: Int64, activityEpoch: UInt64, evidenceAgeMilliseconds: UInt64, residentForMilliseconds: UInt64,
        guest: SandboxGuestIdleActivity?, activeExecSessionIds: [UUID]?, pendingCommandCount: Int?,
        snapshotOrRestoreInProgress: Bool?, idleFenceSupported: Bool,
        hostQuietMilliseconds: UInt64? = nil, policy: SandboxIdlePolicy? = nil, hostPendingCommandCount: Int? = nil,
        controlPlaneActivityRevision: Int64? = nil
    ) {
        self.agentIncarnation = agentIncarnation; self.connectionEpoch = connectionEpoch;
        self.residencyEpoch = residencyEpoch
        self.sequence = sequence; self.generation = generation; self.activityEpoch = activityEpoch
        self.evidenceAgeMilliseconds = evidenceAgeMilliseconds; self.residentForMilliseconds = residentForMilliseconds
        self.guest = guest; self.activeExecSessionIds = activeExecSessionIds;
        self.pendingCommandCount = pendingCommandCount
        self.snapshotOrRestoreInProgress = snapshotOrRestoreInProgress; self.idleFenceSupported = idleFenceSupported
        self.hostQuietMilliseconds = hostQuietMilliseconds; self.policy = policy
        self.hostPendingCommandCount = hostPendingCommandCount
        self.controlPlaneActivityRevision = controlPlaneActivityRevision
    }
    public var isCompleteQuiet: Bool {
        idleFenceSupported && guest?.hasCompleteQuiescentCoverage == true
            && activeExecSessionIds?.isEmpty == true && pendingCommandCount == 0 && hostPendingCommandCount == 0
            && snapshotOrRestoreInProgress == false
            && evidenceAgeMilliseconds <= 30_000 && sequence > 0 && sequence <= UInt64(Int64.max)
            && generation > 0
    }
    public func isNewer(than old: Self) -> Bool {
        agentIncarnation == old.agentIncarnation && connectionEpoch == old.connectionEpoch
            && residencyEpoch == old.residencyEpoch && sequence > old.sequence && activityEpoch >= old.activityEpoch
            && generation >= old.generation
    }
}
