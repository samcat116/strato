import Fluent
import StratoShared
import Vapor

/// The agent-facing seam a mutation depends on, so the accept path can be
/// exercised through its own interface with an in-memory fake instead of a live
/// agent connection. Production adapter: `AgentService` (conformance below);
/// test adapter: a fake that records sync signals.
protocol AgentDispatch: Sendable {
    /// Whether the resource's owning agent is online somewhere in the cluster.
    /// False for an unplaced resource (nil id) or an offline/unknown agent.
    func agentIsOnline(agentId: String) async -> Bool

    /// Signal that the agent's desired state changed by ringing the broadcast
    /// doorbell. Losing the signal is safe: the agent re-fetches
    /// unconditionally on its own interval regardless.
    func syncDesiredState(agentId: String) async
}

extension AgentService: AgentDispatch {
    func agentIsOnline(agentId: String) async -> Bool {
        guard let agent = await getAgentInfo(agentId) else { return false }
        return agent.status == .online
    }
}

/// Accepts one asynchronous lifecycle mutation on a VM or sandbox and hands it
/// to the reconciliation loop (ADR 0001 stage 4, STR-147).
///
/// This is what `ResourceOperationCoordinator` was, minus the side-table. The
/// coordinator's job was to insert a `pending` row, dispatch, and later record
/// a verdict on it; every one of those steps was bookkeeping *about* a fact the
/// resource already carries — `observedGeneration >= generation`. So the row is
/// gone (and, with STR-152, so is the coordinator) and what remains is the part
/// that was never redundant: apply the desired-state change, stamp how long
/// convergence may take, append the attribution record, and reach the agent.
///
/// The client gets `202 { resource, targetGeneration, mutationId }` and polls
/// the resource's `conditions`, not an operation.
///
/// **The dropped mutex.** `ResourceOperation.begin` rejected a mutation while
/// another was pending, with `409`. Nothing here does, and that is deliberate:
/// desired state is level-triggered, so two overlapping writes leave the last
/// one standing and the agent converges on it — which is what a user pressing
/// "stop" during a slow start actually wants. The one place overlap was more
/// than a race in name is the resize path's quota delta, and that is guarded
/// where it belongs, by recomputing the delta inside the mutation transaction.
struct ResourceMutation {
    /// The agent seam. Injected so tests substitute a fake for the live actor.
    let agentDispatch: any AgentDispatch
    let logger: Logger

    /// How an accepted mutation reaches the agent after the transaction
    /// commits. The uniform scaffolding — background hand-off, drain guards,
    /// degrading the resource when the work fails — belongs here; only the
    /// reach-the-agent step differs.
    enum Dispatch {
        /// Desired state is written; nudge the owning agent. An unplaced or
        /// offline resource is degraded now rather than left to sit until its
        /// deadline, exactly as the operation path failed it now.
        case stateSync
        /// Background work that reaches an agent (create: schedule, place,
        /// first sync). Degrades the resource on throw; success is left to the
        /// agent's observed report.
        case placement(@Sendable (any Database) async throws -> Void)
        /// Resolve locally with no agent teardown (the offline/unplaced
        /// delete): run the removal work. Returning `false` means another
        /// finalizer still owes cleanup, so the deletion is under way rather
        /// than done and nothing is recorded — `sweepOrphanedTerminatingResources`
        /// is the backstop.
        case directResolution(@Sendable (any Database) async throws -> Bool)
    }

    /// What the `202` needs: the generation the client waits for, and the id of
    /// the `resource_events` row that recorded the request.
    ///
    /// The id is the delete path's completion signal. Every other mutation is
    /// answerable from the resource itself, but a delete succeeds by the
    /// resource ceasing to exist, and a polling client's `404` means deleted,
    /// never-existed and not-authorized alike. `GET /api/operations/{id}`
    /// answers for this id after the row is gone.
    struct Accepted: Sendable {
        let mutationID: UUID
        let targetGeneration: Int64
    }

