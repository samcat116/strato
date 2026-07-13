import Foundation
import StratoAgentCore
import StratoShared

/// Driver seam for the sandbox runtime (issue #421): the reconciler's sandbox
/// work items route here, exactly as VM items route to `HypervisorService`
/// implementations.
///
/// No implementation ships yet — `Agent.sandboxRuntime` stays nil and
/// `SandboxRuntimeProbe.runtimeBuilt` keeps the sandbox capability off, so the
/// control plane never places sandboxes on this build; sandbox work reaching a
/// nil runtime fails permanently with `SandboxRuntimeError.runtimeUnavailable`.
/// Issue #421 registers the real runtime and flips both.
///
/// Method contracts mirror `HypervisorService`: every operation must be
/// idempotent at the "already satisfied" level, because level-triggered syncs
/// re-drive any step whose effect was not yet observed.
protocol SandboxRuntimeService: Sendable {
    /// Materialize the sandbox's rootfs from its OCI image and define the
    /// microVM (ends "exists, not running" — `SandboxStatus.stopped`).
    func createSandbox(
        sandboxId: String,
        spec: SandboxSpec,
        registryCredential: RegistryCredential?,
        networkAttachments: [ResolvedNetworkAttachment]
    ) async throws

    func bootSandbox(sandboxId: String) async throws

    func shutdownSandbox(sandboxId: String) async throws

    /// Gracefully stop (best effort) and remove the sandbox from this host.
    func deleteSandbox(sandboxId: String) async throws

    /// Reconnect an orphan's Firecracker session and return its observed
    /// status, so the reconciler can plan the remaining convergence steps.
    func adoptSandbox(sandboxId: String, spec: SandboxSpec) async throws -> SandboxStatus

    func getSandboxStatus(sandboxId: String) async throws -> SandboxStatus

    /// Exit code of an `.exited` sandbox's workload, when the guest agent
    /// reported one over vsock.
    func exitCode(sandboxId: String) async -> Int?
}

/// Sandbox actuation failures raised by the Agent's reconcile routing (the
/// runtime's own errors surface as-is).
enum SandboxRuntimeError: Error, LocalizedError, ClassifiableError, Sendable {
    /// This build has no sandbox runtime driver. Permanent: retrying cannot
    /// grow one, only a new agent binary can (issue #421).
    case runtimeUnavailable
    /// The agent has no record of the sandbox.
    case sandboxNotFound(String)
    /// The reconciler planned a step outside the sandbox vocabulary
    /// (pause/resume have no sandbox meaning in v1). Permanent: replanning
    /// the same generation yields the same step.
    case unsupportedStep(String)

    var failureClassification: FailureClassification {
        switch self {
        case .runtimeUnavailable, .unsupportedStep:
            return .permanent
        case .sandboxNotFound:
            return .transient
        }
    }

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            return "this agent build does not include the sandbox runtime (issue #421)"
        case .sandboxNotFound(let id):
            return "sandbox not found: \(id)"
        case .unsupportedStep(let step):
            return "step '\(step)' is not supported for sandbox workloads"
        }
    }
}
