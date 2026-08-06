import Fluent
import SQLKit
import StratoShared
import Vapor

/// How far a resource is from the state the API was last asked to put it in
/// (ADR 0001 stage 1, STR-142) — the answer clients currently get only by
/// polling the `ResourceOperation` a mutation returned.
///
/// Every field is derived on read — from the resource's generation counters
/// and the convergence progress `ObservedStateApplier` mirrors off each agent
/// report. Nothing is stored in this shape and no mutation writes it. That is
/// deliberate: operation completion is *already* this derivation
/// (`ObservedStateApplier`: succeeded ⇔ `observedGeneration >= generation` ∧
/// the desired status is satisfied; failed ⇔ `failedGeneration == generation`),
/// so projecting it onto the resource replaces a hand-maintained side-table
/// with a view of the reconciliation loop's own state. A client that refetches
/// the resource until `converged` is true needs no operation at all.
///
/// The operations API is untouched here — this is additive.
struct ResourceConditions: Content, Equatable {
    /// True once the owning agent has confirmed converging to
    /// `targetGeneration` *and* what it observes satisfies the desired state.
    /// Both halves matter: an agent can acknowledge a generation while the
    /// workload is still, say, `error`.
    ///
    /// Always false for a resource whose desired state is `absent`: a
    /// terminating row is on its way out, not converging on anything. The
    /// agent's confirmation clears the `agent.absent` finalizer rather than
    /// satisfying a desired status (STR-144), and the row is reaped once the
    /// last participant is done.
    let converged: Bool
    /// The generation the resource is trying to reach: what the last mutation
    /// bumped it to.
    let targetGeneration: Int64
    /// The newest generation the owning agent has confirmed converging to. 0
    /// means no agent has ever confirmed this resource.
    let observedGeneration: Int64
    /// The agent's human-readable current step (e.g. "downloading image"),
    /// present only while it is actively working toward `targetGeneration`.
    /// Absent does not mean idle — an unplaced resource, or one whose agent is
    /// offline, reports no phase either.
    let phase: String?
    /// The last convergence attempt that failed, or nil if the most recent
    /// attempt succeeded. Present alongside a newer `targetGeneration` while a
    /// retry is in flight: the failure stands until something converges.
    let degraded: Degraded?

    /// Why a resource is not converging, and since when.
    struct Degraded: Content, Equatable {
        /// The agent's error from the failed attempt, verbatim.
        let reason: String
        /// The generation whose convergence produced `reason`. Compare with
        /// `targetGeneration` to tell a failure of the state currently being
        /// pursued from one a newer mutation has already superseded.
        let sinceGeneration: Int64
    }

    /// - Parameter desiredSatisfied: whether the observed status satisfies the
    ///   desired one — `DesiredVMStatus`/`DesiredSandboxStatus.isSatisfied(by:)`,
    ///   which the caller evaluates because the two enums are unrelated types.
    init(
        targetGeneration: Int64,
        observedGeneration: Int64,
        desiredSatisfied: Bool,
        phase: String?,
        lastError: String?,
        failedGeneration: Int64?
    ) {
        self.converged = observedGeneration >= targetGeneration && desiredSatisfied
        self.targetGeneration = targetGeneration
        self.observedGeneration = observedGeneration
        self.phase = phase
        // Both halves or neither: an error with no generation cannot be placed
        // against `targetGeneration`, which is the whole point of reporting it.
        if let lastError, let failedGeneration {
            self.degraded = Degraded(reason: lastError, sinceGeneration: failedGeneration)
        } else {
            self.degraded = nil
        }
    }
}

/// A resource that mirrors the convergence progress its owning agent reports
/// (STR-142). Implemented by `VM` and `Sandbox`, whose observed-state entries
/// carry identical `convergencePhase` / `lastError` / `failedGeneration`
/// fields, so `ObservedStateApplier` records both through one path.
protocol ConvergenceObservable: AnyObject {
    var convergencePhase: String? { get set }
    var lastError: String? { get set }
    var failedGeneration: Int64? { get set }
}

extension ConvergenceObservable {
    /// Mirrors one report's convergence progress onto the row, nils included:
    /// the agent drops a phase when it stops working and drops the error pair
    /// when an attempt finally succeeds, and a stale "downloading image" or a
    /// long-fixed failure would be worse than none. Returns whether anything
    /// changed so the steady stream of identical reports does no writes; does
    /// not persist — call `save(on:)` afterwards.
    func recordConvergence(
        phase: String?,
        lastError: String?,
        failedGeneration: Int64?
    ) -> Bool {
        guard
            convergencePhase != phase
                || self.lastError != lastError
                || self.failedGeneration != failedGeneration
        else { return false }
        convergencePhase = phase
        self.lastError = lastError
        self.failedGeneration = failedGeneration
        return true
    }
}

extension VM: ConvergenceObservable {}
extension Sandbox: ConvergenceObservable {}

/// A workload whose API mutations are accepted asynchronously and judged by
/// the reconciliation loop rather than by an operation row (ADR 0001 stage 4,
/// STR-147).
///
/// This is the seam `ResourceMutation`, the stuck-convergence sweep, and the
/// operations façade share, so each of them is written once for both workload
/// kinds instead of switching on `OperationResourceKind` at every step.
/// Everything on it already existed on `VM` and `Sandbox`; only
/// `convergenceDeadline` is new.
protocol ConvergingResource: Model, ConvergenceObservable, Sendable where IDValue == UUID {
    static var operationResourceKind: OperationResourceKind { get }

