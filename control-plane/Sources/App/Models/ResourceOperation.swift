import Fluent
import Vapor
import StratoShared

/// The kind of resource an asynchronous operation acts on — the
/// `resource_kind` discriminator on `ResourceOperation` (issue #412). Each
/// kind brings its own operation budgets, stuck-resource resolution, and
/// visibility rule; adding a resource type means extending the switches that
/// dispatch on this enum, not forking the 202/poll/sweep machinery.
enum OperationResourceKind: String, Codable, CaseIterable, Sendable {
    case virtualMachine = "virtual_machine"
    case sandbox = "sandbox"

    /// Short noun for client-facing messages ("An operation is already
    /// pending for this VM").
    var displayName: String {
        switch self {
        case .virtualMachine:
            return "VM"
        case .sandbox:
            return "sandbox"
        }
    }

    /// How long an operation of `kind` on this resource kind may stay
    /// `pending` before it is considered lost. Used both as the
    /// agent-response timeout while the dispatching process is alive and as
    /// the sweep budget after a restart, so the client-observed deadline is
    /// the same on both paths.
    func completionBudgetSeconds(for kind: VMOperationKind) -> TimeInterval {
        switch self {
        case .virtualMachine:
            switch kind {
            case .create:
                // Image-based creates can download multi-gigabyte base images.
                return 600
            case .boot:
                return 180
            case .delete:
                // Deletion runs two agent phases inside this one budget: a
                // best-effort guest shutdown bounded by the shutdown budget,
                // then the delete itself bounded by the remainder (see
                // runVMDeletion).
                return 300
            case .shutdown, .reboot, .pause, .resume:
                return 120
            }
        case .sandbox:
            switch kind {
            case .create, .boot:
                // Both may pull a multi-gigabyte OCI image on a cold agent
                // cache before the microVM can boot.
                return 600
            case .delete:
                return 300
            case .shutdown, .reboot, .pause, .resume:
                // Pause/resume are unreachable for sandboxes (no endpoint
                // issues them) but the budget total function stays total.
                return 120
            }
        }
    }
}

/// Durable record of one asynchronous resource lifecycle mutation (issue #259,
/// generalized beyond VMs in issue #412).
///
/// Mutation endpoints create a `pending` row in the same transaction as the
/// resource change, return it with `202 Accepted`, and complete it from the
/// agent's success/error response. Rows that never complete — control-plane
/// restart, lost agent — are failed by the stuck-operation sweep after the
/// kind's budget.
///
/// `resource_id` is deliberately a plain column, not a foreign key: a delete
/// operation must outlive the row it removes so the client can poll it to a
/// terminal state. `resource_kind` says which table the id points into.
final class ResourceOperation: Model, @unchecked Sendable {
    static let schema = "resource_operations"

    @ID(key: .id)
    var id: UUID?

    @Enum(key: "resource_kind")
    var resourceKind: OperationResourceKind

    @Field(key: "resource_id")
    var resourceID: UUID

    /// The user who initiated the mutation. Operation visibility follows the
    /// resource's `read` permission while it exists; once it is deleted, the
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

    init(resourceKind: OperationResourceKind, resourceID: UUID, userID: UUID, kind: VMOperationKind) {
        self.resourceKind = resourceKind
        self.resourceID = resourceID
        self.userID = userID
        self.kind = kind
        self.status = .pending
    }

    /// VM sugar for the dominant resource kind.
    convenience init(vmID: UUID, userID: UUID, kind: VMOperationKind) {
        self.init(resourceKind: .virtualMachine, resourceID: vmID, userID: userID, kind: kind)
    }

    convenience init(sandboxID: UUID, userID: UUID, kind: VMOperationKind) {
        self.init(resourceKind: .sandbox, resourceID: sandboxID, userID: userID, kind: kind)
    }
}

extension ResourceOperation {
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

    var completionBudgetSeconds: TimeInterval {
        resourceKind.completionBudgetSeconds(for: kind)
    }

    var completionBudget: Duration {
        .seconds(Int64(completionBudgetSeconds))
    }
}

extension ResourceOperation {
    /// Creates the pending operation record and applies the resource's
    /// in-flight mutation in one transaction, rejecting with `409 Conflict`
    /// when any operation is already pending for the resource — the
    /// double-submit guard from issue #259. `mutation` runs inside the same
    /// transaction, after the insert, so the resource change commits (or rolls
    /// back) atomically with the operation record (issue #260).
    static func begin(
        _ kind: VMOperationKind,
        resourceKind: OperationResourceKind,
        resourceID: UUID,
        userID: UUID,
        on db: Database,
        applying mutation: @escaping @Sendable (any Database) async throws -> Void = { _ in }
    ) async throws -> ResourceOperation {
        try await db.transaction { db in
            // Read first for a friendly reason naming the conflicting kind; the
            // partial unique index on pending operations (GeneralizeVMOperations)
            // is what actually closes the race when two mutations arrive at once.
            if let pending = try await ResourceOperation.query(on: db)
                .filter(\.$resourceKind == resourceKind)
                .filter(\.$resourceID == resourceID)
                .filter(\.$status == .pending)
                .first()
            {
                throw Abort(
                    .conflict,
                    reason:
                        "A \(pending.kind.rawValue) operation is already pending for this \(resourceKind.displayName)"
                )
            }

            let operation = ResourceOperation(
                resourceKind: resourceKind, resourceID: resourceID, userID: userID, kind: kind)
            do {
                try await operation.save(on: db)
            } catch let error as any DatabaseError where error.isConstraintFailure {
                throw Abort(
                    .conflict,
                    reason: "An operation is already pending for this \(resourceKind.displayName)")
            }

            try await mutation(db)

            return operation
        }
    }
}

// MARK: - Response DTO

/// Wire shape of an operation. `vmId` predates the resource-kind
/// generalization and is kept verbatim — it is what the frontend's operation
/// polling decodes — even though for a sandbox operation it carries the
/// sandbox's id; `resourceKind`/`resourceId` are the kind-aware fields new
/// clients should read.
struct OperationResponse: Content {
    let id: UUID?
    let vmId: UUID
    let resourceKind: OperationResourceKind
    let resourceId: UUID
    let kind: VMOperationKind
    let status: VMOperationStatus
    let error: String?
    let createdAt: Date?
    let completedAt: Date?

    init(from operation: ResourceOperation) {
        self.id = operation.id
        self.vmId = operation.resourceID
        self.resourceKind = operation.resourceKind
        self.resourceId = operation.resourceID
        self.kind = operation.kind
        self.status = operation.status
        self.error = operation.error
        self.createdAt = operation.createdAt
        self.completedAt = operation.completedAt
    }
}
