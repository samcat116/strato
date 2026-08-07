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

    /// Signal that the agent's desired state changed — by ringing the
    /// broadcast doorbell, plus a direct push when this replica holds the
    /// socket of a push-mode agent. Losing the signal is safe: the agent
    /// re-fetches (or is re-pushed) on its own interval regardless.
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
/// #259/#412).
///
/// Its remit is now the *residue* of ADR 0001 stage 4 (STR-147): the mutations
/// that are still imperative agent RPCs with no generation to converge on, and
/// so still need a side-table row to carry their in-flight state — VM reboot,
/// and the VM/sandbox snapshot verbs. Every generation-backed lifecycle
/// mutation moved to `ResourceMutation`, which answers from the resource's own
/// `conditions` instead. What is left here retires with STR-151 (reboot as an
/// edge-nonce) and ADR stage 8 (snapshots as desired artifacts).
///
/// Divergence between resource kinds rides the `OperationResourceKind`
/// discriminator (its budgets, its `resolveForStuckOperation`), not a generic
/// protocol.
struct ResourceOperationCoordinator {
    /// The agent seam. Injected so tests substitute a fake for the live actor.
    let agentDispatch: any AgentDispatch
    let logger: Logger

    /// How an operation reaches its agent after `begin`.
    ///
    /// One case, since the state-sync/placement/direct-resolution strategies
    /// went with the lifecycle mutations: what remains is genuinely imperative.
    enum Strategy {
        /// Await a correlated imperative agent command and record the verdict
        /// immediately from the response (VM reboot).
        case awaitingResponse(MessageType)
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
        dispatch strategy: Strategy,
        on db: any Database,
        app: Application,
        applying mutation: @escaping @Sendable (any Database) async throws -> Void = { _ in }
    ) async throws -> ResourceOperation {
        let operation = try await ResourceOperation.begin(
            kind, resourceKind: resourceKind, resourceID: resourceID, userID: userID,
            on: db, applying: mutation)
        dispatchInBackground(operation, resourceID: resourceID, strategy: strategy, app: app)
        return operation
    }

    /// Hands the freshly begun operation to a detached background task (the
    /// `202` has already gone out, so nothing here may assume the request is
    /// alive) and drives its dispatch strategy to a verdict.
    private func dispatchInBackground(
        _ operation: ResourceOperation,
        resourceID: UUID,
        strategy: Strategy,
        app: Application
    ) {
        guard let operationID = operation.id else { return }
        let budget = operation.completionBudget

        switch strategy {
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
                    vm.resolveForStuckOperation(
                        mutation: operation.kind, telemetryReason: telemetryReason)
                {
                    try await vm.save(on: db)
                }
            case .sandbox:
                if let sandbox = try await Sandbox.find(operation.resourceID, on: db),
                    sandbox.resolveForStuckOperation(
                        mutation: operation.kind, telemetryReason: telemetryReason)
                {
                    try await sandbox.save(on: db)
                }
            case .volume, .volumeSnapshot, .vmCheckpoint, .sandboxSnapshot:
                // Unreachable: none of these write operation rows at all
                // (STR-148, STR-150). Their failed mutations resolve through
                // the stuck-convergence sweep, which calls the same
                // `resolveForStuckOperation`.
                break
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
