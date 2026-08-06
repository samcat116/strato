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
