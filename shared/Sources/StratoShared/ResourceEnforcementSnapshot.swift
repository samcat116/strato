import Foundation
import SwiftProtobuf

/// Generation-authorized enforcement and accounting captured with the SAME
/// observed report's net resources. Absence is unknown, never acknowledgement.
public typealias ResourceEnforcementSnapshot = Strato_Agent_V1_ResourceEnforcementSnapshot
extension Strato_Agent_V1_ResourceEnforcementSnapshot: Codable {

    public init(
        agentBootID: UUID, sequence: Int64, sampledAt: Date, inventoryComplete: Bool,
        acknowledgements: [WorkloadEnforcementAcknowledgement]
    ) {
        self.init()
        self._jsonAgentBootID = agentBootID
        self._jsonSequence = sequence
        self._jsonSampledAt = sampledAt
        self._jsonInventoryComplete = inventoryComplete
        self._jsonAcknowledgements = acknowledgements
    }

    private enum CodingKeys: String, CodingKey {
        case agentBootID; case sequence; case sampledAt; case inventoryComplete; case acknowledgements
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonAgentBootID = try container.decode(UUID.self, forKey: .agentBootID)
        self._jsonSequence = try container.decode(Int64.self, forKey: .sequence)
        self._jsonSampledAt = try container.decode(Date.self, forKey: .sampledAt)
        self._jsonInventoryComplete = try container.decode(Bool.self, forKey: .inventoryComplete)
        self._jsonAcknowledgements = try container.decode(
            [WorkloadEnforcementAcknowledgement].self, forKey: .acknowledgements)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonAgentBootID, forKey: .agentBootID)
        try container.encode(_jsonSequence, forKey: .sequence)
        try container.encode(_jsonSampledAt, forKey: .sampledAt)
        try container.encode(_jsonInventoryComplete, forKey: .inventoryComplete)
        try container.encode(_jsonAcknowledgements, forKey: .acknowledgements)
    }

    var _jsonAgentBootID: UUID {
        get { UUID(uuidString: agentBootID) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) }
        set { let value = newValue; agentBootID = value.uuidString }
    }
    var _jsonSequence: Int64 {
        get { sequence }
        set { let value = newValue; sequence = value }
    }
    var _jsonSampledAt: Date {
        get { sampledAt.date }
        set { let value = newValue; sampledAt = Google_Protobuf_Timestamp(date: value) }
    }
    var _jsonInventoryComplete: Bool {
        get { inventoryComplete }
        set { let value = newValue; inventoryComplete = value }
    }
    var _jsonAcknowledgements: [WorkloadEnforcementAcknowledgement] {
        get { acknowledgements.values }
        set {
            let value = newValue;
            acknowledgements = Strato_Agent_V1_ResourceEnforcementSnapshotAcknowledgementsSection.with {
                $0.values = value
            }
        }
    }
}

/// Certifies successful guarded backend convergence AND exactly-once inclusion
/// of accountedReservation in this report's capacity arithmetic. File sampling
/// alone cannot create this acknowledgement; the producer owns generation and
/// boundary validation. Desired limits describe this applied snapshot/grant.
public typealias WorkloadEnforcementAcknowledgement = Strato_Agent_V1_WorkloadEnforcementAcknowledgement
extension Strato_Agent_V1_WorkloadEnforcementAcknowledgement: Codable {

    public init(
        kind: WorkloadKind, workloadId: UUID, appliedGeneration: Int64,
        resourceClass: WorkloadResourceClassSnapshot, backend: WorkloadResourceClassBackend,
        accountedReservation: WorkloadAdmittedReservation, runtimeGuestBytes: Int64, pageSizeBytes: Int64,
        desiredLimits: WorkloadRuntimeLimits, appliedLimits: WorkloadRuntimeLimits,
        cpuQuotaUnlimited: Bool, ownershipVerified: Bool
    ) {
        self.init()
        self._jsonKind = kind
        self._jsonWorkloadId = workloadId
        self._jsonAppliedGeneration = appliedGeneration
        self._jsonResourceClass = resourceClass
        self._jsonBackend = backend
        self._jsonAccountedReservation = accountedReservation
        self._jsonRuntimeGuestBytes = runtimeGuestBytes
        self._jsonPageSizeBytes = pageSizeBytes
        self._jsonDesiredLimits = desiredLimits
        self._jsonAppliedLimits = appliedLimits
        self._jsonCpuQuotaUnlimited = cpuQuotaUnlimited
        self._jsonOwnershipVerified = ownershipVerified
    }

