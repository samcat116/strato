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
/// Applies the desired-state change, stamps how long convergence may take,
/// appends the attribution record, and reaches the agent. Completion is the
/// resource's own `observedGeneration >= generation` fact, not side-table state.
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
/// `Idempotency-Key` is a separate concern: it collapses two deliveries of one
/// caller intent while leaving two independently keyed intents free to overlap.
struct ResourceMutation {
    /// The agent seam. Injected so tests substitute a fake for the live actor.
    let agentDispatch: any AgentDispatch
    let logger: Logger
    let idempotencyContext: IdempotencyRequestContext?

    init(
        agentDispatch: any AgentDispatch,
        logger: Logger,
        idempotencyContext: IdempotencyRequestContext? = nil
    ) {
        self.agentDispatch = agentDispatch
        self.logger = logger
        self.idempotencyContext = idempotencyContext
    }

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
        /// delete): run the removal work. The resource's finalizers remain the
        /// source of truth when cleanup is still outstanding.
        case directResolution(@Sendable (any Database) async throws -> Void)
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
        /// The canonical response captured in the mutation transaction for an
        /// idempotent delete. Returning these exact bytes prevents background
        /// finalizer work from changing the first response before it is encoded.
        let responseBody: Data?

        init(mutationID: UUID, targetGeneration: Int64, responseBody: Data? = nil) {
            self.mutationID = mutationID
            self.targetGeneration = targetGeneration
            self.responseBody = responseBody
        }