    /// Wraps a dispatch-work failure with a locating prefix so it reads well as
    /// the resource's `conditions.degraded.reason`.
    struct WorkError: Error, LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// Applies `mutation` to `resource`, records it, and dispatches.
    ///
    /// One transaction covers the desired-state change, the convergence
    /// deadline, and the attribution event, so a mutation can never apply
    /// unrecorded (nor be recorded without applying). `mutation` need not save
    /// the resource — this saves it once afterwards, which is also what
    /// persists the deadline.
    ///
    /// The transaction opens by locking the row and refreshing the columns the
    /// reconciliation loop owns (`lockAndRefresh`). That is what replaces the
    /// dropped `409` — not by refusing the second mutation, but by serializing
    /// it: the caller's instance was loaded before the request and its `save`
    /// writes the whole row, so without the refresh a racing mutation's
    /// generation bump would be lost and a concurrent observed-state report's
    /// `observedGeneration` would be written *backwards*.
    ///
    @discardableResult
    func accept<R: ConvergingResource>(
        _ kind: VMOperationKind,
        on resource: R,
        actor: MutationActor,
        dispatch strategy: Dispatch,
        on db: any Database,
        app: Application,
        applying mutation: @escaping @Sendable (any Database) async throws -> Void = { _ in }
    ) async throws -> Accepted {
        try await accept(
            kind, on: resource, actor: actor, dispatch: strategy, on: db, app: app,
            beforeResourceLock: { _ in }, applying: mutation)
    }

    /// The narrow escape hatch for a cross-row invariant whose advisory lock
    /// must precede the resource row lock. `beforeResourceLock` runs as the
    /// first statement in the same transaction. Both closures are required and
    /// labeled so an ordinary trailing mutation closure cannot bind here.
    @discardableResult
    func accept<R: ConvergingResource>(
        _ kind: VMOperationKind,
        on resource: R,
        actor: MutationActor,
        dispatch strategy: Dispatch,
        on db: any Database,
        app: Application,
        beforeResourceLock: @escaping @Sendable (any Database) async throws -> Void,
        applying mutation: @escaping @Sendable (any Database) async throws -> Void
    ) async throws -> Accepted {
        let resourceID = try resource.requireID()
        let (accepted, placementAgentIDs) = try await db.transaction { db in
            try await beforeResourceLock(db)
            guard try await resource.lockAndRefresh(on: db) else {
                throw Abort(
                    .notFound,
                    reason: "This \(R.operationResourceKind.displayName) no longer exists")
            }
            let expectedGeneration = resource.generation

            // Resolve the delivery/attribution scope before the mutation: the
            // organization lookup walks the hierarchy, and only the generation
            // moves under a mutation.
            var scope = try await ResourceEvent.scope(
                of: R.operationResourceKind, id: resourceID, on: db)

            try await mutation(db)
            switch try await resource.advanceDesiredStateGeneration(
                expectedGeneration: expectedGeneration, on: db)
            {
            case .applied:
                break
            case .missing:
                throw Abort(
                    .notFound,
                    reason: "This \(R.operationResourceKind.displayName) no longer exists")
            case .superseded(let actualGeneration):
                // `lockAndRefresh` holds this row through the transaction, so
                // this is an invariant violation rather than an ordinary race.
                throw Abort(
                    .internalServerError,
                    reason: "Desired-state generation advanced unexpectedly from "
                        + "\(expectedGeneration) to \(actualGeneration) while its row was locked")
            }
            resource.extendConvergenceDeadline(
                by: R.operationResourceKind.completionBudgetSeconds(for: kind))
            try await resource.save(on: db)

            scope.generation = resource.generation
            let event = try await ResourceEvent.record(
                kind,
                resourceKind: R.operationResourceKind,
                resourceID: resourceID,
                actor: actor,
                scope: scope,
                on: db)
            return (
                Accepted(mutationID: try event.requireID(), targetGeneration: resource.generation),
                try await resource.placementAgentIDs(on: db)
            )
        }

        dispatch(
            kind, resourceType: R.self, resourceID: resourceID,
            targetGeneration: accepted.targetGeneration,
            agentIDs: placementAgentIDs, strategy: strategy, app: app)
        return accepted
    }

