import Fluent
import SQLKit
import Vapor
import StratoShared

/// The kind of resource an asynchronous operation acts on — the
/// `resource_kind` discriminator on `ResourceOperation` (issue #412). Each
/// kind brings its own operation budgets, stuck-resource resolution, and
/// visibility rule; adding a resource type means extending the switches that
/// dispatch on this enum, not forking the 202/poll/sweep machinery.
enum OperationResourceKind: String, Codable, CaseIterable, Sendable, Hashable {
    case virtualMachine = "virtual_machine"
    case sandbox = "sandbox"
    case volume = "volume"
    // Snapshot artifacts (ADR 0001 stage 8, STR-150). Three kinds rather than
    // one, because they are three tables with three quota paths, three IAM node
    // types and three very different completion budgets — a qcow2 overlay is
    // seconds and a full-VM checkpoint is the guest's whole RAM at disk speed.
    // What they share is a *shape*, and that is carried by the protocols below
    // rather than by collapsing them into one discriminator.
    case volumeSnapshot = "volume_snapshot"
    case vmCheckpoint = "vm_checkpoint"
    case sandboxSnapshot = "sandbox_snapshot"

    /// Short noun for client-facing messages ("An operation is already
    /// pending for this VM").
    var displayName: String {
        switch self {
        case .virtualMachine:
            return "VM"
        case .sandbox:
            return "sandbox"
        case .volume:
            return "volume"
        case .volumeSnapshot:
            return "volume snapshot"
        case .vmCheckpoint:
            return "checkpoint"
        case .sandboxSnapshot:
            return "sandbox snapshot"
        }
    }

