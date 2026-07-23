import Fluent
import Vapor
import StratoShared

/// The agent-facing seam the `ResourceOperationCoordinator` depends on, so the
/// operation lifecycle can be exercised through the coordinator's interface
/// with an in-memory fake instead of a live agent socket. Production adapter:
/// `AgentService` (conformance below); test adapter: a fake that records syncs
/// and returns canned responses.
protocol AgentDispatch: Sendable {
    /// Whether the resource's owning agent is online somewhere in the cluster.
    /// False for an unplaced resource (nil id) or an offline/unknown agent.
    func agentIsOnline(agentId: String) async -> Bool

    /// Push the freshly written desired state to the agent — directly when this
    /// replica holds its socket, via a pub/sub nudge to the holding replica
    /// otherwise. Losing the nudge is safe: the periodic sync timer re-sends.
    func syncDesiredState(agentId: String) async

    /// Dispatch a correlated imperative command (an action, not a state, so it
    /// cannot ride the level-triggered sync — e.g. VM reboot) and await the
    /// agent's success/error response. `timeout` should be the operation kind's
    /// full completion budget.
    func performOperationAwaitingResponse(
        _ message: MessageType, resourceID: String, timeout: Duration
    ) async throws -> AgentServiceResponse
}

extension AgentService: AgentDispatch {
    func agentIsOnline(agentId: String) async -> Bool {
        guard let agent = await getAgentInfo(agentId) else { return false }
        return agent.status == .online
    }

    func performOperationAwaitingResponse(
        _ message: MessageType, resourceID: String, timeout: Duration
    ) async throws -> AgentServiceResponse {
        // Reboot is the only awaiting-response operation and is VM-only, so the
        // resource id is a VM id; the VM path routes through the socket-holding
        // replica for us.
        try await performVMOperationAwaitingResponse(message, vmId: resourceID, timeout: timeout)
    }
}

/// The deep module that owns one asynchronous resource operation end to end —
/// `begin` → dispatch → `recordVerdict` — for both VMs and sandboxes (issue
/// #259/#412). Controllers name a transition and a dispatch strategy; the
/// coordinator owns the ordering, the background hand-off after the `202`, and
/// the single verdict-recording choke point the stuck-operation sweep shares.
///
/// Divergence between resource kinds rides the `OperationResourceKind`
/// discriminator (its budgets, its `resolveForStuckOperation`), not a generic
/// protocol — the same idiom the sweep already uses.
struct ResourceOperationCoordinator {
    /// The agent seam. Injected so tests substitute a fake for the live actor.
    let agentDispatch: any AgentDispatch
    let logger: Logger

    /// How an operation reaches its agent after `begin`. The uniform scaffolding
    /// (background hand-off, drain guards, verdict recording) is the
    /// coordinator's; only the reach-the-agent step differs per strategy.
    enum Strategy {
        /// Desired state is already written in `begin`; nudge the owning agent,
        /// or fail the operation now if it is unplaced/offline instead of
        /// letting it sit pending for the sweep budget. The success verdict
        /// arrives later, from the observed-state applier.
        case stateSync
        /// Await a correlated imperative agent command and record the verdict
        /// immediately from the response (VM reboot).
        case awaitingResponse(MessageType)
        /// Run background work that reaches an agent (create: schedule, place,
        /// first sync). Records a failure verdict on throw; success is deferred
        /// to the observed-state applier.
        case placement(@Sendable (any Database) async throws -> Void)
        /// Resolve the operation locally without agent teardown (offline/
        /// unplaced delete): run the removal work, then record the verdict here.
        case directResolution(@Sendable (any Database) async throws -> Void)
    }

    /// Wraps a dispatch-work failure with a locating prefix so it reads well in
    /// the operation row's `error` — `.directResolution` records the thrown
    /// error's `localizedDescription`, which is bare without this.
    struct WorkError: Error, LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// Begins the operation (atomic insert + 409 double-submit guard + the
    /// caller's desired-state/spec mutation) and hands it off to the background
    /// dispatch, returning the pending row for the `202` response.
    @discardableResult
    func perform(
        _ kind: VMOperationKind,
        resourceKind: OperationResourceKind,
        resourceID: UUID,
        userID: UUID,
        hypervisorId: String?,
        dispatch strategy: Strategy,
        on db: any Database,
        app: Application,
        applying mutation: @escaping @Sendable (any Database) async throws -> Void = { _ in }
    ) async throws -> ResourceOperation {
        let operation = try await ResourceOperation.begin(
            kind, resourceKind: resourceKind, resourceID: resourceID, userID: userID,
            on: db, applying: mutation)
        dispatchInBackground(
            operation, resourceKind: resourceKind, resourceID: resourceID,
            hypervisorId: hypervisorId, strategy: strategy, app: app)
        return operation
    }

    /// Dispatches an operation that was begun *outside* the coordinator — the
    /// create path, whose retrying IPAM transaction owns its own row insert, and
    /// the sandbox expiry sweep. Same background hand-off and verdict path as
    /// `perform`, without the `begin`.
    func dispatch(
        _ operation: ResourceOperation,
        resourceKind: OperationResourceKind,
        resourceID: UUID,
        hypervisorId: String?,
        dispatch strategy: Strategy,
        app: Application
    ) {
        dispatchInBackground(
            operation, resourceKind: resourceKind, resourceID: resourceID,
            hypervisorId: hypervisorId, strategy: strategy, app: app)
    }

