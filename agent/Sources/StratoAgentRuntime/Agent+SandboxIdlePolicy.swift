import Foundation
import StratoAgentCore
import StratoShared

extension Agent {
    /// Called on the sandbox's existing reconciliation lane by the future
    /// coordinated policy consumer. No timer, wire capability or activation is
    /// installed here until quota/wake and authoritative activity are complete.
    /// The control plane must first admit checkpoint storage and publish the
    /// suspended goal for this generation. Automatic provenance/dispatch is not
    /// installed; explicit opt-in stop keeps STR-312's separate manual path.
    /// Automatic callers always retain STR-312's host admission and reservations.
    func sandboxReconcileIdleSuspend(
        _ item: ReconcileWorkItem, policy suppliedPolicy: SandboxIdlePolicy? = nil,
        dependenciesReady: Bool = false
    ) async throws -> SandboxIdlePolicy.Verdict {
        let policy = suppliedPolicy ?? configuration.sandboxIdlePolicy
        guard policy.enabled, dependenciesReady else { return .disabled }
        guard item.kind == .sandbox, let desired = item.desiredSandbox,
            desired.desiredStatus == .suspended, desired.generation == item.generation,
            UUID(uuidString: item.id) == desired.sandboxId,
            let admittedBytes = desired.suspensionStorageBudgetBytes, admittedBytes > 0
        else { return .unknownActivity }
        let runtime = try requireSandboxRuntime()
        let verdict = await runtime.prepareIdleSuspension(sandboxId: item.id, policy: policy)
        guard verdict == .eligible else { return verdict }
        try await sandboxReconcileSuspend(item, automatic: true)
        return .eligible
    }
}