        func cachedResponse() -> Response? {
            guard let responseBody else { return nil }
            var headers = HTTPHeaders()
            headers.contentType = .json
            return Response(status: .accepted, headers: headers, body: .init(data: responseBody))
        }
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
            beforeResourceLock: { _ in },
            idempotencyResponseBody: { _, _, _ in nil },
            applying: mutation)
    }

    /// Variant for responses that must be retained before the resource can be
    /// removed, notably deletes. Requiring the label keeps ordinary trailing
    /// mutation closures source-compatible with the original overload.
    @discardableResult
    func accept<R: ConvergingResource>(
        _ kind: VMOperationKind,
        on resource: R,
        actor: MutationActor,
        dispatch strategy: Dispatch,
        on db: any Database,
        app: Application,
        idempotencyResponseBody:
            @escaping @Sendable (R, Accepted, any Database) async throws -> Data?,
        applying mutation: @escaping @Sendable (any Database) async throws -> Void
    ) async throws -> Accepted {
        try await accept(
            kind, on: resource, actor: actor, dispatch: strategy, on: db, app: app,
            beforeResourceLock: { _ in },
            idempotencyResponseBody: idempotencyResponseBody,
            applying: mutation)
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
        idempotencyResponseBody:
            @escaping @Sendable (R, Accepted, any Database) async throws -> Data?,
        applying mutation: @escaping @Sendable (any Database) async throws -> Void
    ) async throws -> Accepted {
        let resourceID = try resource.requireID()
        let (accepted, placementAgentIDs) = try await db.transaction { db in
            try await IdempotencyService.reserve(idempotencyContext, actor: actor, on: db)
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
            let acceptedIdentity = Accepted(
                mutationID: try event.requireID(), targetGeneration: resource.generation)
            let responseBody: Data?
            if idempotencyContext == nil {
                responseBody = nil
            } else {
                responseBody = try await idempotencyResponseBody(resource, acceptedIdentity, db)
            }
            let accepted = Accepted(
                mutationID: acceptedIdentity.mutationID,
                targetGeneration: acceptedIdentity.targetGeneration,
                responseBody: responseBody)
            try await IdempotencyService.complete(
                idempotencyContext,
                actor: actor,
                resourceKind: R.operationResourceKind,
                resourceID: resourceID,
                accepted: accepted,
                responseBody: responseBody,
                on: db)
            return (
                accepted,
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

        case .placement(let work), .directResolution(let work):
            app.backgroundTasks.spawn {
                // Bail if shutdown's drain already cancelled us — background
                // work dereferences `app.db` immediately.
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
    /// Every effect is drain-safe: it bails before touching a torn-down
    /// `app.db`.
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
        ResourceMutation(agentDispatch: agentService, logger: logger, idempotencyContext: nil)
    }
}

extension Request {
    var resourceMutation: ResourceMutation {
        ResourceMutation(
            agentDispatch: application.agentService,
            logger: logger,
            idempotencyContext: idempotencyContext)
    }
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

    enum FailureRecordingContext: Sendable {
        /// A direct dispatch failure, or any caller whose model still reflects
        /// the durable resource row.
        case resourceState
        /// The observed-state applier has already mirrored the agent's failure
        /// onto its in-memory model. The supplied generation and deadline state
        /// are what the row carried before that report. A live deadline means a
        /// previously reported blocked error is still an unfinished mutation,
        /// so a later terminal report must settle it rather than look duplicate.
        case observedReport(previousFailureGeneration: Int64?, hadActiveDeadline: Bool)
        /// The deadline sweep locked and refreshed this generation while its
        /// deadline remained expired. It must settle even when a blocked report
        /// already exposed the same generation as degraded.
        case expiredDeadline
    }

    /// Finalizes one model returned by the overdue-deadline query, if the same
    /// generation is still overdue after locking and refreshing its row.
    ///
    /// The refresh and verdict share one transaction. A successful agent
    /// report that commits first therefore clears the deadline and is observed
    /// here; a report that arrives later waits behind this lock and sees the
    /// terminal state. Splitting the deadline claim from `recordFailure` would
    /// leave a gap where a success could commit before this stale model was
    /// saved back over it.
    @discardableResult
    static func recordExpiredDeadline<R: ConvergingResource>(
        _ resource: R,
        mutation: VMOperationKind,
        now: Date,
        timeoutReason: String,
        on db: any Database
    ) async throws -> WriteOutcome {
        let expectedGeneration = resource.generation
        return try await db.transaction { tx -> WriteOutcome in
            guard try await resource.lockAndRefresh(on: tx) else { return .missing }
            guard resource.generation == expectedGeneration else {
                return .superseded(actualGeneration: resource.generation)
            }
            guard let deadline = resource.convergenceDeadline, deadline <= now else {
                return .alreadyRecorded
            }

            // Preserve the prior sweep behavior for a row that is already
            // converged when locked: close its stale deadline without emitting
            // a second convergence outcome.
            if resource.isConverged {
                resource.convergenceDeadline = nil
                try await resource.save(on: tx)
                return .alreadyRecorded
            }

            let reason =
                resource.failedGeneration == resource.generation
                ? resource.lastError ?? timeoutReason
                : timeoutReason
            return try await recordFailure(
                resource, mutation: mutation, reason: reason,
                telemetryReason: "stuck_convergence", context: .expiredDeadline, on: tx)
        }
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
    /// `context` distinguishes the three views callers can hold. The observed
    /// applier supplies the failure generation and deadline state from before
    /// it mirrored the report, so that mirror cannot suppress the first
    /// terminal verdict or a terminal verdict that follows a blocked report at
    /// the same generation. A deadline sweep deliberately bypasses the
    /// failure-pair guard after it locks and rechecks the expired deadline: a
    /// blocked report exposes the remedy before the deadline but is not a
    /// terminal verdict, and the sweep must still resolve intent and enqueue
    /// the failure webhook. Direct callers read the model as usual.
    ///
    /// Note that the resolution *bumps the generation*: abandoning an
    /// unachieved intent is itself a desired-state change
    /// (`revertDesiredToObserved`), so `failedGeneration` ends one behind
    /// `generation`. That is the shape `ResourceConditions` documents — a
    /// failure that stands against a newer target — and it is why the
    /// stuck-convergence sweep locks and rechecks the deadline rather than
    /// relying on this guard to stay true across passes.
    @discardableResult
    static func recordFailure<R: ConvergingResource>(
        _ resource: R,
        mutation: VMOperationKind,
        reason: String,
        telemetryReason: String,
        context: FailureRecordingContext = .resourceState,
        on db: any Database
    ) async throws -> WriteOutcome {
        let expectedGeneration = resource.generation
        let recorded: Int64?
        switch context {
        case .resourceState:
            recorded = resource.failedGeneration
        case .observedReport(let previousFailureGeneration, let hadActiveDeadline):
            recorded = hadActiveDeadline ? nil : previousFailureGeneration
        case .expiredDeadline:
            recorded = nil
        }
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

    /// JSON bytes suitable for retaining with an idempotency claim inside the
    /// mutation transaction. Delete replay cannot depend on the resource row
    /// still existing when the caller retries.
    func encodedBody() throws -> Data {
        guard let data = try acceptedResponse().body.data else {
            throw Abort(.internalServerError, reason: "The accepted mutation response had no body")
        }
        return data
    }
}
