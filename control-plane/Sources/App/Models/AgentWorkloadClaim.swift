import ControlPlanePostgres
import Foundation
import StratoShared

typealias WorkloadClaimDisposition = ControlPlanePostgres.WorkloadClaimDisposition

/// Stable table vocabulary shared by reconciliation, desired-state assembly,
/// and the schema compatibility tests. This is a namespace, not a mutable
/// persistence entity.
enum AgentWorkloadClaim {
    static let schema = "agent_workload_claims"
    static let resourceKindConstraintName = "ck_agent_workload_claims_resource_kind_enum"

    static func heldOnOtherAgentReason(_ agentId: String) -> String {
        "row_on_agent:\(agentId)"
    }

    static let heldRowPresentReason = "row_present_here"
    static let heldOtherAgentBucket = "row_on_other_agent"
}

/// Application projection of the native immutable workload-claim snapshot.
struct AgentWorkloadClaimRecord: Equatable, Sendable {
    let id: UUID
    let agentId: String
    let resourceKind: OperationResourceKind
    let resourceID: UUID
    let disposition: WorkloadClaimDisposition
    let tombstoneGeneration: Int64?
    let reason: String?
    let observedGeneration: Int64
    let observedStatus: String?
    let firstSeenAt: Date?
    let lastSeenAt: Date?

    init(_ snapshot: WorkloadClaimSnapshot) throws {
        guard let resourceKind = OperationResourceKind(rawValue: snapshot.resourceKind) else {
            throw AgentWorkloadClaimError.invalidResourceKind(snapshot.resourceKind)
        }
        self.id = snapshot.id
        self.agentId = snapshot.agentID
        self.resourceKind = resourceKind
        self.resourceID = snapshot.resourceID
        self.disposition = snapshot.disposition
        self.tombstoneGeneration = snapshot.tombstoneGeneration
        self.reason = snapshot.reason
        self.observedGeneration = snapshot.observedGeneration
        self.observedStatus = snapshot.observedStatus
        self.firstSeenAt = snapshot.firstSeenAt
        self.lastSeenAt = snapshot.lastSeenAt
    }

    var reasonBucket: String {
        placedOnAgentId == nil ? AgentWorkloadClaim.heldRowPresentReason : AgentWorkloadClaim.heldOtherAgentBucket
    }

    var placedOnAgentId: String? {
        guard disposition == .held, let reason,
            reason.hasPrefix("row_on_agent:")
        else { return nil }
        return String(reason.dropFirst("row_on_agent:".count))
    }
}

/// Application intent converted explicitly into the native module's write
/// value so the App-only operation discriminator does not leak into the
/// persistence target.
struct AgentWorkloadClaimWrite: Equatable, Sendable {
    let id: UUID
    let agentId: String
    let resourceKind: OperationResourceKind
    let resourceID: UUID
    let disposition: WorkloadClaimDisposition
    let tombstoneGeneration: Int64?
    let reason: String?
    let observedGeneration: Int64
    let observedStatus: String?

    init(
        id: UUID = UUID(),
        agentId: String,
        resourceKind: OperationResourceKind,
        resourceID: UUID,
        disposition: WorkloadClaimDisposition,
        tombstoneGeneration: Int64? = nil,
        reason: String? = nil,
        observedGeneration: Int64,
        observedStatus: String? = nil
    ) {
        self.id = id
        self.agentId = agentId
        self.resourceKind = resourceKind
        self.resourceID = resourceID
        self.disposition = disposition
        self.tombstoneGeneration = tombstoneGeneration
        self.reason = reason
        self.observedGeneration = observedGeneration
        self.observedStatus = observedStatus
    }

    var native: WorkloadClaimWrite {
        WorkloadClaimWrite(
            id: id,
            agentID: agentId,
            resourceKind: resourceKind.rawValue,
            resourceID: resourceID,
            disposition: disposition,
            tombstoneGeneration: tombstoneGeneration,
            reason: reason,
            observedGeneration: observedGeneration,
            observedStatus: observedStatus)
    }
}

enum AgentWorkloadClaimError: Error, Equatable, Sendable {
    case invalidResourceKind(String)
}

extension WorkloadKind {
    var resourceKind: OperationResourceKind {
        switch self {
        case .vm: return .virtualMachine
        case .sandbox: return .sandbox
        case .volume: return .volume
        case .volumeSnapshot: return .volumeSnapshot
        case .vmCheckpoint: return .vmCheckpoint
        case .sandboxSnapshot: return .sandboxSnapshot
        }
    }
}

extension OperationResourceKind {
    var workloadKind: WorkloadKind {
        switch self {
        case .virtualMachine: return .vm
        case .sandbox: return .sandbox
        case .volume: return .volume
        case .volumeSnapshot: return .volumeSnapshot
        case .vmCheckpoint: return .vmCheckpoint
        case .sandboxSnapshot: return .sandboxSnapshot
        }
    }
}