    var name: String { get }
    var projectID: UUID { get }

    /// The agent this workload is placed on, or nil if it never reached one.
    var hypervisorId: String? { get }

    var generation: Int64 { get }
    var observedGeneration: Int64 { get }
    var convergenceDeadline: Date? { get set }

    /// The owning agent has confirmed the current generation and what it
    /// observes satisfies the desired state — `conditions.converged`, in the
    /// shape the reconciliation paths want it.
    var isConverged: Bool { get }

    /// Derived on read from the columns above — the client-facing answer to
    /// "is this mutation done?".
    var conditions: ResourceConditions { get }

    /// Resolves the in-flight state a failed mutation left behind. Returns
    /// whether anything changed; does not persist.
    @discardableResult
    func resolveForStuckOperation(mutation: VMOperationKind, telemetryReason: String) -> Bool

    /// Rows whose convergence deadline has passed — the stuck-convergence
    /// sweep's whole query. A protocol requirement rather than a generic
    /// extension because Fluent filters on the model's own field *projection*
    /// (`\.$convergenceDeadline`), which a protocol cannot name. Rows with no
    /// deadline are excluded by SQL's `NULL` comparison, which is the wanted
    /// behaviour: nothing is outstanding on them.
    static func overdueForConvergence(at now: Date, on db: any Database) async throws -> [Self]
}

extension ConvergingResource {
    /// Claims the right to declare this resource's outstanding convergence
    /// timed out, by clearing the deadline in a conditional `UPDATE`.
    ///
    /// This is what makes the stuck-convergence sweep safe to run on every
    /// replica *and* exactly-once per deadline (STR-147). Marking degraded is
    /// idempotent and convergent on its own — the state two replicas write is
    /// the same — but the completion webhook is not, so the claim decides which
    /// pass gets to emit it. `AND convergence_deadline IS NOT NULL` is
    /// evaluated by PostgreSQL under the row lock, so of two racing sweeps
    /// exactly one updates a row: the same compare-and-swap technique as
    /// `ResourceOperation.completeIfPending`, without the cluster lock.
    func claimConvergenceTimeout(on db: any Database) async throws -> Bool {
        guard let sql = db as? any SQLDatabase else {
            throw OperationCompletionError.unsupportedDatabase
        }
        let claimed = try await sql.raw(
            """
            UPDATE \(ident: Self.schema)
            SET convergence_deadline = NULL
            WHERE id = \(bind: try requireID()) AND convergence_deadline IS NOT NULL
            RETURNING id
            """
        ).all(decoding: ClaimedConvergenceRow.self)
        guard !claimed.isEmpty else { return false }
        convergenceDeadline = nil
        return true
    }
}

/// `RETURNING id` from the claim above. A file-scope type because a generic
/// function cannot nest one.
private struct ClaimedConvergenceRow: Decodable {
    let id: UUID
}

extension ConvergingResource {
    /// Pushes the convergence deadline out to cover a mutation with `budget`
    /// seconds to converge, never pulling it in.
    ///
    /// The `max` is the whole point (STR-147). With the "operation already
    /// pending" mutex dropped, mutations of different kinds overlap: a reboot
    /// issued against a VM whose 600s create is still downloading its image
    /// would, under a plain assignment, hand the create a 120s runway and flip
    /// a perfectly healthy resource to degraded. Extending only forward means
    /// the outstanding work is always judged against the most generous budget
    /// anything asked for.
    func extendConvergenceDeadline(by budget: TimeInterval, from now: Date = Date()) {
        let candidate = now.addingTimeInterval(budget)
        if let existing = convergenceDeadline, existing > candidate { return }
        convergenceDeadline = candidate
    }
}

extension VM: ConvergingResource {
    static var operationResourceKind: OperationResourceKind { .virtualMachine }
    var projectID: UUID { $project.id }

    static func overdueForConvergence(at now: Date, on db: any Database) async throws -> [VM] {
        try await VM.query(on: db).filter(\.$convergenceDeadline <= now).all()
    }
}

extension Sandbox: ConvergingResource {
    static var operationResourceKind: OperationResourceKind { .sandbox }
    var projectID: UUID { $project.id }

    static func overdueForConvergence(at now: Date, on db: any Database) async throws -> [Sandbox] {
        try await Sandbox.query(on: db).filter(\.$convergenceDeadline <= now).all()
    }
}

extension VM {
    var conditions: ResourceConditions {
        ResourceConditions(
            targetGeneration: generation,
            observedGeneration: observedGeneration,
            desiredSatisfied: desiredStatus.isSatisfied(by: status),
            phase: convergencePhase,
            lastError: lastError,
            failedGeneration: failedGeneration
        )
    }
}

extension Sandbox {
    var conditions: ResourceConditions {
        ResourceConditions(
            targetGeneration: generation,
            observedGeneration: observedGeneration,
            desiredSatisfied: desiredStatus.isSatisfied(by: status),
            phase: convergencePhase,
            lastError: lastError,
            failedGeneration: failedGeneration
        )
    }
}