    /// Hands the freshly begun operation to a detached background task (the
    /// `202` has already gone out, so nothing here may assume the request is
    /// alive) and drives its dispatch strategy to a verdict.
    private func dispatchInBackground(
        _ operation: ResourceOperation,
        resourceKind: OperationResourceKind,
        resourceID: UUID,
        hypervisorId: String?,
        strategy: Strategy,
        app: Application
    ) {
        guard let operationID = operation.id else { return }
        let budget = operation.completionBudget

        switch strategy {
        case .stateSync:
            app.backgroundTasks.spawn {
                guard let agentId = hypervisorId else {
                    await recordVerdict(
                        operationID: operationID, as: .failed,
                        error: "This \(resourceKind.displayName) is not placed on any agent", on: app)
                    return
                }
                guard await agentDispatch.agentIsOnline(agentId: agentId) else {
                    await recordVerdict(
                        operationID: operationID, as: .failed,
                        error:
                            "Agent \(agentId) is offline; the \(resourceKind.displayName) cannot converge to the requested state",
                        on: app)
                    return
                }
                await agentDispatch.syncDesiredState(agentId: agentId)
            }

        case .awaitingResponse(let message):
            app.backgroundTasks.spawn {
                do {
                    let response = try await agentDispatch.performOperationAwaitingResponse(
                        message, resourceID: resourceID.uuidString, timeout: budget)
                    switch response {
                    case .success:
                        await recordVerdict(operationID: operationID, as: .succeeded, error: nil, on: app)
                    case .error(let message, let details):
                        let reason = details.map { "\(message): \($0)" } ?? message
                        await recordVerdict(operationID: operationID, as: .failed, error: reason, on: app)
                    }
                } catch {
                    await recordVerdict(
                        operationID: operationID, as: .failed, error: error.localizedDescription, on: app)
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
                    await recordVerdict(
                        operationID: operationID, as: .failed, error: error.localizedDescription, on: app)
                }
            }

        case .directResolution(let work):
            app.backgroundTasks.spawn {
                guard let db = app.liveDB else { return }
                do {
                    // If the sweep already failed this operation, stop: the user
                    // will retry, and resolving under a failed operation would
                    // contradict it.
                    guard let current = try await ResourceOperation.find(operationID, on: db),
                        current.status == .pending
                    else { return }
                    try await work(db)
                    await recordVerdict(operationID: operationID, as: .succeeded, error: nil, on: app)
                } catch {
                    await recordVerdict(
                        operationID: operationID, as: .failed, error: error.localizedDescription, on: app)
                }
            }
        }
    }

    /// The single verdict choke point for the controller and stuck-operation
    /// sweep paths: mark the operation terminal — but only if it is still
    /// pending, so the agent-response path and the sweep cannot overwrite each
    /// other's verdict — and, on failure, resolve the in-flight state the
    /// operation left on its resource. Every effect is drain-safe: it bails
    /// before touching a torn-down `app.db`.
    ///
    /// (The observed-state applier records its own verdicts inline; its
    /// convergence-failure resolution differs from resolve-after-verdict.)
    ///
    /// Returns whether this call won the race and recorded the verdict, so a
    /// caller that also wants to stamp a terminal resource status (e.g. a
    /// restore's `.running`) can gate that on having won — a lost race means the
    /// sweep already resolved the resource.
    @discardableResult
    func recordVerdict(
        operationID: UUID,
        as status: VMOperationStatus,
        error: String?,
        telemetryReason: String = "operation_failed",
        on app: Application
    ) async -> Bool {
        // Shutdown's drain cancels surviving background tasks before Vapor tears
        // down Fluent; bail before the first database access so a cancelled task
        // cannot dereference a torn-down `app.db`.
        guard let db = app.liveDB else { return false }
        do {
            guard let operation = try await ResourceOperation.find(operationID, on: db),
                try await operation.completeIfPending(as: status, error: error, on: db)
            else { return false }

            if status == .failed {
                logger.warning(
                    "Resource operation failed",
                    metadata: [
                        "operationId": .string(operationID.uuidString),
                        "resourceKind": .string(operation.resourceKind.rawValue),
                        "resourceId": .string(operation.resourceID.uuidString),
                        "kind": .string(operation.kind.rawValue),
                        "error": .string(error ?? "unknown"),
                    ])
            }

            // Only a failed operation needs resolving; a success left the
            // resource where the caller/applier already put it.
            guard status == .failed else { return true }

            // The awaits above may have spanned the drain — re-check before the
            // resource read/write. (This is the observed crash gap: the failure
            // warning logged, then a model `find` unwrapped a torn-down db.)
            guard !Task.isCancelled else { return true }

            switch operation.resourceKind {
            case .virtualMachine:
                if let vm = try await VM.find(operation.resourceID, on: db),
                    vm.resolveForStuckOperation(operation, telemetryReason: telemetryReason)
                {
                    try await vm.save(on: db)
                }
            case .sandbox:
                if let sandbox = try await Sandbox.find(operation.resourceID, on: db),
                    sandbox.resolveForStuckOperation(operation)
                {
                    try await sandbox.save(on: db)
                }
            }
            return true
        } catch {
            logger.error(
                "Failed to record operation verdict: \(error)",
                metadata: ["operationId": .string(operationID.uuidString)])
            return false
        }
    }
}

extension Application {
    /// The operation coordinator, built over the live `AgentService` dispatch
    /// adapter. Cheap to construct (it holds references), so it is materialized
    /// per access rather than stored.
    var resourceOperationCoordinator: ResourceOperationCoordinator {
        ResourceOperationCoordinator(agentDispatch: agentService, logger: logger)
    }
}

extension Request {
    var resourceOperationCoordinator: ResourceOperationCoordinator {
        application.resourceOperationCoordinator
    }
}
