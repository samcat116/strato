import Fluent
import StratoShared
import Vapor

/// Answers the operations API for mutations that no longer have an operation
/// row (ADR 0001 stage 4, STR-147).
///
/// Lifecycle mutations stopped writing `resource_operations`; what they write
/// is a `resource_events` row and a desired-state change. Everything an
/// operation used to report is recoverable from those two — the id and kind
/// from the event, the verdict from the resource's `conditions` — so
/// `GET /api/operations/{id}` and the per-resource lists keep answering for
/// old clients while nothing new depends on the table.
///
/// This is a *view*, not a store: it holds no state, and every value it returns
/// is derived at read time. When the last imperative operation kind converts
/// (STR-151, ADR stage 8) the table and its coordinator go, and this stays.
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

    /// One resource's operation history, newest first: the mutations recorded
    /// in `resource_events` merged with whatever operation rows the still
    /// imperative verbs (VM reboot, the snapshot verbs) wrote.
    ///
    /// Merged rather than replaced, because both are real: a snapshot's row is
    /// the only record of it, and a lifecycle mutation's event is the only
    /// record of *that*. Deliberately over-fetches `limit` from each side
    /// before the merge — the alternative is a `UNION` across two tables with
    /// different shapes for a list that is capped at 100 rows.
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
        let operations = try await ResourceOperation.recent(
            resourceKind: resourceKind, resourceID: resourceID, limit: limit, on: db)

        let events = try await ResourceEvent.query(on: db)
            .filter(\.$resourceKind == resourceKind)
            .filter(\.$resourceID == resourceID)
            .filter(\.$phase == .requested)
            .sort(\.$createdAt, .descending)
            .limit(limit)
            .all()

        var responses = operations.map { OperationResponse(from: $0) }
        if !events.isEmpty {
            let view = try await view(of: resourceKind, id: resourceID, on: db)
            responses += events.map { response(for: $0, in: view) }
        }
        return
            responses
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }
}
