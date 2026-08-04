import Fluent
import StratoShared
import Vapor

/// What the control plane decided about a workload an agent holds but no
/// desired-state sync accounted for (STR-98).
enum WorkloadClaimDisposition: String, Codable, CaseIterable, Sendable {
    /// No row describes this workload, so its teardown is authorized: the next
    /// sync to this agent carries a `DesiredWorkloadTombstone` for it.
    case tombstoned
    /// A row *does* exist. Teardown is never authorized from here — the sync
    /// that omitted a live workload is the thing that is wrong, not the
    /// workload. The claim stays as the evidence an operator (or the
    /// re-point endpoint) acts on.
    case held
}

/// One agent's claim to hold a workload its last sync did not list.
///
/// This table is the memory between the two halves of the teardown round trip.
/// An agent reports an `UnrecognizedWorkload`; the control plane decides once
/// and records it here; `DesiredStateAssembler` turns the `tombstoned` rows
/// into the tombstones the next sync carries. Without it, "should this be torn
/// down?" would have to be re-decided inside every sync assembly, which has no
/// access to what the agent reported.
///
/// Deliberately no foreign key on `resource_id`: the common case is a workload
/// whose row does not exist, which is precisely what an FK would forbid.
final class AgentWorkloadClaim: Model, @unchecked Sendable {
    static let schema = "agent_workload_claims"

    @ID(key: .id)
    var id: UUID?

    /// The reporting agent, in the same form as `VM.hypervisorId` (the agent
    /// row's UUID string), so claims join to placements without translation.
    @Field(key: "agent_id")
    var agentId: String

    @Enum(key: "resource_kind")
    var resourceKind: OperationResourceKind

    @Field(key: "resource_id")
    var resourceID: UUID

    @Enum(key: "disposition")
    var disposition: WorkloadClaimDisposition

    /// The generation the authorizing tombstone carries. Set only for
    /// `tombstoned` claims, and monotonic: it must outrank whatever the agent
    /// last applied for the workload or the reconciler drops it as stale.
    @OptionalField(key: "tombstone_generation")
    var tombstoneGeneration: Int64?

    /// Why the claim is `held` — `row_present_here`, or `row_on_agent:<uuid>`
    /// when the workload's row is placed on a different agent (the re-point
    /// case). Nil for `tombstoned` claims.
    @OptionalField(key: "reason")
    var reason: String?

    /// The desired-state generation the agent last applied for this workload,
    /// as reported. The tombstone generation is minted above it.
    @Field(key: "observed_generation")
    var observedGeneration: Int64

    /// The workload's observed status on the agent, for operator-facing
    /// listings. Diagnostic only.
    @OptionalField(key: "observed_status")
    var observedStatus: String?

    @Timestamp(key: "first_seen_at", on: .create)
    var firstSeenAt: Date?

    @Timestamp(key: "last_seen_at", on: .update)
    var lastSeenAt: Date?

    init() {}

    init(
        id: UUID? = nil,
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

    /// The reason string recorded for a workload whose row is placed on
    /// another agent, and the parser for it. Kept together so the re-point
    /// endpoint reads the same format the applier writes.
    static func heldOnOtherAgentReason(_ agentId: String) -> String {
        "row_on_agent:\(agentId)"
    }

    static let heldRowPresentReason = "row_present_here"

    /// The agent this claim's workload is currently placed on, when the claim
    /// records exactly that situation.
    var placedOnAgentId: String? {
        guard disposition == .held, let reason,
            reason.hasPrefix("row_on_agent:")
        else { return nil }
        return String(reason.dropFirst("row_on_agent:".count))
    }
}

extension WorkloadKind {
    /// The operation/claim discriminator for this wire-level workload kind.
    var resourceKind: OperationResourceKind {
        switch self {
        case .vm: return .virtualMachine
        case .sandbox: return .sandbox
        }
    }
}

extension OperationResourceKind {
    /// The wire-level workload kind for this discriminator.
    var workloadKind: WorkloadKind {
        switch self {
        case .virtualMachine: return .vm
        case .sandbox: return .sandbox
        }
    }
}
