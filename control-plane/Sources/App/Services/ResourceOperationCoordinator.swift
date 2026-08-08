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
}

extension AgentService: AgentDispatch {
    func agentIsOnline(agentId: String) async -> Bool {
        guard let agent = await getAgentInfo(agentId) else { return false }
        return agent.status == .online
    }
}

/// What is left of the operation side-table's machinery once every mutation has
/// converted: a verdict path for rows nothing writes any more.
///
/// The coordinator used to own an operation end to end — `begin` → dispatch →
/// `recordVerdict`. Stage 4 (STR-147) moved every generation-backed lifecycle
/// mutation to `ResourceMutation`, stage 8 (STR-150) took the snapshot verbs,
/// and stage 9 (STR-151) took the last one: **VM reboot**, whose
/// `awaitingResponse` strategy was the only dual-transport special case left in
/// this file and the only caller of the pending-request apparatus for a durable
/// resource. Nothing constructs a `ResourceOperation` now.
///
/// `recordVerdict` survives on purpose, and only for the upgrade: rows written
/// by the *previous* build can still be `pending` when this one starts, and the
/// stuck-operation sweep is what takes them terminal instead of leaving a client
/// polling forever. Once no such row can exist, this goes with the table (ADR
/// stage 11, STR-152).
struct ResourceOperationCoordinator {
    /// The agent seam. Injected so tests substitute a fake for the live actor.
    let agentDispatch: any AgentDispatch
    let logger: Logger

    /// Mark an operation terminal — but only if it is still pending, so two
    /// sweep passes cannot overwrite each other's verdict — and, on failure,
    /// resolve the in-flight state it left on its resource. Every effect is
    /// drain-safe: it bails before touching a torn-down `app.db`.
    ///
    /// (The observed-state applier records its own verdicts inline; its
    /// convergence-failure resolution differs from resolve-after-verdict.)
    ///
    /// Returns whether this call won the race and recorded the verdict.
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
