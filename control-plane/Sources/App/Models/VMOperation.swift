import Fluent
import Vapor
import StratoShared

/// Durable record of one asynchronous VM lifecycle mutation (issue #259).
///
/// Mutation endpoints create a `pending` row in the same transaction as the VM
/// change, return it with `202 Accepted`, and complete it from the agent's
/// success/error response. Rows that never complete — control-plane restart,
/// lost agent — are failed by the stuck-operation sweep after the kind's budget.
///
/// `vm_id` is deliberately a plain column, not a foreign key: a delete
/// operation must outlive the VM row it removes so the client can poll it to a
/// terminal state.
final class VMOperation: Model, @unchecked Sendable {
    static let schema = "vm_operations"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "vm_id")
    var vmID: UUID

    /// The user who initiated the mutation. Operation visibility follows the
    /// VM's `read` permission while the VM exists; once it is deleted, the
    /// initiator (and system admins) can still poll the operation.
    @Field(key: "user_id")
    var userID: UUID

    @Enum(key: "kind")
    var kind: VMOperationKind

    @Enum(key: "status")
    var status: VMOperationStatus

    @OptionalField(key: "error")
    var error: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @OptionalField(key: "completed_at")
    var completedAt: Date?

    init() {}

    init(vmID: UUID, userID: UUID, kind: VMOperationKind) {
        self.vmID = vmID
        self.userID = userID
        self.kind = kind
        self.status = .pending
    }
}

extension VMOperation {
    /// Marks the operation terminal if — and only if — it is still pending, so
    /// the two completion paths (agent response and stuck-operation sweep)
    /// cannot overwrite each other's verdict. Returns whether this call won.
    func completeIfPending(as status: VMOperationStatus, error: String?, on db: Database) async throws -> Bool {
        guard self.status == .pending else { return false }
        self.status = status
        self.error = error
        self.completedAt = Date()
        try await self.save(on: db)
        return true
    }
}

extension VMOperationKind {
    /// How long an operation of this kind may stay `pending` before it is
    /// considered lost. Used both as the agent-response timeout while the
    /// dispatching process is alive and as the sweep budget after a restart,
    /// so the client-observed deadline is the same on both paths.
    var completionBudgetSeconds: TimeInterval {
        switch self {
        case .create:
            // Image-based creates can download multi-gigabyte base images.
            return 600
        case .boot:
            return 180
        case .delete:
            // Deletion runs two agent phases inside this one budget: a
            // best-effort guest shutdown bounded by the shutdown budget, then
            // the delete itself bounded by the remainder (see runVMDeletion).
            return 300
        case .shutdown, .reboot, .pause, .resume:
            return 120
        }
    }

    var completionBudget: Duration {
        .seconds(Int64(completionBudgetSeconds))
    }
}

// MARK: - Response DTO

struct OperationResponse: Content {
    let id: UUID?
    let vmId: UUID
    let kind: VMOperationKind
    let status: VMOperationStatus
    let error: String?
    let createdAt: Date?
    let completedAt: Date?

    init(from operation: VMOperation) {
        self.id = operation.id
        self.vmId = operation.vmID
        self.kind = operation.kind
        self.status = operation.status
        self.error = operation.error
        self.createdAt = operation.createdAt
        self.completedAt = operation.completedAt
    }
}
