import ControlPlanePostgres
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
protocol ConvergenceObservable: Sendable {
    var convergencePhase: String? { get }
    var lastError: String? { get }
    var failedGeneration: Int64? { get }

    func replacingConvergence(
        phase: String?, lastError: String?, failedGeneration: Int64?
    ) -> Self
}

extension ConvergenceObservable {
    func recordingConvergence(
        phase: String?, lastError: String?, failedGeneration: Int64?
    ) -> (resource: Self, changed: Bool) {
        guard
            convergencePhase != phase
                || self.lastError != lastError
                || self.failedGeneration != failedGeneration
        else { return (self, false) }
        return (
            replacingConvergence(
                phase: phase, lastError: lastError, failedGeneration: failedGeneration),
            true
        )
    }
}

/// VM and Sandbox convergence state includes the failure timestamp and the
/// internal sustained-divergence claim. Other resource families retain the
/// common convergence fields without taking these workload-only columns.
protocol TimestampedConvergenceObservable: ConvergenceObservable {
    var lastErrorAt: Date? { get }
    var divergenceDetectedAt: Date? { get }

    func replacingTimestampedConvergence(
        phase: String?, lastError: String?, failedGeneration: Int64?, lastErrorAt: Date?
    ) -> Self
}

extension TimestampedConvergenceObservable {
    func recordingTimestampedConvergence(
        phase: String?,
        lastError: String?,
        failedGeneration: Int64?,
        at now: Date = Date()
    ) -> (resource: Self, changed: Bool) {
        let errorPairChanged = self.lastError != lastError || self.failedGeneration != failedGeneration
        let nextErrorAt: Date?
        if lastError == nil || failedGeneration == nil {
            nextErrorAt = nil
        } else if errorPairChanged || lastErrorAt == nil {
            nextErrorAt = now
        } else {
            nextErrorAt = lastErrorAt
        }
        let changed = convergencePhase != phase
            || self.lastError != lastError
            || self.failedGeneration != failedGeneration
            || lastErrorAt != nextErrorAt
        guard changed else { return (self, false) }
        return (
            replacingTimestampedConvergence(
                phase: phase,
                lastError: lastError,
                failedGeneration: failedGeneration,
                lastErrorAt: nextErrorAt),
            true
        )
    }
}

extension VM: TimestampedConvergenceObservable {
    func replacingConvergence(
        phase: String?, lastError: String?, failedGeneration: Int64?
    ) -> Self {
        var copy = self
        copy.convergencePhase = phase
        copy.lastError = lastError
        copy.failedGeneration = failedGeneration
        return copy
    }

    func replacingTimestampedConvergence(
        phase: String?, lastError: String?, failedGeneration: Int64?, lastErrorAt: Date?
    ) -> Self {
        var copy = replacingConvergence(
            phase: phase, lastError: lastError, failedGeneration: failedGeneration)
        copy.lastErrorAt = lastErrorAt
        return copy
    }
}
extension Sandbox: TimestampedConvergenceObservable {
    func replacingConvergence(
        phase: String?, lastError: String?, failedGeneration: Int64?
    ) -> Self {
        var copy = self
        copy.convergencePhase = phase
        copy.lastError = lastError
        copy.failedGeneration = failedGeneration
        return copy
    }

    func replacingTimestampedConvergence(
        phase: String?, lastError: String?, failedGeneration: Int64?, lastErrorAt: Date?
    ) -> Self {
        var copy = replacingConvergence(
            phase: phase, lastError: lastError, failedGeneration: failedGeneration)
        copy.lastErrorAt = lastErrorAt
        return copy
    }
}
extension Volume: ConvergenceObservable {
    var lastError: String? { errorMessage }

    func replacingConvergence(
        phase: String?, lastError: String?, failedGeneration: Int64?
    ) -> Self {
        replacing(
            convergencePhase: .some(phase), errorMessage: .some(lastError),
            failedGeneration: .some(failedGeneration))
    }
}

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
    func placementAgentIDs(on db: PostgresStoreContext) async throws -> [String]
}

protocol PersistentResourceRecord: Sendable {
    static var schema: String { get }
    var id: UUID? { get }

    func requireID() throws -> UUID
    func persist(on db: PostgresStoreContext) async throws
    func remove(on db: PostgresStoreContext) async throws
    static func load(_ id: UUID?, on db: PostgresStoreContext) async throws -> Self?
}

protocol ConvergingResource:
    PersistentResourceRecord, ConvergenceDerived, AgentPlacedResource
{
    static var operationResourceKind: OperationResourceKind { get }

    var generation: Int64 { get }

    var name: String { get }
    var projectID: UUID { get }

    var convergenceDeadline: Date? { get }

    func replacingGeneration(_ generation: Int64) -> Self
    func replacingConvergenceDeadline(_ deadline: Date?) -> Self

    /// Resolves the in-flight state a failed mutation left behind. Returns
    /// whether desired state changed and therefore needs a new generation;
    /// observed-status realignment does not count. Does not persist.
    @discardableResult
    func resolvingForStuckOperation(
        mutation: VMOperationKind, telemetryReason: String
    ) -> (resource: Self, desiredStateChanged: Bool)

    /// Rows whose convergence deadline has passed — the stuck-convergence
    /// sweep's whole query. A protocol requirement rather than a generic
    /// extension because Fluent filters on the model's own field *projection*
    /// (`\.$convergenceDeadline`), which a protocol cannot name. Rows with no
    /// deadline are excluded by SQL's `NULL` comparison, which is the wanted
    /// behaviour: nothing is outstanding on them.
    static func overdueForConvergence(at now: Date, on db: PostgresStoreContext) async throws -> [Self]

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
    func adoptingReconciliationState(from committed: Self) -> Self
}

