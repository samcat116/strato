import Fluent
import SQLKit
import StratoShared
import Vapor

/// Why a convergence write could not be attempted at all — as opposed to
/// losing a compare-and-swap, which is an ordinary `false` return.
///
/// Inherited from the retired `ResourceOperation.completeIfPending`, whose
/// verdict guard had the same requirement and the same reason for stating it.
enum ConvergenceWriteError: Error, CustomStringConvertible, Sendable {
    /// The claims below are conditional `UPDATE`s and a `SELECT ... FOR UPDATE`,
    /// so they need the SQL interface. Every supported deployment is
    /// PostgreSQL; this exists so a database that cannot express them fails
    /// loudly instead of silently letting two writers both win.
    case unsupportedDatabase

    var description: String {
        switch self {
        case .unsupportedDatabase:
            return "Recording resource convergence requires an SQL database"
        }
    }
}

/// How far a resource is from the state the API was last asked to put it in
/// (ADR 0001 stage 1, STR-142) — and, since STR-152, the only answer there is:
/// a mutation's `202` hands back a target generation, and the client refetches
/// the resource until its conditions settle.
///
/// Every field is derived on read — from the resource's generation counters
/// and the convergence progress `ObservedStateApplier` mirrors off each agent
/// report. Nothing is stored in this shape and no mutation writes it. That is
/// deliberate: operation completion was *already* this derivation
/// (`ObservedStateApplier`: succeeded ⇔ `observedGeneration >= generation` ∧
/// the desired status is satisfied; failed ⇔ `failedGeneration == generation`),
/// so projecting it onto the resource replaced a hand-maintained side-table
/// with a view of the reconciliation loop's own state.
struct ResourceConditions: Content, Equatable {
    /// True once the owning agent has confirmed converging to
    /// `targetGeneration`, what it observes satisfies the desired state, and no
    /// attempt at *that same generation* is on record as having failed. All
    /// three matter: an agent can acknowledge a generation while the workload is
    /// still, say, `error`, and it can acknowledge one and then fail a second
    /// work item at the very same number.
    ///
    /// That third clause makes this and `degraded` **mutually exclusive** at the
    /// target generation (STR-191), so a client always has exactly one verdict.
    /// Without it both could be true at once: the agent advances its applied
    /// generation only when a whole work item succeeds, but it plans more than
    /// one item per generation — a boot converges and stamps the number, then
    /// the drift-correcting resize planned at the same number fails. The rest of
    /// the control plane already called that a failure (`ObservedStateApplier`
    /// records it; the operations façade and the frontend's watcher both read
    /// `degraded` first), so this states the rule the system was following
    /// rather than leaving each reader to guess it.
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
    /// attempt succeeded. "Failed" means the agent refused or could not apply
    /// that attempt; it does not necessarily mean the agent gave up. A blocked
    /// failure at `targetGeneration` remains degraded while every sync retries
    /// it, and success later clears the condition without a generation bump.
    /// The condition can also stand alongside a newer `targetGeneration` while
    /// that newer mutation is in flight.
    let degraded: Degraded?

