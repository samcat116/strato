import Foundation

/// Generation-authorized enforcement and accounting captured with the SAME
/// observed report's net resources. Absence is unknown, never acknowledgement.
public struct ResourceEnforcementSnapshot: Codable, Sendable, Equatable {
    public let agentBootID: UUID
    public let sequence: Int64
    public let sampledAt: Date
    public let inventoryComplete: Bool
    public let acknowledgements: [WorkloadEnforcementAcknowledgement]

    public init(
        agentBootID: UUID, sequence: Int64, sampledAt: Date, inventoryComplete: Bool,
        acknowledgements: [WorkloadEnforcementAcknowledgement]
    ) {
        self.agentBootID = agentBootID
        self.sequence = sequence
        self.sampledAt = sampledAt
        self.inventoryComplete = inventoryComplete
        self.acknowledgements = acknowledgements
    }
}

/// Certifies successful guarded backend convergence AND exactly-once inclusion
/// of accountedReservation in this report's capacity arithmetic. File sampling
/// alone cannot create this acknowledgement; the producer owns generation and
/// boundary validation. Desired limits describe this applied snapshot/grant.
public struct WorkloadEnforcementAcknowledgement: Codable, Sendable, Equatable {
    public let kind: WorkloadKind
    public let workloadId: UUID
    public let appliedGeneration: Int64
    public let resourceClass: WorkloadResourceClassSnapshot
    public let backend: WorkloadResourceClassBackend
    public let accountedReservation: WorkloadAdmittedReservation
    public let runtimeGuestBytes: Int64
    public let pageSizeBytes: Int64
    public let desiredLimits: WorkloadRuntimeLimits
    public let appliedLimits: WorkloadRuntimeLimits
    public let cpuQuotaUnlimited: Bool
    public let ownershipVerified: Bool

    public init(
        kind: WorkloadKind, workloadId: UUID, appliedGeneration: Int64,
        resourceClass: WorkloadResourceClassSnapshot, backend: WorkloadResourceClassBackend,
        accountedReservation: WorkloadAdmittedReservation, runtimeGuestBytes: Int64, pageSizeBytes: Int64,
        desiredLimits: WorkloadRuntimeLimits, appliedLimits: WorkloadRuntimeLimits,
        cpuQuotaUnlimited: Bool, ownershipVerified: Bool
    ) {
        self.kind = kind
        self.workloadId = workloadId
        self.appliedGeneration = appliedGeneration
        self.resourceClass = resourceClass
        self.backend = backend
        self.accountedReservation = accountedReservation
        self.runtimeGuestBytes = runtimeGuestBytes
        self.pageSizeBytes = pageSizeBytes
        self.desiredLimits = desiredLimits
        self.appliedLimits = appliedLimits
        self.cpuQuotaUnlimited = cpuQuotaUnlimited
        self.ownershipVerified = ownershipVerified
    }
}