enum ConvergenceTimeoutClaimOutcome: Equatable, Sendable {
    case claimed
    case alreadyClaimed
    case superseded(actualGeneration: Int64)
    case missing
}

extension ConvergingResource {
    func advancingDesiredStateGeneration(
        expectedGeneration: Int64? = nil, on db: PostgresStoreContext
    ) async throws -> (resource: Self, outcome: DesiredStateGenerationWriter.Outcome) {
        let outcome = try await DesiredStateGenerationWriter.advance(
            schema: Self.schema,
            id: try requireID(),
            expectedGeneration: expectedGeneration,
            on: db)
        guard case .applied(let generation) = outcome else { return (self, outcome) }
        return (replacingGeneration(generation), outcome)
    }

    func lockingAndRefreshing(on db: PostgresStoreContext) async throws -> Self? {
        guard let sql = db as? PostgresStoreContext else {
            throw ConvergenceWriteError.unsupportedDatabase
        }
        let id = try requireID()
        let locked = try await sql.raw(
            "SELECT id FROM \(ident: Self.schema) WHERE id = \(bind: id) FOR UPDATE"
        ).all(decoding: ClaimedConvergenceRow.self)
        guard !locked.isEmpty, let committed = try await Self.load(id, on: db) else {
            return nil
        }
        return adoptingReconciliationState(from: committed)
    }

    func claimingConvergenceTimeout(on db: PostgresStoreContext) async throws
        -> ConvergenceTimeoutClaimOutcome
    {
        guard let sql = db as? PostgresStoreContext else {
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
        if !claimed.isEmpty { return .claimed }

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

    func extendingConvergenceDeadline(
        by budget: TimeInterval, from now: Date = Date()
    ) -> Self {
        let candidate = now.addingTimeInterval(budget)
        if let existing = convergenceDeadline, existing > candidate { return self }
        return replacingConvergenceDeadline(candidate)
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

extension VM: ConvergingResource {
    static var operationResourceKind: OperationResourceKind { .virtualMachine }
    func placementAgentIDs(on db: PostgresStoreContext) async throws -> [String] {
        hypervisorId.map { [$0] } ?? []
    }

    static func overdueForConvergence(at now: Date, on db: PostgresStoreContext) async throws -> [VM] {
        try await LegacyVMStore.vms(overdueAt: now, on: db)
    }

    func adoptingReconciliationState(from committed: VM) -> Self { committed }

    func replacingGeneration(_ generation: Int64) -> Self {
        var copy = self
        copy.generation = generation
        return copy
    }

    func replacingConvergenceDeadline(_ deadline: Date?) -> Self {
        var copy = self
        copy.convergenceDeadline = deadline
        return copy
    }

    func resolvingForStuckOperation(
        mutation: VMOperationKind, telemetryReason: String
    ) -> (resource: Self, desiredStateChanged: Bool) {
        var copy = self
        let changed = copy.resolveForStuckOperation(
            mutation: mutation, telemetryReason: telemetryReason)
        return (copy, changed)
    }
}

extension Sandbox: ConvergingResource {
    static var operationResourceKind: OperationResourceKind { .sandbox }
    func placementAgentIDs(on db: PostgresStoreContext) async throws -> [String] {
        hypervisorId.map { [$0] } ?? []
    }

    static func overdueForConvergence(at now: Date, on db: PostgresStoreContext) async throws -> [Sandbox] {
        try await LegacySandboxStore.sandboxes(overdueAt: now, on: db)
    }

    func adoptingReconciliationState(from committed: Sandbox) -> Self { committed }

    func replacingGeneration(_ generation: Int64) -> Self {
        var copy = self
        copy.generation = generation
        return copy
    }

    func replacingConvergenceDeadline(_ deadline: Date?) -> Self {
        var copy = self
        copy.convergenceDeadline = deadline
        return copy
    }

    func resolvingForStuckOperation(
        mutation: VMOperationKind, telemetryReason: String
    ) -> (resource: Self, desiredStateChanged: Bool) {
        var copy = self
        let changed = copy.resolveForStuckOperation(
            mutation: mutation, telemetryReason: telemetryReason)
        return (copy, changed)
    }
}

extension Volume: ConvergingResource {
    static var operationResourceKind: OperationResourceKind { .volume }
    func placementAgentIDs(on db: PostgresStoreContext) async throws -> [String] {
        if desiredStatus == .absent {
            return try await VolumeService.agentIDsWithPhysicalReplicas(of: self, on: db)
        }
        return try await VolumeService.agentIDs(holding: self, on: db)
    }

    static func overdueForConvergence(at now: Date, on db: PostgresStoreContext) async throws -> [Volume] {
        try await LegacyVolumeStore.volumes(overdueAt: now, on: db)
    }

    func adoptingReconciliationState(from committed: Volume) -> Self { committed }

    func replacingGeneration(_ generation: Int64) -> Self { replacing(generation: generation) }

    func replacingConvergenceDeadline(_ deadline: Date?) -> Self {
        replacing(convergenceDeadline: .some(deadline))
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
    func resolvingForStuckOperation(
        mutation: VMOperationKind, telemetryReason: String
    ) -> (resource: Self, desiredStateChanged: Bool) {
        guard desiredStatus != .absent, mutation == .attach, vmID != nil else {
            return (self, false)
        }
        return (
            replacing(
                attachedAgentId: .some(nil), vmID: .some(nil),
                deviceName: .some(nil), bootOrder: .some(nil), readonly: false),
            true
        )
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
