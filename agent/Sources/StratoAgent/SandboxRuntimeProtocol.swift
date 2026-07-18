import Foundation
import StratoAgentCore
import StratoShared

/// Driver seam for the sandbox runtime (issue #421): the reconciler's sandbox
/// work items route here, exactly as VM items route to `HypervisorService`
/// implementations. `FirecrackerSandboxRuntime` is the shipping driver (Linux
/// only); on builds without one, `Agent.sandboxRuntime` stays nil, the sandbox
/// capability stays off, and sandbox work reaching a nil runtime fails
/// permanently with `SandboxRuntimeError.runtimeUnavailable`.
///
/// Method contracts mirror `HypervisorService`: every operation must be
/// idempotent at the "already satisfied" level, because level-triggered syncs
/// re-drive any step whose effect was not yet observed. The exec/log surface
/// (issue #423) is stream-shaped instead: sessions are keyed by the control
/// plane's sessionId and end with exactly one terminal event.
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

    // MARK: Snapshots / checkpoint-resume (issue #426)

    /// Checkpoint the sandbox: drain host↔guest connections, pause the
    /// microVM, capture guest memory + vmstate via the Firecracker snapshot
    /// API, copy the rootfs while paused, then resume (`.resume`) or stay
    /// stopped (`.stop`). The runtime owns the artifact layout (host-side,
    /// beside the sandbox) and reports sizes + the Firecracker version the
    /// snapshot is tied to.
    func snapshotSandbox(
        sandboxId: String, snapshotId: String, mode: SandboxSnapshotMode
    ) async throws -> SandboxSnapshotResult

    /// Restore the sandbox in place from one of its snapshots: tear down the
    /// current microVM process, re-stage the checkpointed rootfs, spawn a
    /// fresh Firecracker, load the snapshot, resume, and confirm the guest
    /// answers. Same identity — the vsock wiring and (future) NIC devices come
    /// back under their original names from the snapshotted device topology.
    func restoreSandbox(sandboxId: String, snapshotId: String) async throws

    /// Remove a snapshot's artifacts from this host. Idempotent: deleting a
    /// snapshot that left no files (or was already deleted) succeeds.
    func deleteSandboxSnapshot(sandboxId: String, snapshotId: String) async throws

    // MARK: Exec sessions and workload logs (issue #423)

    /// Start an exec session inside a running sandbox: spawn `request.command`
    /// in the workload's container context over a dedicated guest connection.
    ///
    /// Returns once the guest confirmed the spawn (after emitting `.started`
    /// through `events`); throws if the sandbox is unknown or the guest
    /// refused/failed the spawn. After a successful return, `events` receives
    /// the session's `.output` records in guest order, ending with exactly one
    /// terminal event: `.exited` (process reaped) or `.closed` (channel died,
    /// sandbox stopped, or `closeExec`).
    func startExec(
        sandboxId: String,
        sessionId: String,
        request: SandboxExecRequest,
        events: @escaping @Sendable (SandboxExecEvent) -> Void
    ) async throws

    /// Write stdin bytes to a live exec session and/or close its stdin.
    func sendExecInput(sessionId: String, data: Data?, eof: Bool) async throws

    /// Resize a live exec session's PTY.
    func resizeExec(sessionId: String, rows: Int, cols: Int) async throws

    /// Tear down an exec session: closing the guest connection kills the exec
    /// process group. Idempotent; no event is emitted for a session closed
    /// this way (the requester already knows).
    func closeExec(sessionId: String) async

    /// Install the handler that receives the workload's stdout/stderr, one
    /// assembled line at a time, as `(sandboxId, stream, line)`. Lines for one
    /// sandbox are delivered in order. Set once, at agent startup, before any
    /// sandbox runs.
    func setSandboxLogHandler(_ handler: @escaping @Sendable (String, String, String) -> Void) async

    /// The control-plane WebSocket dropped. Ends every live exec session (the
    /// control plane tears down its side but cannot send `sandboxExecClose`
    /// over a dead socket — closing guest-side kills the exec process groups,
    /// so quiet processes don't outlive their frontends) and suspends log
    /// follows so workload output stays in the guest ring buffer instead of
    /// being consumed toward a socket that cannot deliver it.
    func controlPlaneDisconnected() async

    /// The control-plane WebSocket is (re)established: resume log follows for
    /// live sandboxes, picking up from each sandbox's seq checkpoint.
    /// Idempotent — a follow that is already running is left alone.
    func controlPlaneConnected() async
}