    private enum CodingKeys: String, CodingKey {
        case kind; case workloadId; case appliedGeneration; case resourceClass; case backend; case accountedReservation;
        case runtimeGuestBytes; case pageSizeBytes; case desiredLimits; case appliedLimits; case cpuQuotaUnlimited;
        case ownershipVerified
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonKind = try container.decode(WorkloadKind.self, forKey: .kind)
        self._jsonWorkloadId = try container.decode(UUID.self, forKey: .workloadId)
        self._jsonAppliedGeneration = try container.decode(Int64.self, forKey: .appliedGeneration)
        self._jsonResourceClass = try container.decode(WorkloadResourceClassSnapshot.self, forKey: .resourceClass)
        self._jsonBackend = try container.decode(WorkloadResourceClassBackend.self, forKey: .backend)
        self._jsonAccountedReservation = try container.decode(
            WorkloadAdmittedReservation.self, forKey: .accountedReservation)
        self._jsonRuntimeGuestBytes = try container.decode(Int64.self, forKey: .runtimeGuestBytes)
        self._jsonPageSizeBytes = try container.decode(Int64.self, forKey: .pageSizeBytes)
        self._jsonDesiredLimits = try container.decode(WorkloadRuntimeLimits.self, forKey: .desiredLimits)
        self._jsonAppliedLimits = try container.decode(WorkloadRuntimeLimits.self, forKey: .appliedLimits)
        self._jsonCpuQuotaUnlimited = try container.decode(Bool.self, forKey: .cpuQuotaUnlimited)
        self._jsonOwnershipVerified = try container.decode(Bool.self, forKey: .ownershipVerified)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonKind, forKey: .kind)
        try container.encode(_jsonWorkloadId, forKey: .workloadId)
        try container.encode(_jsonAppliedGeneration, forKey: .appliedGeneration)
        try container.encode(_jsonResourceClass, forKey: .resourceClass)
        try container.encode(_jsonBackend, forKey: .backend)
        try container.encode(_jsonAccountedReservation, forKey: .accountedReservation)
        try container.encode(_jsonRuntimeGuestBytes, forKey: .runtimeGuestBytes)
        try container.encode(_jsonPageSizeBytes, forKey: .pageSizeBytes)
        try container.encode(_jsonDesiredLimits, forKey: .desiredLimits)
        try container.encode(_jsonAppliedLimits, forKey: .appliedLimits)
        try container.encode(_jsonCpuQuotaUnlimited, forKey: .cpuQuotaUnlimited)
        try container.encode(_jsonOwnershipVerified, forKey: .ownershipVerified)
    }

    var _jsonKind: WorkloadKind {
        get { kind }
        set { let value = newValue; kind = value }
    }
    var _jsonWorkloadId: UUID {
        get { UUID(uuidString: workloadID) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) }
        set { let value = newValue; workloadID = value.uuidString }
    }
    var _jsonAppliedGeneration: Int64 {
        get { appliedGeneration }
        set { let value = newValue; appliedGeneration = value }
    }
    var _jsonResourceClass: WorkloadResourceClassSnapshot {
        get { resourceClass }
        set { let value = newValue; resourceClass = value }
    }
    var _jsonBackend: WorkloadResourceClassBackend {
        get { backend }
        set { let value = newValue; backend = value }
    }
    var _jsonAccountedReservation: WorkloadAdmittedReservation {
        get { accountedReservation }
        set { let value = newValue; accountedReservation = value }
    }
    var _jsonRuntimeGuestBytes: Int64 {
        get { runtimeGuestBytes }
        set { let value = newValue; runtimeGuestBytes = value }
    }
    var _jsonPageSizeBytes: Int64 {
        get { pageSizeBytes }
        set { let value = newValue; pageSizeBytes = value }
    }
    var _jsonDesiredLimits: WorkloadRuntimeLimits {
        get { desiredLimits }
        set { let value = newValue; desiredLimits = value }
    }
    var _jsonAppliedLimits: WorkloadRuntimeLimits {
        get { appliedLimits }
        set { let value = newValue; appliedLimits = value }
    }
    var _jsonCpuQuotaUnlimited: Bool {
        get { cpuQuotaUnlimited }
        set { let value = newValue; cpuQuotaUnlimited = value }
    }
    var _jsonOwnershipVerified: Bool {
        get { ownershipVerified }
        set { let value = newValue; ownershipVerified = value }
    }
}
