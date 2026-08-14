import Fluent
import StratoShared
import Vapor

/// The kind of resource an asynchronous mutation acts on — the `resource_kind`
/// discriminator on `ResourceEvent`, the key `ConvergingResource` and
/// `SnapshotArtifactResource` project themselves under, and the discriminator
/// the operations façade resolves an id against.
///
/// It was `ResourceOperation`'s column first (issue #412) and outlived that
/// table (STR-152) because everything hung on it is about the *mutation*, not
/// about the row: the kind's display noun, the artifact family it names, and
/// the per-kind convergence budgets — which are the same figures the operation
/// rows used, now stamped as `convergence_deadline` rather than compared
/// against a row's age.
enum OperationResourceKind: String, Codable, CaseIterable, Sendable, Hashable {
    case virtualMachine = "virtual_machine"
    case sandbox = "sandbox"
    case volume = "volume"
    // Snapshot artifacts (ADR 0001 stage 8, STR-150). Three kinds rather than
    // one, because they are three tables with three quota paths and three IAM
    // node types. What they share is a *shape*, and that is carried by the
    // protocols on the models rather than by collapsing them into one
    // discriminator.
    case volumeSnapshot = "volume_snapshot"
    case vmCheckpoint = "vm_checkpoint"
    case sandboxSnapshot = "sandbox_snapshot"

    /// Short noun for client-facing messages ("This VM no longer exists").
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

    /// How long a mutation of `kind` on this resource kind may run before the
    /// stuck-convergence sweep declares it timed out — the figure
    /// `extendConvergenceDeadline` stamps at accept time.
    ///
    /// These are the `ResourceOperation` completion budgets, unchanged. What
    /// changed is what reads them: the row's `created_at` plus its budget was
    /// the deadline, and now the deadline is a column, so a mutation's runway
    /// survives without a row to hang it on.
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
                // the guest's own onlining (which nothing waits for).
                return 120
            case .snapshot, .restore:
                // Full-VM checkpoint / restore (issue #564): QEMU writes or
                // reads the whole guest RAM through a background job, so the
                // cost scales with the memory grant at disk speed.
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
        // else is metadata work or unreachable.
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

/// Answers the operations API for mutations that keep no operation row (ADR
/// 0001 stage 4, STR-147; the row itself retired in stage 11, STR-152).
///
/// What a mutation writes is a `resource_events` row and a desired-state
/// change. Everything an operation used to report is recoverable from those
/// two — the id and kind from the event, the verdict from the resource's
/// `conditions` — so `GET /api/operations/{id}` and the per-resource lists keep
/// answering for clients that poll them, which is still how a **delete**'s
/// outcome is read: its success is the resource's absence, which no resource
/// can report about itself.
///
/// This is a *view*, not a store: it holds no state, and every value it returns
/// is derived at read time.
enum OperationFacade {

    /// The mutation's outcome, synthesized from the resource it acted on.
    struct Verdict {
        let status: VMOperationStatus
        let error: String?
        let completedAt: Date?
    }

    /// Everything the verdict rules read, resolved once per *resource* rather
    /// than once per event. Both lookups are the same for every mutation on
    /// one resource, and `history` returns up to a hundred of them.
    struct ResourceView {
        /// The resource's conditions, or nil once its row is gone.
        let conditions: ResourceConditions?
        /// The newest terminal event, if the deletion has been recorded.
        let terminal: ResourceEvent?
    }

    static func view(
        of kind: OperationResourceKind, id: UUID, on db: any Database
    ) async throws -> ResourceView {
        let conditions: ResourceConditions?
        switch kind {
        case .virtualMachine: conditions = try await VM.find(id, on: db)?.conditions
        case .sandbox: conditions = try await Sandbox.find(id, on: db)?.conditions
        case .volume: conditions = try await Volume.find(id, on: db)?.conditions
        case .volumeSnapshot: conditions = try await VolumeSnapshot.find(id, on: db)?.conditions
        case .vmCheckpoint: conditions = try await VMSnapshot.find(id, on: db)?.conditions
        case .sandboxSnapshot: conditions = try await SandboxSnapshot.find(id, on: db)?.conditions
        }
        // Only worth looking for once the resource is gone — the reap appends
        // it as the row goes, so a live resource cannot have one.
        let terminal =
            conditions == nil
            ? try await ResourceEvent.latest(.completed, resourceKind: kind, resourceID: id, on: db)
            : nil
        return ResourceView(conditions: conditions, terminal: terminal)
    }

    /// Synthesizes the operation view of one recorded mutation.
    ///
    /// `event` must be a `.requested` row; terminal rows are the *evidence*
    /// this reads, not its subject.
    static func response(for event: ResourceEvent, on db: any Database) async throws -> OperationResponse {
        let view = try await view(of: event.resourceKind, id: event.resourceID, on: db)
        return response(for: event, in: view)
    }

    static func response(for event: ResourceEvent, in view: ResourceView) -> OperationResponse {
        let verdict = self.verdict(for: event, in: view)
        return OperationResponse(
            id: event.id,
            resourceKind: event.resourceKind,
            resourceID: event.resourceID,
            kind: event.mutation,
            status: verdict.status,
            error: verdict.error,
            createdAt: event.createdAt,
            completedAt: verdict.completedAt)
    }