    /// Dispatches a mutation applied *outside* `accept` — the create paths,
    /// whose retrying IPAM transaction owns the whole insert. Same background
    /// hand-off and failure path, without the transaction.
    func dispatch<R: ConvergingResource>(
        _ kind: VMOperationKind,
        resourceType: R.Type,
        resourceID: UUID,
        targetGeneration: Int64,
        agentIDs: [String],
        strategy: Dispatch,
        app: Application
    ) {
        switch strategy {
        case .stateSync:
            app.backgroundTasks.spawn {
                guard !agentIDs.isEmpty else {
                    await degrade(
                        R.self, id: resourceID, mutation: kind,
                        expectedGeneration: targetGeneration,
                        reason: "This \(R.operationResourceKind.displayName) is not placed on any agent",
                        app: app)
                    return
                }
                for agentId in agentIDs {
                    guard await agentDispatch.agentIsOnline(agentId: agentId) else {
                        await degrade(
                            R.self, id: resourceID, mutation: kind,
                            expectedGeneration: targetGeneration,
                            reason: "Agent \(agentId) is offline; the "
                                + "\(R.operationResourceKind.displayName) cannot converge to the requested state",
                            app: app)
                        continue
                    }
                    await agentDispatch.syncDesiredState(agentId: agentId)
                }
            }

        case .placement(let work):
            app.backgroundTasks.spawn {
                // Bail if shutdown's drain already cancelled us — placement work
                // dereferences `app.db` immediately (see `Application.liveDB`).
                guard let db = app.liveDB else { return }
                do {
                    try await work(db)
                } catch {
                    await degrade(
                        R.self, id: resourceID, mutation: kind,
                        expectedGeneration: targetGeneration,
                        reason: error.localizedDescription, app: app)
                }
            }

        case .directResolution(let work):
            app.backgroundTasks.spawn {
                guard let db = app.liveDB else { return }
                do {
                    _ = try await work(db)
                } catch {
                    await degrade(
                        R.self, id: resourceID, mutation: kind,
                        expectedGeneration: targetGeneration,
                        reason: error.localizedDescription, app: app)
                }
            }
        }
    }

    /// Records a convergence failure on the resource: the `degraded` half of
    /// its `conditions`, plus the resolution of whatever in-flight state the
    /// failed mutation left behind.
    ///
    /// Every effect is drain-safe — it bails before touching a torn-down
    /// `app.db`, the crash gap `ResourceOperationCoordinator.recordVerdict`
    /// documents.
    private func degrade<R: ConvergingResource>(
        _ type: R.Type,
        id: UUID,
        mutation: VMOperationKind,
        expectedGeneration: Int64,
        reason: String,
        app: Application
    ) async {
        guard let db = app.liveDB else { return }
        do {
            guard let resource = try await R.find(id, on: db) else { return }
            guard resource.generation == expectedGeneration else {
                Telemetry.desiredStateWriteConflict(
                    resourceKind: R.operationResourceKind.rawValue, writer: "mutation_failed")
                logger.warning(
                    "Dropped a mutation failure after newer desired state superseded it",
                    metadata: [
                        "resourceKind": .string(R.operationResourceKind.rawValue),
                        "resourceId": .string(id.uuidString),
                        "expectedGeneration": .stringConvertible(expectedGeneration),
                        "actualGeneration": .stringConvertible(resource.generation),
                    ])
                return
            }
            let outcome = try await ResourceConvergence.recordFailure(
                resource, mutation: mutation, reason: reason,
                telemetryReason: "mutation_failed", on: db)
            if case .superseded(let actualGeneration) = outcome {
                logger.warning(
                    "Dropped a mutation failure after newer desired state superseded it",
                    metadata: [
                        "resourceKind": .string(R.operationResourceKind.rawValue),
                        "resourceId": .string(id.uuidString),
                        "actualGeneration": .stringConvertible(actualGeneration),
                    ])
                return
            }
            guard outcome == .recorded else { return }
            logger.warning(
                "Resource mutation failed",
                metadata: [
                    "resourceKind": .string(R.operationResourceKind.rawValue),
                    "resourceId": .string(id.uuidString),
                    "mutation": .string(mutation.rawValue),
                    "error": .string(reason),
                ])
        } catch {
            logger.error(
                "Failed to record a convergence failure: \(error)",
                metadata: ["resourceId": .string(id.uuidString)])
        }
    }
}

extension Application {
    /// Cheap to construct (it holds references), so it is materialized per
    /// access rather than stored — the same idiom as
    /// `resourceOperationCoordinator`.
    var resourceMutation: ResourceMutation {
        ResourceMutation(agentDispatch: agentService, logger: logger)
    }
}