    /// Why a resource is not converging, and since when.
    struct Degraded: Content, Equatable {
        /// The agent's error from the failed attempt, verbatim.
        let reason: String
        /// The generation whose convergence produced `reason`. Compare with
        /// `targetGeneration` to tell a failure of the state currently being
        /// pursued from one a newer mutation has already superseded.
        let sinceGeneration: Int64
        /// When this error/generation pair was first observed. Nil on resource
        /// families that do not persist convergence-failure timestamps.
        let lastErrorAt: Date?
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
        failedGeneration: Int64?,
        lastErrorAt: Date? = nil
    ) {
        self.targetGeneration = targetGeneration
        self.observedGeneration = observedGeneration
        self.phase = phase
        // Both halves or neither: an error with no generation cannot be placed
        // against `targetGeneration`, which is the whole point of reporting it.
        if let lastError, let failedGeneration {
            self.degraded = Degraded(
                reason: lastError, sinceGeneration: failedGeneration, lastErrorAt: lastErrorAt)
        } else {
            self.degraded = nil
        }
        // Derived *from* `degraded` rather than alongside it: the two fields are
        // one verdict, and reading the assigned condition is what makes
        // "converged ∧ degraded at the target" unrepresentable instead of merely
        // unlikely. Reading `degraded?.sinceGeneration` rather than the
        // `failedGeneration` argument matters for the same reason — a failure
        // with no reason is not reportable and so is not a verdict, which keeps
        // this exactly the negation of "degraded names the target".
        self.converged =
            observedGeneration >= targetGeneration
            && desiredSatisfied
            && self.degraded?.sinceGeneration != targetGeneration
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

/// VM and Sandbox convergence state includes the failure timestamp and the
/// internal sustained-divergence claim. Other resource families retain the
/// common convergence fields without taking these workload-only columns.
protocol TimestampedConvergenceObservable: ConvergenceObservable {
    var lastErrorAt: Date? { get set }
    var divergenceDetectedAt: Date? { get set }
}

extension TimestampedConvergenceObservable {
    /// Mirrors convergence progress and timestamps a newly observed
    /// error/generation pair. Repeated heartbeats keep the original timestamp.
    func recordTimestampedConvergence(
        phase: String?,
        lastError: String?,
        failedGeneration: Int64?,
        at now: Date = Date()
    ) -> Bool {
        let errorPairChanged = self.lastError != lastError || self.failedGeneration != failedGeneration
        var changed = recordConvergence(
            phase: phase, lastError: lastError, failedGeneration: failedGeneration)

        let nextErrorAt: Date?
        if lastError == nil || failedGeneration == nil {
            nextErrorAt = nil
        } else if errorPairChanged || lastErrorAt == nil {
            nextErrorAt = now
        } else {
            nextErrorAt = lastErrorAt
        }
        if lastErrorAt != nextErrorAt {
            lastErrorAt = nextErrorAt
            changed = true
        }
        return changed
    }
}

extension VM: TimestampedConvergenceObservable {}
extension Sandbox: TimestampedConvergenceObservable {}
extension Volume: ConvergenceObservable {}

/// A resource whose `conditions` block and `isConverged` predicate are one
/// derivation over one set of columns.
///
/// Both used to be written out per family — four `isConverged` bodies and six
/// `conditions` properties — with doc comments asserting the pair could not
/// disagree. They could, and did (STR-191). The failure clause was in neither,
/// and the `desiredSatisfied` term had already drifted: the volume's and all
/// three snapshot families' `conditions` omitted the `desiredStatus == .present`
/// their `isConverged` required, and `SandboxSnapshot`'s omitted
/// `exportSatisfied` as well — the one family where that omission was live,
/// since the other two report `wantsExport == false` and inherit a constant
/// `true`. Each family now supplies only the term that genuinely differs, and
/// everything derived from it is written once.
protocol ConvergenceDerived: ConvergenceObservable {
    var generation: Int64 { get }
    var observedGeneration: Int64 { get }

    /// Whether what the owning agent observes satisfies what the desired state
    /// asks for — the one term the families do not share, because a VM's is a
    /// status predicate, a volume's is a resting status, and a snapshot
    /// artifact's is presence plus its export.
    var desiredSatisfied: Bool { get }
}

extension ConvergenceDerived {
    /// Derived on read — the client-facing answer to "is this mutation done?".
    var conditions: ResourceConditions {
        ResourceConditions(
            targetGeneration: generation,
            observedGeneration: observedGeneration,
            desiredSatisfied: desiredSatisfied,
            phase: convergencePhase,
            lastError: lastError,
            failedGeneration: failedGeneration,
            lastErrorAt: (self as? any TimestampedConvergenceObservable)?.lastErrorAt
        )
    }

    /// `conditions.converged` in the shape the reconciliation paths want it —
    /// the same value by construction rather than by assertion.
    ///
    /// Deliberately not a protocol *requirement*: a family free to supply its
    /// own witness is a family free to disagree with its own `conditions`, which
    /// is the bug this shape exists to make unrepresentable.
    var isConverged: Bool { conditions.converged }
}

/// A workload whose API mutations are accepted asynchronously and judged by
/// the reconciliation loop rather than by an operation row (ADR 0001 stage 4,
/// STR-147).
///
/// This is the seam `ResourceMutation`, the stuck-convergence sweep, and the
/// operations façade share, so each of them is written once for both workload
/// kinds instead of switching on `OperationResourceKind` at every step.
/// Everything on it already existed on `VM` and `Sandbox`; only
/// `convergenceDeadline` is new.
protocol AgentPlacedResource {
    /// Every agent whose desired-state sync carries this resource. Most
    /// resources have one placement; a volume derives the set from its active
    /// replica rows.
    func placementAgentIDs(on db: any Database) async throws -> [String]
}

protocol ConvergingResource: Model, ConvergenceDerived, AgentPlacedResource, Sendable
where IDValue == UUID {
    static var operationResourceKind: OperationResourceKind { get }

    /// Writable only so the shared SQL generation writer can copy the value
    /// returned by PostgreSQL back onto the model before its guarded save.
    var generation: Int64 { get set }

    var name: String { get }
    var projectID: UUID { get }

    var convergenceDeadline: Date? { get set }

    /// Resolves the in-flight state a failed mutation left behind. Returns
    /// whether desired state changed and therefore needs a new generation;
    /// observed-status realignment does not count. Does not persist.
    @discardableResult
    func resolveForStuckOperation(mutation: VMOperationKind, telemetryReason: String) -> Bool

    /// Rows whose convergence deadline has passed — the stuck-convergence
    /// sweep's whole query. A protocol requirement rather than a generic
    /// extension because Fluent filters on the model's own field *projection*
    /// (`\.$convergenceDeadline`), which a protocol cannot name. Rows with no
    /// deadline are excluded by SQL's `NULL` comparison, which is the wanted
    /// behaviour: nothing is outstanding on them.
    static func overdueForConvergence(at now: Date, on db: any Database) async throws -> [Self]

    /// Copies the columns the *reconciliation* loop owns — everything the
    /// observed-state applier, the scheduler's placement, the finalizer
    /// participants and other mutations write — from a freshly read row onto
    /// this instance.
    ///
    /// A mutation loads its resource in the route handler and later `save`s the
    /// whole row, so without this its pre-request snapshot of these columns
    /// would be written back over whatever committed in between:
    /// `observedGeneration` would go *backwards*, un-converging a client that
    /// was already satisfied, and placement the scheduler had just assigned
    /// could be overwritten. `ResourceMutation.accept` calls this under the
    /// row lock, before the mutation closure runs, so the closure builds on
    /// committed state.
    ///
    /// Deliberately not "copy everything": the guest telemetry (qga view,
    /// balloon stats, exit code) is re-reported on every agent poll and heals
    /// itself within seconds, so it is left out rather than growing this list
    /// with fields whose staleness has no lasting consequence.
    func adoptReconciliationState(from committed: Self)
}

enum ConvergenceTimeoutClaimOutcome: Equatable, Sendable {
    case claimed
    case alreadyClaimed
    case superseded(actualGeneration: Int64)
    case missing
}

extension ConvergingResource {
    @discardableResult
    func advanceDesiredStateGeneration(
        expectedGeneration: Int64? = nil, on db: any Database
    ) async throws -> DesiredStateGenerationWriter.Outcome {
        let outcome = try await DesiredStateGenerationWriter.advance(
            schema: Self.schema,
            id: try requireID(),
            expectedGeneration: expectedGeneration,
            on: db)
        if case .applied(let generation) = outcome {
            self.generation = generation
        }
        return outcome
    }

    /// Locks this resource's row for the rest of the caller's transaction and
    /// refreshes the reconciliation-owned columns from what is committed.
    ///
    /// The lock is what serializes concurrent API mutations on one resource,
    /// now that the "operation already pending" `409` is gone (STR-147): each
    /// one's generation bump lands on top of the last, so the loser's desired
    /// state is genuinely applied rather than silently overwritten by a stale
    /// snapshot — which would otherwise have the façade report a dropped
    /// mutation as succeeded. Returns false when the row is gone.
    func lockAndRefresh(on db: any Database) async throws -> Bool {
        guard let sql = db as? any SQLDatabase else {
            throw ConvergenceWriteError.unsupportedDatabase
        }
        let id = try requireID()
        let locked = try await sql.raw(
            "SELECT id FROM \(ident: Self.schema) WHERE id = \(bind: id) FOR UPDATE"
        ).all(decoding: ClaimedConvergenceRow.self)
        guard !locked.isEmpty else { return false }

        // Read *after* the lock so this sees whatever the writer we waited on
        // committed, not the snapshot our caller opened with.
        guard let committed = try await Self.find(id, on: db) else { return false }
        adoptReconciliationState(from: committed)
        return true
    }

    /// Claims the right to declare this resource's outstanding convergence
    /// timed out, by clearing the deadline in a conditional `UPDATE`.
    ///
    /// This is what makes the stuck-convergence sweep safe to run on every
    /// replica *and* exactly-once per deadline (STR-147). Marking degraded is
    /// idempotent and convergent on its own — the state two replicas write is
    /// the same — but the completion webhook is not, so the claim decides which
    /// pass gets to emit it. `AND convergence_deadline IS NOT NULL` is
    /// evaluated by PostgreSQL under the row lock, so of two racing sweeps
    /// exactly one updates a row — the compare-and-swap the retired
    /// stuck-operation sweep needed a cluster lock to approximate.
    func claimConvergenceTimeout(on db: any Database) async throws
        -> ConvergenceTimeoutClaimOutcome
    {
        guard let sql = db as? any SQLDatabase else {
            throw ConvergenceWriteError.unsupportedDatabase
        }
        let claimed = try await sql.raw(
            """
            UPDATE \(ident: Self.schema)
            SET convergence_deadline = NULL
            WHERE id = \(bind: try requireID())
              AND generation = \(bind: generation)
              AND convergence_deadline IS NOT NULL
            RETURNING id
            """
        ).all(decoding: ClaimedConvergenceRow.self)
        if !claimed.isEmpty {
            convergenceDeadline = nil
            return .claimed
        }

        guard
            let current = try await sql.raw(
                "SELECT generation FROM \(ident: Self.schema) WHERE id = \(bind: try requireID())"
            ).first(decoding: CurrentConvergenceGeneration.self)
        else { return .missing }
        guard current.generation == generation else {
            return .superseded(actualGeneration: current.generation)
        }
        return .alreadyClaimed
    }
}

/// `RETURNING id` from the claim above. A file-scope type because a generic
/// function cannot nest one.
private struct ClaimedConvergenceRow: Decodable {
    let id: UUID
}

private struct CurrentConvergenceGeneration: Decodable {
    let generation: Int64
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
    func placementAgentIDs(on db: any Database) async throws -> [String] {
        hypervisorId.map { [$0] } ?? []
    }

    static func overdueForConvergence(at now: Date, on db: any Database) async throws -> [VM] {
        try await VM.query(on: db).filter(\.$convergenceDeadline <= now).all()
    }

    func adoptReconciliationState(from committed: VM) {
        status = committed.status
        statusChangedAt = committed.statusChangedAt
        desiredStatus = committed.desiredStatus
        generation = committed.generation
        observedGeneration = committed.observedGeneration
        convergencePhase = committed.convergencePhase
        lastError = committed.lastError
        failedGeneration = committed.failedGeneration
        lastErrorAt = committed.lastErrorAt
        divergenceDetectedAt = committed.divergenceDetectedAt
        convergenceDeadline = committed.convergenceDeadline
        hypervisorId = committed.hypervisorId
        finalizers = committed.finalizers
        // The edge nonces (STR-151) are refreshed for `generation`'s reason,
        // and losing one is worse: a stale snapshot written back over a racing
        // reboot would not merely drop a generation bump, it would drop the
        // *edge*, and no later sync re-derives it.
        rebootGeneration = committed.rebootGeneration
        restoreGeneration = committed.restoreGeneration
        restoreSnapshotID = committed.restoreSnapshotID
    }
}

extension Sandbox: ConvergingResource {
    static var operationResourceKind: OperationResourceKind { .sandbox }
    var projectID: UUID { $project.id }
    func placementAgentIDs(on db: any Database) async throws -> [String] {
        hypervisorId.map { [$0] } ?? []
    }

    static func overdueForConvergence(at now: Date, on db: any Database) async throws -> [Sandbox] {
        try await Sandbox.query(on: db).filter(\.$convergenceDeadline <= now).all()
    }

    func adoptReconciliationState(from committed: Sandbox) {
        status = committed.status
        statusChangedAt = committed.statusChangedAt
        desiredStatus = committed.desiredStatus
        generation = committed.generation
        observedGeneration = committed.observedGeneration
        convergencePhase = committed.convergencePhase
        lastError = committed.lastError
        failedGeneration = committed.failedGeneration
        lastErrorAt = committed.lastErrorAt
        divergenceDetectedAt = committed.divergenceDetectedAt
        convergenceDeadline = committed.convergenceDeadline
        hypervisorId = committed.hypervisorId
        finalizers = committed.finalizers
        restoreGeneration = committed.restoreGeneration
        restoreSnapshotID = committed.restoreSnapshotID
    }
}

extension Volume: ConvergingResource {
    static var operationResourceKind: OperationResourceKind { .volume }
    var projectID: UUID { $project.id }
    func placementAgentIDs(on db: any Database) async throws -> [String] {
        if desiredStatus == .absent {
            return try await VolumeService.agentIDsWithPhysicalReplicas(of: self, on: db)
        }
        return try await VolumeService.agentIDs(holding: self, on: db)
    }

    /// A volume's convergence progress and its most recent failure share one
    /// column pair with its user-facing error, so `ConvergenceObservable`'s
    /// `lastError` is `errorMessage` under another name.
    var lastError: String? {
        get { errorMessage }
        set { errorMessage = newValue }
    }

    static func overdueForConvergence(at now: Date, on db: any Database) async throws -> [Volume] {
        try await Volume.query(on: db).filter(\.$convergenceDeadline <= now).all()
    }

    func adoptReconciliationState(from committed: Volume) {
        status = committed.status
        desiredStatus = committed.desiredStatus
        generation = committed.generation
        observedGeneration = committed.observedGeneration
        convergencePhase = committed.convergencePhase
        errorMessage = committed.errorMessage
        failedGeneration = committed.failedGeneration
        convergenceDeadline = committed.convergenceDeadline
        observedSizeBytes = committed.observedSizeBytes
        finalizers = committed.finalizers
        // The desired size, for the same read-modify-write reason as the
        // attachment below: `accept` saves the whole model, so an attach or a
        // throttle accepted while a resize commits would write its pre-request
        // snapshot back over the new size. Adopting it is also what lets
        // `resizeVolume` compute its quota delta (STR-181) against the row as it
        // is under the lock rather than as the request found it.
        size = committed.size
        // The desired attachment, which is not reconciliation-owned but is
        // read-modify-written by every mutation all the same: `accept` saves
        // the whole model, so a resize accepted while an attach commits would
        // write its pre-request snapshot back over the new attachment. Adopting
        // it is also what makes `canAttach` answer against the row as it is
        // under the lock rather than as the request found it — without which
        // two attaches of one volume to two VMs both pass the guard and the
        // second silently moves the attachment (STR-129).
        $vm.id = committed.$vm.id
        deviceName = committed.deviceName
        bootOrder = committed.bootOrder
        readonly = committed.readonly
        attachedAgentId = committed.attachedAgentId
    }

    /// Resolves the in-flight state a failed mutation left on this volume.
    ///
    /// The *attachment* is reverted, because an unachieved attach left in place
    /// replays destructively on every later sync — the repo's most expensive
    /// bug shape. The *size* deliberately is not: the control plane does not
    /// know the last size the agent actually realized, so "reverting" it would
    /// be a guess, and a desired size larger than reality is harmless to
    /// re-attempt under the agent's own attempt cap. A stuck delete keeps its
    /// `.absent`, for the same reason a VM's does — reverting it would
    /// resurrect a volume the user deleted.
    @discardableResult
    func resolveForStuckOperation(mutation: VMOperationKind, telemetryReason: String) -> Bool {
        guard desiredStatus != .absent else { return false }
        guard mutation == .attach, $vm.id != nil else { return false }
        $vm.id = nil
        deviceName = nil
        bootOrder = nil
        readonly = false
        return true
    }
}

// MARK: - The one term each family supplies

extension VM {
    var desiredSatisfied: Bool { desiredStatus.isSatisfied(by: status) }
}

extension Sandbox {
    var desiredSatisfied: Bool { desiredStatus.isSatisfied(by: status) }
}

extension Volume {
    /// A volume has no `DesiredVolumeStatus.isSatisfied(by:)` because `.absent`
    /// is confirmed by omission from the observed report and `.present` is
    /// confirmed by a resting status. The generation clause the derivation
    /// supplies would, on its own, call a volume converged whose file had been
    /// deleted out of band, since nothing would have bumped the generation to
    /// notice.
    ///
    /// Spelled out rather than delegating to `bytesAtRest` — which asks the same
    /// question today and is the one free to diverge. See the note there.
    var desiredSatisfied: Bool {
        desiredStatus == .present && (status == .available || status == .attached)
    }
}
