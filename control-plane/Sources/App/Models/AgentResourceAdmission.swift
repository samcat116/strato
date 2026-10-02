import Fluent
import Foundation
import StratoShared

/// PostgreSQL, not an expiring coordination key, owns pending growth charges.
final class AgentResourceAdmission: Model, @unchecked Sendable {
    static let schema = "agent_resource_admissions"
    @ID(custom: "id", generatedBy: .user) var id: UUID?
    @Field(key: "state") var state: ResourceAdmissionState
    init() {}
    init(agentID: UUID, state: ResourceAdmissionState = .init()) {
        id = agentID
        self.state = state
    }
}

struct ResourceAdmissionState: Codable, Sendable {
    var sessionID: UUID?
    var bootID: UUID?
    var sequence: Int64 = -1
    var requestID: String?
    var resources: AgentResources?
    var inventoryComplete: Bool?
    var pending: [PendingResourceCommitment] = []

    var amounts: ReservationAmounts {
        pending.reduce(.zero) { sum, claim in
            let (cpu, cpuOverflow) = sum.cpuMicroUnits.addingReportingOverflow(claim.cpuMicroUnits)
            let (memory, memoryOverflow) = sum.memory.addingReportingOverflow(claim.memoryBytes)
            return .init(
                memory: memoryOverflow ? .max : memory, disk: 0,
                cpuMicroUnits: cpuOverflow ? .max : cpu)
        }
    }
}

struct PendingResourceCommitment: Codable, Sendable {
    let reservationID: String
    let kind: WorkloadKind
    let workloadID: UUID
    let generation: Int64
    let resourceClass: WorkloadResourceClassSnapshot
    let previousReservation: WorkloadAdmittedReservation
    let reservation: WorkloadAdmittedReservation
    let backend: WorkloadResourceClassBackend
    let cpuMicroUnits: Int64
    let memoryBytes: Int64
}
