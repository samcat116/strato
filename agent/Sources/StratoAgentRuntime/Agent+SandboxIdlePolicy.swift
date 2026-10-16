import Foundation
import StratoAgentCore
import StratoShared

extension Agent {
    /// Runs on the sandbox reconciliation lane. CP provenance/storage, root
    /// opt-in and fresh runtime eligibility precede STR-312's host admission.
    func sandboxReconcileIdleSuspend(
        _ item: ReconcileWorkItem, policy suppliedPolicy: SandboxIdlePolicy? = nil,
        dependenciesReady: Bool = false
    ) async throws -> SandboxIdlePolicy.Verdict {
        let policy = suppliedPolicy ?? configuration.sandboxIdlePolicy
        guard policy.enabled, dependenciesReady else { return .disabled }
        guard item.kind == .sandbox, let desired = item.desiredSandbox,
            desired.desiredStatus == .suspended, desired.generation == item.generation,
            UUID(uuidString: item.id) == desired.sandboxId,
            let admittedBytes = desired.suspensionStorageBudgetBytes, admittedBytes > 0,
            let fence = desired.automaticSuspensionFence, fence.isValid, fence.generation == item.generation
        else { return .unknownActivity }
        let runtime = try requireSandboxRuntime()
        let verdict = await runtime.prepareIdleSuspension(sandboxId: item.id, policy: policy)
        guard verdict == .eligible else { return verdict }
        try await sandboxReconcileSuspend(item, automatic: true, fence: fence)
        return .eligible
    }
}

#if os(Linux)
extension Agent {
    func exchangeSandboxIdleFence(_ context: SandboxSuspensionFenceContext, request: SandboxIdleGuestRequest)
        async throws -> SandboxIdleGuestResponse
    {
        guard let runtime = sandboxRuntime as? FirecrackerSandboxRuntime else {
            throw SandboxSuspensionGuard.GateError.stale
        }
        return try await runtime.exchangeIdleFence(context, request: request)
    }
}
#endif