extension Request {
    var resourceMutation: ResourceMutation { application.resourceMutation }
}

// MARK: - Convergence outcomes

/// The two writes that take a resource out of "converging": it got there, or
/// it will not.
///
/// Both are the transitions the operations façade, the completion webhooks, and
/// the frontend's refetch loop all read, so they live in one place rather than
/// once per caller — `ObservedStateApplier` (the agent's report), the
/// stuck-convergence sweep (the deadline), and `ResourceMutation` (dispatch
/// that never reached an agent).
enum ResourceConvergence {
    enum WriteOutcome: Equatable, Sendable {
        case recorded
        case alreadyRecorded
        case superseded(actualGeneration: Int64)
        case missing
    }

    /// Marks a resource degraded for `reason` and resolves the in-flight state
    /// the failed mutation left, saving the row and enqueuing the
    /// `operation.failed` webhook **in one transaction**.
    ///
    /// The transaction is load-bearing, not hygiene. The save is what flips the
    /// `failedGeneration == generation` guard below, and the enqueue is what
    /// tells the user. Committing the first without the second would leave the
    /// guard permanently satisfied — no later report and no sweep pass would
    /// re-enter — so `resolveForStuckOperation` would never run, the
    /// unachieved intent would never be abandoned, and it would replay on every
    /// sync while the user was told nothing. Rolling both back instead costs a
    /// retry.
    ///
    /// The transaction composes with a caller transaction. Observed-state
    /// application already holds the resource row lock while re-evaluating a
    /// bulk-loaded report; dispatch failures and sweeps open the outermost one.
    /// In either case callers pass pending row changes on `resource` and let
    /// this persist them.
    ///
    /// Idempotent by the `failedGeneration == generation` guard: a caller
    /// repeating an already-recorded failure — the agent restating the same
    /// error on every heartbeat — does nothing. Returns whether this call
    /// recorded it.
    ///
    /// `alreadyRecordedAt` is the failure generation the resource carried
    /// *before* the caller touched it, for the one caller that has already
    /// mirrored the agent's own `failedGeneration` onto the in-memory model by
    /// this point (`ObservedStateApplier`). Without it, that mirror would trip
    /// the guard on the very first report of a failure and nothing would ever
    /// be recorded. Everyone else leaves it nil and the guard reads the model.
    ///
    /// Note that the resolution *bumps the generation*: abandoning an
    /// unachieved intent is itself a desired-state change
    /// (`revertDesiredToObserved`), so `failedGeneration` ends one behind
    /// `generation`. That is the shape `ResourceConditions` documents — a
    /// failure that stands against a newer target — and it is why the
    /// stuck-convergence sweep claims the deadline rather than relying on this
    /// guard to stay true across passes.
    @discardableResult
    static func recordFailure<R: ConvergingResource>(
        _ resource: R,
        mutation: VMOperationKind,
        reason: String,
        telemetryReason: String,
        alreadyRecordedAt: Int64?? = nil,
        on db: any Database
    ) async throws -> WriteOutcome {
        let expectedGeneration = resource.generation
        let recorded = alreadyRecordedAt ?? resource.failedGeneration
        if recorded == expectedGeneration {
            let outcome = try await db.transaction { tx -> WriteOutcome in
                switch try await DesiredStateGenerationWriter.lockCurrent(
                    schema: R.schema,
                    id: try resource.requireID(),
                    expectedGeneration: expectedGeneration,
                    on: tx)
                {
                case .applied:
                    return .alreadyRecorded
                case .missing:
                    return .missing
                case .superseded(let actualGeneration):
                    return .superseded(actualGeneration: actualGeneration)
                }
            }
            if case .superseded = outcome {
                Telemetry.desiredStateWriteConflict(
                    resourceKind: R.operationResourceKind.rawValue, writer: telemetryReason)
            }
            return outcome
        }

        let failurePairChanged =
            resource.lastError != reason || resource.failedGeneration != resource.generation
        resource.convergencePhase = nil
        resource.lastError = reason
        resource.failedGeneration = expectedGeneration
        if let timestamped = resource as? any TimestampedConvergenceObservable {
            // The observed-state path timestamps before it enters this shared
            // mutation verdict. Preserve that first-observed instant; direct
            // dispatch and sweep failures still need a timestamp of their own.
            if failurePairChanged || timestamped.lastErrorAt == nil {
                timestamped.lastErrorAt = Date()
            }
        }
        resource.convergenceDeadline = nil
        let desiredStateChanged = resource.resolveForStuckOperation(
            mutation: mutation, telemetryReason: telemetryReason)

        let outcome = try await db.transaction { tx -> WriteOutcome in
            switch try await DesiredStateGenerationWriter.lockCurrent(
                schema: R.schema,
                id: try resource.requireID(),
                expectedGeneration: expectedGeneration,
                on: tx)
            {
            case .missing:
                return .missing
            case .superseded(let actualGeneration):
                return .superseded(actualGeneration: actualGeneration)
            case .applied:
                break
            }

            if desiredStateChanged {
                switch try await resource.advanceDesiredStateGeneration(
                    expectedGeneration: expectedGeneration, on: tx)
                {
                case .applied:
                    break
                case .missing:
                    return .missing
                case .superseded(let actualGeneration):
                    return .superseded(actualGeneration: actualGeneration)
                }
            }
            try await resource.save(on: tx)
            try await WebhookEvents.enqueueMutationOutcome(
                for: resource, succeeded: false, error: reason, on: tx)
            return .recorded
        }
        if case .superseded = outcome {
            Telemetry.desiredStateWriteConflict(
                resourceKind: R.operationResourceKind.rawValue, writer: telemetryReason)
        }
        return outcome
    }