    /// The artifact family this kind names, or nil for a live resource.
    var snapshotArtifactKind: SnapshotArtifactKind? {
        switch self {
        case .volumeSnapshot: return .volumeSnapshot
        case .vmCheckpoint: return .vmCheckpoint
        case .sandboxSnapshot: return .sandboxSnapshot
        case .virtualMachine, .sandbox, .volume: return nil
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
            case .resize:
                // Hot-add is a couple of QMP commands; the budget covers a
                // sync round trip and the agent's next observed report, not
                // the guest's own onlining (which the operation doesn't wait
                // for).
                return 120
            case .snapshot, .restore:
                // Full-VM checkpoint / restore (issue #564): QEMU writes or
                // reads the whole guest RAM through a background job, so the
                // cost scales with the memory grant at disk speed. Sized like
                // the sandbox checkpoint budget, and above the agent's own
                // stage budget so the RPC verdict — not the sweep — decides
                // the operation whenever the dispatching replica survives.
                return 1800
            case .snapshotDelete:
                // Dropping a qcow2 internal snapshot rewrites metadata, not
                // data.
                return 120
            case .snapshotExport:
                // Unreachable for VMs: a checkpoint lives inside the VM's own
                // disks, and moving one off-node is out of scope for v1
                // (issue #564). The budget function stays total.
                return 300
            case .attach, .detach, .throttle:
                // Volume-only kinds (STR-148, STR-19); unreachable for VMs.
                // Total function, unreachable arm.
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
            case .shutdown, .reboot, .pause, .resume, .resize:
                // Pause/resume/resize are unreachable for sandboxes (no
                // endpoint issues them) but the budget function stays total.
                return 120
            case .snapshot:
                // Checkpoint copies the guest memory file plus a full rootfs
                // on filesystems without reflink support (issue #426).
                return 600
            case .restore:
                // A local restore is the same class of copy, but a cross-agent
                // one stages the whole archive from object storage first
                // (issue #428) — the budget has to cover the slower shape,
                // since it is keyed by kind and both share `.restore`.
                return 3600
            case .snapshotExport:
                // Export streams the whole archive (guest memory + rootfs)
                // through the control plane into object storage (issue #428),
                // so it is bounded by the network, not local disk.
                return 3600
            case .snapshotDelete:
                return 120
            case .attach, .detach, .throttle:
                // Unreachable for sandboxes (no endpoint issues them); the
                // budget function stays total.
                return 120
            }
        case .volume:
            switch kind {
            case .create:
                // Covers the two slow create strategies: materializing a
                // multi-gigabyte image, and `qemu-img convert`-ing a full
                // clone of another volume.
                return 900
            case .delete:
                return 300
            case .resize:
                // `qemu-img resize` grows metadata, not data; the budget
                // covers a sync round trip and the agent's next report.
                return 180
            case .attach, .detach:
                // A QMP hot-plug, or — for a powered-off guest — just the
                // agent recording the attachment.
                return 120
            case .throttle:
                // Setting a ceiling moves no bytes at all (STR-19): the budget
                // covers a sync round trip and the agent's next report, like
                // the resize arm above.
                return 180
            case .boot, .shutdown, .reboot, .pause, .resume,
                .snapshot, .snapshotDelete, .restore, .snapshotExport:
                // A volume has no run state, and its snapshot artifacts are
                // their own resource kinds since STR-150. Total function,
                // unreachable arms.
                return 120
            }

        // Snapshot artifacts (STR-150). `create` is the capture and the only
        // budget that differs meaningfully between the families; everything
        // else is metadata work or unreachable. The figures are the ones the
        // retired `ResourceOperation` budgets used for the same work, moved
        // from the parent resource onto the artifact where they belong.
        case .volumeSnapshot:
            switch kind {
            case .create:
                // A qcow2 overlay is a metadata write, but it is taken against
                // a volume that may be many gigabytes and on a busy host.
                return 300
            case .delete:
                return 120
            case .boot, .shutdown, .reboot, .pause, .resume, .resize,
                .snapshot, .snapshotDelete, .restore, .snapshotExport, .attach, .detach, .throttle:
                return 120
            }

        case .vmCheckpoint:
            switch kind {
            case .create:
                // QEMU writes the whole guest RAM through a background job, so
                // the cost scales with the memory grant at disk speed.
                return 1800
            case .delete:
                // Dropping an internal snapshot rewrites metadata, not data.
                return 120
            case .boot, .shutdown, .reboot, .pause, .resume, .resize,
                .snapshot, .snapshotDelete, .restore, .snapshotExport, .attach, .detach, .throttle:
                return 120
            }

        case .sandboxSnapshot:
            switch kind {
            case .create:
                // The guest memory file plus, without reflink support, a full
                // rootfs copy.
                return 600
            case .snapshotExport:
                // The whole archive streams through the control plane into
                // object storage, so this is bounded by the network rather than
                // by local disk.
                return 3600
            case .delete:
                return 120
            case .boot, .shutdown, .reboot, .pause, .resume, .resize,
                .snapshot, .snapshotDelete, .restore, .attach, .detach, .throttle:
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

    /// Webhook delivery context, captured by `begin` while the resource row
    /// still exists (PR #668 review). Like `resource_id`, deliberately
    /// FK-free: a delete operation's completion event must be deliverable
    /// after the resource — and its name — are gone. Nil on rows that predate
    /// the column or bypassed `begin`; those resolve from the live resource.
    @OptionalField(key: "organization_id")
    var organizationID: UUID?

    @OptionalField(key: "project_id")
    var projectID: UUID?

    @OptionalField(key: "resource_name")
    var resourceName: String?

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

/// Why a completion could not be recorded at all — as opposed to losing the
/// compare-and-swap, which is an ordinary `false` return.
enum OperationCompletionError: Error, CustomStringConvertible, Sendable {
    /// The verdict guard is a conditional `UPDATE`, so it needs the SQL
    /// interface. Every supported deployment is PostgreSQL; this exists so a
    /// database that cannot express the compare-and-swap fails loudly instead
    /// of silently double-completing operations.
    case unsupportedDatabase

    var description: String {
        switch self {
        case .unsupportedDatabase:
            return "Recording an operation verdict requires an SQL database"
        }
    }
}

extension ResourceOperation {
    /// The actor recorded on operations the control plane starts by itself,
    /// with no user behind them — today the sandbox expiry sweep (issue #424).
    /// `user_id` deliberately has no foreign key (operations outlive the rows
    /// they delete), so a sentinel matching no real user is safe. It also
    /// scopes visibility sensibly: `OperationController` shows an operation to
    /// its initiator or a system admin, and an unattended deletion has no
    /// initiator to show it to.
    static let systemUserID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// Marks the operation terminal if — and only if — it is still pending, so
    /// the two completion paths (agent response and stuck-operation sweep)
    /// cannot overwrite each other's verdict. Returns whether this call won.
    ///
    /// The pending check is a database compare-and-swap, not an in-memory read
    /// of `self.status` (issue #733): the completion paths hold separately
    /// loaded instances and are not serialized against each other, so an
    /// in-memory guard passes on both while the blind `UPDATE ... WHERE id = ?`
    /// behind `save` lets the second one overwrite the first's verdict. The
    /// `AND status = 'pending'` predicate is instead evaluated by PostgreSQL
    /// under the row lock, so of two racing transactions exactly one updates a
    /// row. Same technique as `WebhookDeliveryService.claimDueDeliveries`.
    ///
    /// The winning flip also enqueues `operation.completed`/`operation.failed`
    /// webhook deliveries (issue #559), in the same transaction as the status
    /// write: because every completion path funnels through here, this is the
    /// one place the outbox rows commit atomically with the verdict — and the
    /// "only the winner" guard means the event is enqueued exactly once.
    func completeIfPending(as status: VMOperationStatus, error: String?, on db: Database) async throws -> Bool {
        guard let id = self.id else { return false }
        let completedAt = Date()

        return try await db.transaction { db in
            guard let sql = db as? any SQLDatabase else {
                throw OperationCompletionError.unsupportedDatabase
            }
            struct CompletedRow: Decodable {
                let id: UUID
            }
            let updated = try await sql.raw(
                """
                UPDATE resource_operations
                SET status = \(bind: status.rawValue),
                    error = \(bind: error),
                    completed_at = \(bind: completedAt)
                WHERE id = \(bind: id)
                  AND status = \(bind: VMOperationStatus.pending.rawValue)
                RETURNING id
                """
            ).all(decoding: CompletedRow.self)
            // Zero rows: another path already took this operation terminal.
            guard !updated.isEmpty else { return false }

            // Carry the committed verdict onto this instance — the webhook
            // payload reads it, and callers keep using the model afterwards.
            self.status = status
            self.error = error
            self.completedAt = completedAt
            try await WebhookEvents.enqueueOperationCompletion(for: self, on: db)
            return true
        }
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
            // Capture the resource's scope while its row still exists — a
            // delete's completion event has nothing left to resolve against
            // once the row is removed (PR #668 review). It is the operation's
            // webhook delivery context and, below, the event's.
            //
            // These three stamp independently: a resource whose project has no
            // organization records its project and name with a nil
            // `organization_id`, where the earlier all-or-nothing capture left
            // all three nil. Delivery is unchanged — the only reader,
            // `WebhookEvents.enqueueOperationCompletion`, guards on
            // `organizationID` — but a future reader of `projectID` should
            // know it can be set on a row that has no deliverable context.
            var scope = try await ResourceEvent.scope(of: resourceKind, id: resourceID, on: db)
            operation.organizationID = scope.organizationID
            operation.projectID = scope.projectID
            operation.resourceName = scope.resourceName
            do {
                try await operation.save(on: db)
            } catch let error as any DatabaseError where error.isConstraintFailure {
                throw Abort(
                    .conflict,
                    reason: "An operation is already pending for this \(resourceKind.displayName)")
            }

            try await mutation(db)

            // The append-only attribution record (ADR 0001, stage 2),
            // dual-written with the operation row until the operations table
            // retires. In the mutation's transaction, so the trail cannot
            // disagree with what actually applied.
            //
            // Only the generation is re-read: the event's target generation is
            // the one the mutation just set, and a mutation closure moves
            // nothing else the scope carries.
            scope.generation = try await ResourceEvent.generation(
                of: resourceKind, id: resourceID, on: db)
            try await ResourceEvent.record(
                kind,
                resourceKind: resourceKind,
                resourceID: resourceID,
                actor: MutationActor(operationUserID: userID),
                scope: scope,
                on: db)

            return operation
        }
    }

    /// The resource's operation history, newest first — what the `GET
    /// /<resource>/:id/operations` handlers return once their own permission
    /// check has produced the id. The query is identical for every resource
    /// kind, so it lives here rather than once per controller.
    static func recent(
        resourceKind: OperationResourceKind,
        resourceID: UUID,
        limit: Int,
        on db: Database
    ) async throws -> [ResourceOperation] {
        try await ResourceOperation.query(on: db)
            .filter(\.$resourceKind == resourceKind)
            .filter(\.$resourceID == resourceID)
            .sort(\.$createdAt, .descending)
            .limit(limit)
            .all()
    }
}

// MARK: - Response DTO

/// Wire shape of an operation. `vmId` predates the resource-kind
/// generalization and is kept verbatim — it is what the frontend's operation
/// polling decodes — even though for a sandbox operation it carries the
/// sandbox's id; `resourceKind`/`resourceId` are the kind-aware fields new
/// clients should read.
///
/// Since STR-147 this shape is served from two sources: rows of this table, for
/// the verbs still dispatched as imperative agent RPCs, and `OperationFacade`'s
/// synthesis over `resource_events` + the resource's `conditions`, for the
/// lifecycle mutations that stopped writing rows. Nothing about the wire shape
/// distinguishes them, which is the point.
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

    init(
        id: UUID?,
        resourceKind: OperationResourceKind,
        resourceID: UUID,
        kind: VMOperationKind,
        status: VMOperationStatus,
        error: String?,
        createdAt: Date?,
        completedAt: Date?
    ) {
        self.id = id
        self.vmId = resourceID
        self.resourceKind = resourceKind
        self.resourceId = resourceID
        self.kind = kind
        self.status = status
        self.error = error
        self.createdAt = createdAt
        self.completedAt = completedAt
    }

    init(from operation: ResourceOperation) {
        self.init(
            id: operation.id,
            resourceKind: operation.resourceKind,
            resourceID: operation.resourceID,
            kind: operation.kind,
            status: operation.status,
            error: operation.error,
            createdAt: operation.createdAt,
            completedAt: operation.completedAt)
    }
}

extension ResourceOperation {
    /// `202 Accepted` carrying the operation record for the client to poll.
    /// Every async mutation endpoint — VM or sandbox — returns this shape.
    func acceptedResponse() throws -> Response {
        let response = Response(status: .accepted)
        try response.content.encode(OperationResponse(from: self))
        return response
    }
}