    /// **Delete** is judged only by evidence that the resource is gone, never
    /// by its conditions:
    ///
    /// * a terminal event recorded after the request → `succeeded`, dated by
    ///   that row;
    /// * no terminal event but no resource either → `succeeded` undated. The
    ///   fallback covers rows removed by a path that bypasses the reap (a
    ///   delete in flight across the deploy that added the terminal event, a
    ///   cascade), and is still a two-part positive signal;
    /// * otherwise `pending`, **including past the convergence deadline**.
    ///
    /// That last clause is deliberate. A delete that misses its budget is
    /// usually slow — a large disk, a finalizer participant waiting on a
    /// detach — not doomed, and the resource's `degraded` block would flip the
    /// verdict to `failed` only for the reap to flip it back to `succeeded` a
    /// minute later. Telling a user their delete failed and then deleting the
    /// resource anyway is the worst available answer, so the deadline informs
    /// the *resource* (where an operator can see why it is slow) and never the
    /// delete's own verdict.
    ///
    /// Every other mutation is judged from the resource:
    ///
    /// * `degraded` naming exactly the generation this mutation targeted →
    ///   `failed`;
    /// * convergence at or past that generation → `succeeded`, whether the
    ///   agent reached it or a later mutation superseded it, so a mutation the
    ///   reconciler has moved past is not left `pending` forever;
    /// * a resource that vanished under a non-delete → `failed`;
    /// * anything else → `pending`.
    static func verdict(for event: ResourceEvent, in view: ResourceView) -> Verdict {
        if event.mutation == .delete {
            if let terminal = view.terminal, isAfter(terminal, event) {
                return Verdict(status: .succeeded, error: nil, completedAt: terminal.createdAt)
            }
            if view.conditions == nil {
                return Verdict(status: .succeeded, error: nil, completedAt: nil)
            }
            return Verdict(status: .pending, error: nil, completedAt: nil)
        }

        guard let conditions = view.conditions else {
            return Verdict(
                status: .failed, error: "The resource was removed before the mutation converged",
                completedAt: nil)
        }

        // A mutation that bumped no generation (the resource was read back
        // after the mutation, so this is only nil for a row already gone) is
        // judged against the generation it was issued at.
        let target = event.targetGeneration ?? conditions.targetGeneration

        if let degraded = conditions.degraded, degraded.sinceGeneration == target {
            return Verdict(status: .failed, error: degraded.reason, completedAt: nil)
        }
        if conditions.observedGeneration >= target,
            conditions.converged || conditions.targetGeneration > target
        {
            return Verdict(status: .succeeded, error: nil, completedAt: nil)
        }
        return Verdict(status: .pending, error: nil, completedAt: nil)
    }

    /// Whether a terminal event was recorded after the request it would settle.
    /// Scoped by time so a resource id reused by a later create — which cannot
    /// happen today, but costs one comparison to rule out — cannot answer an
    /// older request.
    private static func isAfter(_ terminal: ResourceEvent, _ request: ResourceEvent) -> Bool {
        guard let requestedAt = request.createdAt, let completedAt = terminal.createdAt else {
            return true
        }
        return completedAt >= requestedAt
    }

    /// One resource's mutation history, newest first — what the
    /// `GET /<resource>/:id/operations` handlers return once their own
    /// permission check has produced the id.
    ///
    /// One source now: `resource_events`. It used to merge in the operation
    /// rows the still-imperative verbs wrote, and the merge went with them
    /// (STR-152) rather than the events half, because every verb records an
    /// event and none records a row.
    ///
    /// Every event here names the same resource, so the view the verdicts read
    /// is resolved once rather than per event: this is a list endpoint, and a
    /// point query per row is exactly the shape that turns one request into a
    /// hundred.
    static func history(
        resourceKind: OperationResourceKind,
        resourceID: UUID,
        limit: Int,
        on db: any Database
    ) async throws -> [OperationResponse] {
        let events = try await ResourceEvent.query(on: db)
            .filter(\.$resourceKind == resourceKind)
            .filter(\.$resourceID == resourceID)
            .filter(\.$phase == .requested)
            .sort(\.$createdAt, .descending)
            .limit(limit)
            .all()
        guard !events.isEmpty else { return [] }

        let view = try await view(of: resourceKind, id: resourceID, on: db)
        return events.map { response(for: $0, in: view) }
    }
}

// MARK: - Response DTO

/// Wire shape of an operation. `vmId` is a deprecated compatibility alias for
/// `resourceId`. It remains populated during its deprecation cycle, but is
/// optional in the contract so clients can stop depending on it;
/// `resourceKind`/`resourceId` are the canonical target fields.
///
/// Since STR-152 there is exactly one source: `OperationFacade`'s synthesis
/// over `resource_events` + the resource's `conditions`. The shape is unchanged
/// from when a `resource_operations` row could also answer, which is the point
/// — nothing about a client should have to notice which it was.
struct OperationResponse: Content {
    let id: UUID?
    let vmId: UUID?
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
}