    /// Persists a converged resource and enqueues `operation.completed`, in one
    /// transaction for the reason `recordFailure` opens one: clearing the
    /// deadline is what closes the transition, and committing that without the
    /// outbox row loses the completion permanently — the next report sees a
    /// resource that was already converged and never re-enters.
    ///
    /// A live deadline is what says a mutation was actually outstanding, and it
    /// gates the *webhook*, not the save. Without that gate, a resource that
    /// drifts into its desired state on its own — a guest powering itself off
    /// while desired is `shutdown` — would fire a completion naming whichever
    /// mutation happened to be the most recent, which is not what converged.
    static func recordSuccess<R: ConvergingResource>(
        _ resource: R, on db: any Database
    ) async throws -> WriteOutcome {
        let expectedGeneration = resource.generation
        let wasOutstanding = resource.convergenceDeadline != nil
        resource.convergenceDeadline = nil
        let outcome = try await db.transaction { tx -> WriteOutcome in
            switch try await DesiredStateGenerationWriter.lockCurrent(
                schema: R.schema,
                id: try resource.requireID(),
                expectedGeneration: expectedGeneration,
                on: tx)
            {
            case .missing:
                return .missing
            case .superseded(let actualGeneration):
                return .superseded(actualGeneration: actualGeneration)
            case .applied:
                break
            }
            try await resource.save(on: tx)
            guard wasOutstanding else { return .alreadyRecorded }
            try await WebhookEvents.enqueueMutationOutcome(
                for: resource, succeeded: true, error: nil, on: tx)
            return .recorded
        }
        if case .superseded = outcome {
            Telemetry.desiredStateWriteConflict(
                resourceKind: R.operationResourceKind.rawValue, writer: "observed_success")
        }
        return outcome
    }
}

// MARK: - Response

/// The body of a `202` from a lifecycle mutation (ADR 0001 stage 4).
///
/// `resource` is the resource as the mutation left it, so a client has
/// something to render without a second round trip; `targetGeneration` is what
/// its `conditions.observedGeneration` has to reach; `mutationId` names the
/// `resource_events` row, which is what `GET /api/operations/{id}` answers for
/// once a deleted resource is gone.
struct AcceptedMutation<Resource: Content>: Content {
    let resource: Resource
    let targetGeneration: Int64
    let mutationId: UUID

    init(_ resource: Resource, _ accepted: ResourceMutation.Accepted) {
        self.resource = resource
        self.targetGeneration = accepted.targetGeneration
        self.mutationId = accepted.mutationID
    }

    /// `202 Accepted` carrying this body. Every converted VM and sandbox
    /// lifecycle endpoint answers with it.
    func acceptedResponse() throws -> Response {
        let response = Response(status: .accepted)
        try response.content.encode(self)
        return response
    }
}
