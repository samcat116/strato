import ControlPlanePostgres
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
    let database: PostgresStoreContext

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
        case placement(@Sendable (PostgresStoreContext) async throws -> Void)
        /// Resolve locally with no agent teardown (the offline/unplaced
        /// delete): run the removal work. Returning `false` means another
        /// finalizer still owes cleanup, so the deletion is under way rather
        /// than done and nothing is recorded — `sweepOrphanedTerminatingResources`
        /// is the backstop.
        case directResolution(@Sendable (PostgresStoreContext) async throws -> Bool)
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

    /// Value-oriented counterpart used by immutable persistence records. The
    /// committed replacement is returned with the acceptance metadata so no
    /// caller relies on reference mutation or Fluent dirty tracking.
    func acceptValue<R: ConvergingResource>(
        _ kind: VMOperationKind,
        on resource: R,
        actor: MutationActor,
        dispatch strategy: Dispatch,
        on db: PostgresStoreContext,
        app: Application,
        applying mutation: @escaping @Sendable (R, PostgresStoreContext) async throws -> R = { value, _ in value }
    ) async throws -> (resource: R, accepted: Accepted) {
        let resourceID = try resource.requireID()
        let (committed, accepted, placementAgentIDs) = try await db.transaction { db in
            guard var current = try await resource.lockingAndRefreshing(on: db) else {
                throw Abort(
                    .notFound,
                    reason: "This \(R.operationResourceKind.displayName) no longer exists")
            }
            let expectedGeneration = current.generation
            var scope = try await ResourceEvent.scope(
                of: R.operationResourceKind, id: resourceID, on: db)

            current = try await mutation(current, db)
            let advance = try await current.advancingDesiredStateGeneration(
                expectedGeneration: expectedGeneration, on: db)
            current = advance.resource
            switch advance.outcome {
            case .applied:
                break
            case .missing:
                throw Abort(
                    .notFound,
                    reason: "This \(R.operationResourceKind.displayName) no longer exists")
            case .superseded(let actualGeneration):
                throw Abort(
                    .internalServerError,
                    reason: "Desired-state generation advanced unexpectedly from "
                        + "\(expectedGeneration) to \(actualGeneration) while its row was locked")
            }
            current = current.extendingConvergenceDeadline(
                by: R.operationResourceKind.completionBudgetSeconds(for: kind))
            try await current.persist(on: db)

            scope.generation = current.generation
            let event = try await ResourceEvent.record(
                kind, resourceKind: R.operationResourceKind, resourceID: resourceID,
                actor: actor, scope: scope, on: db)
            return (
                current,
                Accepted(mutationID: try event.requireID(), targetGeneration: current.generation),
                try await current.placementAgentIDs(on: db)
            )
        }

        dispatch(
            kind, resourceType: R.self, resourceID: resourceID,
            targetGeneration: accepted.targetGeneration,
            agentIDs: placementAgentIDs, strategy: strategy, app: app)
        return (committed, accepted)
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
                // The registry drains this work before the native pool closes.
                let db = database
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
                let db = database
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
    /// Every effect is drain-safe because the registry completes or cancels it
    /// before the native pool closes.
    private func degrade<R: ConvergingResource>(
        _ type: R.Type,
        id: UUID,
        mutation: VMOperationKind,
        expectedGeneration: Int64,
        reason: String,
        app: Application
    ) async {
        let db = database
        do {
            guard let resource = try await R.load(id, on: db) else { return }
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
            let result = try await ResourceConvergence.recordValueFailure(
                resource, mutation: mutation, reason: reason,
                telemetryReason: "mutation_failed", on: db)
            let outcome = result.outcome
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
    private struct ResourceMutationKey: StorageKey {
        typealias Value = ResourceMutation
    }

    var resourceMutation: ResourceMutation {
        guard let mutation = storage[ResourceMutationKey.self] else {
            preconditionFailure("Resource mutation service has not been configured")
        }
        return mutation
    }

    func configureResourceMutation(_ mutation: ResourceMutation) {
        storage[ResourceMutationKey.self] = mutation
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

    struct ValueWrite<R: ConvergingResource>: Sendable {
        let resource: R
        let outcome: WriteOutcome
    }

    /// Immutable-record failure transition. It mirrors the mutable path below
    /// but threads each replacement through the transaction and returns the
    /// exact value that was persisted.
    static func recordValueFailure<R: ConvergingResource>(
        _ resource: R,
        mutation: VMOperationKind,
        reason: String,
        telemetryReason: String,
        alreadyRecordedAt: Int64?? = nil,
        on db: PostgresStoreContext
    ) async throws -> ValueWrite<R> {
        let expectedGeneration = resource.generation
        let recorded = alreadyRecordedAt ?? resource.failedGeneration
        if recorded == expectedGeneration {
            let outcome = try await db.transaction { tx -> WriteOutcome in
                switch try await DesiredStateGenerationWriter.lockCurrent(
                    schema: R.schema, id: try resource.requireID(),
                    expectedGeneration: expectedGeneration, on: tx)
                {
                case .applied: return .alreadyRecorded
                case .missing: return .missing
                case .superseded(let actualGeneration):
                    return .superseded(actualGeneration: actualGeneration)
                }
            }
            if case .superseded = outcome {
                Telemetry.desiredStateWriteConflict(
                    resourceKind: R.operationResourceKind.rawValue, writer: telemetryReason)
            }
            return ValueWrite(resource: resource, outcome: outcome)
        }

        let withFailure = resource.replacingConvergence(
            phase: nil, lastError: reason, failedGeneration: expectedGeneration)
        let withoutDeadline = withFailure.replacingConvergenceDeadline(nil)
        let resolution = withoutDeadline.resolvingForStuckOperation(
            mutation: mutation, telemetryReason: telemetryReason)
        let prepared = resolution.resource

        let result = try await db.transaction { tx -> ValueWrite<R> in
            var updated = prepared
            switch try await DesiredStateGenerationWriter.lockCurrent(
                schema: R.schema, id: try updated.requireID(),
                expectedGeneration: expectedGeneration, on: tx)
            {
            case .missing:
                return ValueWrite(resource: resource, outcome: .missing)
            case .superseded(let actualGeneration):
                return ValueWrite(
                    resource: resource,
                    outcome: .superseded(actualGeneration: actualGeneration))
            case .applied:
                break
            }

            if resolution.desiredStateChanged {
                let advance = try await updated.advancingDesiredStateGeneration(
                    expectedGeneration: expectedGeneration, on: tx)
                updated = advance.resource
                switch advance.outcome {
                case .applied: break
                case .missing:
                    return ValueWrite(resource: resource, outcome: .missing)
                case .superseded(let actualGeneration):
                    return ValueWrite(
                        resource: resource,
                        outcome: .superseded(actualGeneration: actualGeneration))
                }
            }
            try await updated.persist(on: tx)
            try await WebhookEvents.enqueueMutationOutcome(
                for: updated, succeeded: false, error: reason, on: tx)
            return ValueWrite(resource: updated, outcome: .recorded)
        }
        if case .superseded = result.outcome {
            Telemetry.desiredStateWriteConflict(
                resourceKind: R.operationResourceKind.rawValue, writer: telemetryReason)
        }
        return result
    }

    static func recordValueSuccess<R: ConvergingResource>(
        _ resource: R, on db: PostgresStoreContext
    ) async throws -> ValueWrite<R> {
        let expectedGeneration = resource.generation
        let wasOutstanding = resource.convergenceDeadline != nil
        let updated = resource.replacingConvergenceDeadline(nil)
        let result = try await db.transaction { tx -> ValueWrite<R> in
            switch try await DesiredStateGenerationWriter.lockCurrent(
                schema: R.schema, id: try updated.requireID(),
                expectedGeneration: expectedGeneration, on: tx)
            {
            case .missing:
                return ValueWrite(resource: resource, outcome: .missing)
            case .superseded(let actualGeneration):
                return ValueWrite(
                    resource: resource,
                    outcome: .superseded(actualGeneration: actualGeneration))
            case .applied:
                break
            }
            try await updated.persist(on: tx)
            guard wasOutstanding else {
                return ValueWrite(resource: updated, outcome: .alreadyRecorded)
            }
            try await WebhookEvents.enqueueMutationOutcome(
                for: updated, succeeded: true, error: nil, on: tx)
            return ValueWrite(resource: updated, outcome: .recorded)
        }
        if case .superseded = result.outcome {
            Telemetry.desiredStateWriteConflict(
                resourceKind: R.operationResourceKind.rawValue, writer: "observed_success")
        }
        return result
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