/// What one completed sandbox snapshot left on disk (issue #426): the input
/// for the agent's `SandboxSnapshotStatusResponse` back to the control plane.
struct SandboxSnapshotResult: Sendable {
    let memorySizeBytes: Int64
    let vmstateSizeBytes: Int64
    let rootfsSizeBytes: Int64
    /// The agent-owned directory holding the snapshot artifacts.
    let storagePath: String
    /// `vmm_version` of the Firecracker that took the snapshot.
    let firecrackerVersion: String

    var totalSizeBytes: Int64 { memorySizeBytes + vmstateSizeBytes + rootfsSizeBytes }
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
    /// An orphaned sandbox's Firecracker process is gone, so there is nothing
    /// to re-attach. The Agent catches this during adoption and re-creates the
    /// sandbox from its desired entry (mirroring the VM path).
    case adoptionTargetGone(String)
    /// An exec input/resize referenced a session this runtime is not tracking
    /// (never started, or already ended). The Agent answers with
    /// `sandboxExecClosed` so the control plane tears its side down.
    case execSessionNotFound(String)
    /// The sandbox requested a NIC, but v1 has no in-guest networking: the guest
    /// init does not bring up `eth0`/DHCP and the guest kernel has no IP
    /// autoconfiguration, so a TAP would leave the workload with an
    /// unconfigured interface while the sandbox reported running. Permanent
    /// until guest-side networking lands (a guest-image change).
    case networkingUnsupported
    /// Setting up the jailer barrier (issue #425) failed host-side — chroot
    /// staging, ownership, or the network namespace. Transient: these are
    /// filesystem/tooling operations a retry can succeed at once the host
    /// condition (disk pressure, an iproute2 hiccup) clears.
    case jailSetupFailed(String)
    /// `sandbox_jailer_mode = "required"` is unmet on this host, so creating
    /// a sandbox (which would have to run unjailed) is refused; existing
    /// sandboxes are still adopted and torn down. Permanent: only a host or
    /// config change (and an agent restart) can satisfy the mode.
    case jailerRequiredUnavailable(String)
    /// A checkpoint or restore is in flight for this sandbox, so lifecycle
    /// operations that would race it (boot, stop, exec) are refused.
    /// Transient by construction: the checkpoint finishes.
    case checkpointInProgress(String)
    /// The referenced snapshot has no artifacts on this host.
    case snapshotNotFound(sandboxId: String, snapshotId: String)
    /// The sandbox has no state worth checkpointing (never booted), or its
    /// state cannot be captured.
    case notSnapshottable(String)
    /// Copying or moving snapshot artifacts failed host-side. Transient:
    /// disk pressure or an I/O hiccup a retry can clear.
    case snapshotIOFailed(String)

    var failureClassification: FailureClassification {
        switch self {
        case .runtimeUnavailable, .unsupportedStep, .networkingUnsupported, .jailerRequiredUnavailable,
            .notSnapshottable, .snapshotNotFound:
            return .permanent
        case .sandboxNotFound, .adoptionTargetGone, .execSessionNotFound, .jailSetupFailed,
            .checkpointInProgress, .snapshotIOFailed:
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
        case .adoptionTargetGone(let reason):
            return "sandbox adoption target gone: \(reason)"
        case .execSessionNotFound(let sessionId):
            return "exec session not found: \(sessionId)"
        case .networkingUnsupported:
            return "networked sandboxes are not supported yet (the guest image has no in-guest networking)"
        case .jailSetupFailed(let reason):
            return "sandbox jail setup failed: \(reason)"
        case .jailerRequiredUnavailable(let reason):
            return "sandbox_jailer_mode is 'required' but the jailer is unusable: \(reason)"
        case .checkpointInProgress(let id):
            return "a checkpoint or restore is in progress for sandbox \(id)"
        case .snapshotNotFound(let sandboxId, let snapshotId):
            return "snapshot \(snapshotId) of sandbox \(sandboxId) has no artifacts on this host"
        case .notSnapshottable(let reason):
            return "sandbox cannot be checkpointed: \(reason)"
        case .snapshotIOFailed(let reason):
            return "snapshot artifact I/O failed: \(reason)"
        }
    }
}
