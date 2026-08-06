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

    /// Synthesizes the operation view of one recorded mutation.
    ///
    /// `event` must be a `.requested` row; terminal rows are the *evidence*
    /// this reads, not its subject.
    static func response(for event: ResourceEvent, on db: any Database) async throws -> OperationResponse {
        let verdict = try await self.verdict(for: event, on: db)
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

    /// The rules, in the order they are checked:
    ///
    /// 1. **A delete with a terminal event** succeeded — the positive record
    ///    the reap appends, and the only honest answer once the resource is
    ///    gone, since `404` on the resource means deleted, never-existed and
    ///    not-authorized alike.
    /// 2. **A delete whose resource is gone with no terminal event** also
    ///    succeeded. The fallback covers rows removed by a path that predates
    ///    the terminal event (a delete in flight across the deploy that added
    ///    it) or one that bypasses the reap entirely, and is still a two-part
    ///    positive signal: the request is recorded and the resource is provably
    ///    absent. It reports no `completedAt`, which is the honest thing to say
    ///    about a completion nothing recorded.
    /// 3. **A failure at this generation** — the resource's `degraded` block
    ///    naming exactly the generation this mutation targeted.
    /// 4. **Convergence at or past this generation** succeeded, whether by the
    ///    agent reaching it or by a later mutation superseding it. A mutation
    ///    the reconciler has moved past is not left `pending` forever.
    /// 5. Anything else is still `pending`.
    static func verdict(for event: ResourceEvent, on db: any Database) async throws -> Verdict {
        if event.mutation == .delete {
            if let terminal = try await terminalEvent(for: event, on: db) {
                return Verdict(status: .succeeded, error: nil, completedAt: terminal.createdAt)
            }
            if try await !resourceExists(kind: event.resourceKind, id: event.resourceID, on: db) {
                return Verdict(status: .succeeded, error: nil, completedAt: nil)
            }
        }

        guard
            let conditions = try await conditions(
                kind: event.resourceKind, id: event.resourceID, on: db)
        else {
            // Gone, and not a delete: whatever this mutation was doing, the
            // resource it was doing it to no longer exists.
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
        if conditions.observedGeneration >= target {
            // Superseded mutations count as succeeded: their generation was
            // reached, and the newer one owns whatever happens next.
            if conditions.converged || conditions.targetGeneration > target {
                return Verdict(status: .succeeded, error: nil, completedAt: nil)
            }
        }
        return Verdict(status: .pending, error: nil, completedAt: nil)
    }

    /// The newest terminal event recorded after `event` was requested. Scoped
    /// by time so a resource id reused by a later create — which cannot happen
    /// today, but costs one comparison to rule out — cannot answer an older
    /// request.
    private static func terminalEvent(
        for event: ResourceEvent, on db: any Database
    ) async throws -> ResourceEvent? {
        guard
            let terminal = try await ResourceEvent.latest(
                .completed, resourceKind: event.resourceKind, resourceID: event.resourceID, on: db)
        else { return nil }
        guard let requestedAt = event.createdAt, let completedAt = terminal.createdAt else {
            return terminal
        }
        return completedAt >= requestedAt ? terminal : nil
    }

    private static func resourceExists(
        kind: OperationResourceKind, id: UUID, on db: any Database
    ) async throws -> Bool {
        switch kind {
        case .virtualMachine: return try await VM.find(id, on: db) != nil
        case .sandbox: return try await Sandbox.find(id, on: db) != nil
        }
    }

    /// The resource's conditions block, or nil if the row is gone.
    private static func conditions(
        kind: OperationResourceKind, id: UUID, on db: any Database
    ) async throws -> ResourceConditions? {
        switch kind {
        case .virtualMachine: return try await VM.find(id, on: db)?.conditions
        case .sandbox: return try await Sandbox.find(id, on: db)?.conditions
        }
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
        for event in events {
            responses.append(try await response(for: event, on: db))
        }
        return
            responses
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }
}
