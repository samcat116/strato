import Foundation
import Logging
import StratoShared

/// A no-op sandbox runtime that behaves like a real driver without ever
/// touching Firecracker — the sandbox counterpart of `MockHypervisorService`,
/// and the backend behind simulation mode's sandbox capability (issue #470).
/// It lets a fleet of dummy agents attract sandbox placements so sandbox
/// scheduling, reconciliation, exec bridging, and log shipping can be
/// scale-tested without a single real microVM.
///
/// Like the mock hypervisor it tracks each sandbox's spec and status so it
/// stays faithful to what the reconciler depends on: `getSandboxStatus()`
/// reflects the last lifecycle transition (so the reconciler converges instead
/// of looping), and every operation is idempotent at the "already satisfied"
/// level (level-triggered syncs re-drive any step whose effect was not yet
/// observed). Capacity accounting needs no help here — sandbox reservations
/// come from the agent's manifest, not from the runtime.
///
/// The exec surface honors the `SandboxRuntimeService` session contract
/// exactly — `.started`, then `.output`*, then **exactly one** terminal event
/// — because a session that emits zero or two terminal events wedges the
/// control plane's session teardown. Non-tty sessions run as one-shots
/// (echo the command, exit 0); tty sessions stay interactive (echo stdin back
/// as stdout) until EOF, `closeExec`, or sandbox teardown.
public actor MockSandboxRuntime: SandboxRuntimeService {
    private let logger: Logger

    /// Optional artificial delays so a simulated fleet exhibits boot/shutdown
    /// latency the control plane's operation tracking has to wait out.
    /// Defaults mirror `MockHypervisorService`.
    private let bootDelay: Duration
    private let shutdownDelay: Duration

    /// When set, a booted workload "runs to completion": its status flips to
    /// `.exited` (code 0) this long after boot, exercising the one-shot
    /// workload path (`exited` status + `exitCode` reporting). Nil means
    /// workloads run until stopped.
    private let workloadLifetime: Duration?

    /// When set, every running sandbox emits one synthetic workload log line
    /// per interval while the control plane is connected — the load source for
    /// scale-testing log shipping. Nil disables emission.
    private let logInterval: Duration?

    /// Sandboxes this mock is "managing", with the spec they were created from
    /// and their current lifecycle status.
    private struct MockSandbox {
        var spec: SandboxSpec
        var status: SandboxStatus
        var exitCode: Int?
        /// Monotonic per-sandbox line counter, so emitted log lines are
        /// distinguishable and survive suspend/resume like the real follow's
        /// seq checkpoint.
        var logLinesEmitted: Int = 0
    }
    private var sandboxes: [String: MockSandbox] = [:]

    /// Live interactive (tty) exec sessions. One-shot (non-tty) sessions end
    /// inside `startExec` and are never stored.
    private struct ExecSession {
        var sandboxId: String
        var events: @Sendable (SandboxExecEvent) -> Void
    }
    private var execSessions: [String: ExecSession] = [:]

    /// Tombstones for sessions that already ended (one-shot completion, EOF,
    /// close, or teardown), so a replayed `startExec` for a finished session
    /// cannot emit a second terminal event — session ids are minted per attach
    /// by the control plane, and each may see at most one terminal. Bounded
    /// FIFO: replays are near-in-time, so evicting old ids is safe and keeps a
    /// long-lived fleet from growing this without limit.
    private var completedExecSessions: Set<String> = []
    private var completedExecSessionOrder: [String] = []
    private static let completedExecSessionLimit = 1024

    private var logHandler: (@Sendable (String, String, String) -> Void)?
    /// One emitter task per running sandbox while the control plane is
    /// connected; suspended (cancelled) on disconnect, mirroring the real
    /// runtime's follow quiesce.
    private var logEmitters: [String: Task<Void, Never>] = [:]
    /// Pending one-shot workload-exit transitions (`workloadLifetime`).
    private var lifetimeTasks: [String: Task<Void, Never>] = [:]
    private var controlPlaneIsConnected = false

    public init(
        logger: Logger,
        bootDelay: Duration = .milliseconds(500),
        shutdownDelay: Duration = .milliseconds(200),
        workloadLifetime: Duration? = nil,
        logInterval: Duration? = nil
    ) {
        self.logger = logger
        self.bootDelay = bootDelay
        self.shutdownDelay = shutdownDelay
        self.workloadLifetime = workloadLifetime
        self.logInterval = logInterval
        logger.warning("Sandbox runtime running in mock mode - no real sandboxes will be created")
    }

    // MARK: - Lifecycle

    public func createSandbox(
        sandboxId: String,
        spec: SandboxSpec,
        registryCredential: RegistryCredential?,
        networkAttachments: [ResolvedNetworkAttachment]
    ) async throws {
        // Faithful to the real runtime: v1 sandboxes have no in-guest
        // networking, and quietly accepting a NIC here would let simulation
        // validate a config that fails on real hardware.
        guard spec.network == nil, networkAttachments.isEmpty else {
            throw SandboxRuntimeError.networkingUnsupported
        }
        logger.info("Creating mock sandbox (mock mode)", metadata: ["sandboxId": .string(sandboxId)])
        if var existing = sandboxes[sandboxId] {
            // Replayed create: refresh the spec, never regress the status.
            existing.spec = spec
            sandboxes[sandboxId] = existing
            return
        }
        sandboxes[sandboxId] = MockSandbox(spec: spec, status: .stopped)
    }

    public func bootSandbox(sandboxId: String) async throws {
        guard let sandbox = sandboxes[sandboxId] else {
            throw SandboxRuntimeError.sandboxNotFound(sandboxId)
        }
        guard sandbox.status != .running else { return }
        logger.info("Booting mock sandbox (mock mode)", metadata: ["sandboxId": .string(sandboxId)])
        try await Task.sleep(for: bootDelay)  // Simulate boot delay
        markRunning(sandboxId)
    }

    public func shutdownSandbox(sandboxId: String) async throws {
        guard let sandbox = sandboxes[sandboxId] else {
            throw SandboxRuntimeError.sandboxNotFound(sandboxId)
        }
        guard sandbox.status != .stopped else { return }
        logger.info("Shutting down mock sandbox (mock mode)", metadata: ["sandboxId": .string(sandboxId)])
        // Delay first, teardown after: the sleep throws on cancellation, and
        // tearing down before it could leave a cancelled shutdown with a
        // "running" sandbox whose emitter and exec sessions are already gone.
        // It also keeps the workload live through the graceful-stop window,
        // like a real guest.
        try await Task.sleep(for: shutdownDelay)  // Simulate shutdown delay
        endWorkloadActivity(sandboxId: sandboxId, execCloseReason: "sandbox stopped")
        sandboxes[sandboxId]?.status = .stopped
    }

    public func deleteSandbox(sandboxId: String) async throws {
        logger.info("Deleting mock sandbox (mock mode)", metadata: ["sandboxId": .string(sandboxId)])
        endWorkloadActivity(sandboxId: sandboxId, execCloseReason: "sandbox deleted")
        sandboxes.removeValue(forKey: sandboxId)
    }

    /// Re-adopts a sandbox across an agent restart. Like the mock hypervisor,
    /// there is no process to reattach — the mock resumes tracking the spec
    /// and reports the sandbox running, so a simulated agent restart converges
    /// exactly like a real one.
    public func adoptSandbox(sandboxId: String, spec: SandboxSpec) async throws -> SandboxStatus {
        logger.info("Re-adopting mock sandbox (mock mode)", metadata: ["sandboxId": .string(sandboxId)])
        sandboxes[sandboxId] = MockSandbox(spec: spec, status: .stopped)
        markRunning(sandboxId)
        return .running
    }

    public func getSandboxStatus(sandboxId: String) async throws -> SandboxStatus {
        guard let sandbox = sandboxes[sandboxId] else {
            throw SandboxRuntimeError.sandboxNotFound(sandboxId)
        }
        return sandbox.status
    }

    public func exitCode(sandboxId: String) async -> Int? {
        sandboxes[sandboxId]?.exitCode
    }

    /// Transition to `.running` and start the running-state side activity
    /// (log emission, the optional one-shot lifetime clock).
    private func markRunning(_ sandboxId: String) {
        guard sandboxes[sandboxId] != nil else { return }
        sandboxes[sandboxId]?.status = .running
        sandboxes[sandboxId]?.exitCode = nil
        startLogEmitter(sandboxId: sandboxId)
        scheduleWorkloadExit(sandboxId: sandboxId)
    }

    /// Stop everything tied to a running workload: the log emitter, the
    /// lifetime clock, and every live exec session (each session's control
    /// plane side gets exactly one `.closed` with the reason).
    private func endWorkloadActivity(sandboxId: String, execCloseReason: String) {
        stopLogEmitter(sandboxId: sandboxId)
        lifetimeTasks.removeValue(forKey: sandboxId)?.cancel()
        for (sessionId, session) in execSessions where session.sandboxId == sandboxId {
            execSessions.removeValue(forKey: sessionId)
            recordCompletedExecSession(sessionId)
            session.events(.closed(reason: execCloseReason))
        }
    }

    /// Tombstone a finished session id (bounded FIFO eviction).
    private func recordCompletedExecSession(_ sessionId: String) {
        guard completedExecSessions.insert(sessionId).inserted else { return }
        completedExecSessionOrder.append(sessionId)
        if completedExecSessionOrder.count > Self.completedExecSessionLimit {
            completedExecSessions.remove(completedExecSessionOrder.removeFirst())
        }
    }

    private func scheduleWorkloadExit(sandboxId: String) {
        guard let workloadLifetime else { return }
        lifetimeTasks[sandboxId]?.cancel()
        lifetimeTasks[sandboxId] = Task { [weak self] in
            try? await Task.sleep(for: workloadLifetime)
            guard !Task.isCancelled else { return }
            await self?.workloadExited(sandboxId: sandboxId)
        }
    }

    private func workloadExited(sandboxId: String) {
        guard let sandbox = sandboxes[sandboxId], sandbox.status == .running else { return }
        logger.info("Mock sandbox workload exited (mock mode)", metadata: ["sandboxId": .string(sandboxId)])
        endWorkloadActivity(sandboxId: sandboxId, execCloseReason: "sandbox workload exited")
        sandboxes[sandboxId]?.status = .exited
        sandboxes[sandboxId]?.exitCode = 0
    }

    // MARK: - Exec sessions

    public func startExec(
        sandboxId: String,
        sessionId: String,
        request: SandboxExecRequest,
        events: @escaping @Sendable (SandboxExecEvent) -> Void
    ) async throws {
        guard let sandbox = sandboxes[sandboxId] else {
            throw SandboxRuntimeError.sandboxNotFound(sandboxId)
        }
        guard execSessions[sessionId] == nil, !completedExecSessions.contains(sessionId) else {
            // Session ids are minted per attach by the control plane; a
            // duplicate start is a stream replay we must not double-bridge —
            // whether the session is still live or already ended (re-running a
            // finished one-shot would emit a second terminal event).
            return
        }
        guard sandbox.status == .running else {
            // The real runtime's guest connection would fail on a sandbox
            // that is not running; surface the same refusal.
            throw SandboxRuntimeError.sandboxNotFound("\(sandboxId) (not running)")
        }

        logger.info(
            "Starting mock sandbox exec session (mock mode)",
            metadata: [
                "sandboxId": .string(sandboxId),
                "sessionId": .string(sessionId),
                "tty": .stringConvertible(request.tty),
            ])

        // Confirmed "spawn": report `.started` before any output. The Agent's
        // pump serializes delivery, so emitting the whole session synchronously
        // preserves the per-session event order the contract requires.
        events(.started)
        if request.tty {
            // Interactive: the session stays live and echoes stdin back as
            // stdout until EOF, closeExec, or sandbox teardown.
            execSessions[sessionId] = ExecSession(sandboxId: sandboxId, events: events)
        } else {
            // One-shot: echo the command and exit — the session's single
            // terminal event. Tombstoned so a replayed start cannot re-run it.
            recordCompletedExecSession(sessionId)
            let line = "simulated exec: \(request.command.joined(separator: " "))\n"
            events(.output(stream: "stdout", data: Data(line.utf8)))
            events(.exited(code: 0))
        }
    }

    public func sendExecInput(sessionId: String, data: Data?, eof: Bool) async throws {
        guard let session = execSessions[sessionId] else {
            throw SandboxRuntimeError.execSessionNotFound(sessionId)
        }
        if let data, !data.isEmpty {
            session.events(.output(stream: "stdout", data: data))
        }
        if eof {
            // Stdin EOF ends the interactive workload, like `cat`: the exit
            // is the session's single terminal event.
            execSessions.removeValue(forKey: sessionId)
            recordCompletedExecSession(sessionId)
            session.events(.exited(code: 0))
        }
    }

    public func resizeExec(sessionId: String, rows: Int, cols: Int) async throws {
        guard execSessions[sessionId] != nil else {
            throw SandboxRuntimeError.execSessionNotFound(sessionId)
        }
        // Accepted and discarded — nothing to resize.
    }

    public func closeExec(sessionId: String) async {
        // Idempotent; no event is emitted for a session closed this way (the
        // requester already knows). Still tombstoned: the session is over, so
        // a replayed start must not resurrect it.
        guard execSessions.removeValue(forKey: sessionId) != nil else { return }
        recordCompletedExecSession(sessionId)
    }

    // MARK: - Control-plane connectivity

    public func controlPlaneDisconnected() async {
        controlPlaneIsConnected = false
        // Exec sessions: their frontends are unreachable and the control plane
        // cannot send sandboxExecClose over the dead socket — end them, as the
        // real runtime does (the .closed events are dropped by the dead send
        // path, which is fine).
        for (sessionId, session) in execSessions {
            execSessions.removeValue(forKey: sessionId)
            recordCompletedExecSession(sessionId)
            session.events(.closed(reason: "control plane disconnected"))
        }
        // Log emission: suspend, keeping each sandbox's line counter, so
        // emission resumes where it left off — the analogue of the real
        // follow's seq checkpoint.
        for sandboxId in Array(logEmitters.keys) {
            stopLogEmitter(sandboxId: sandboxId)
        }
    }

    public func controlPlaneConnected() async {
        controlPlaneIsConnected = true
        for (sandboxId, sandbox) in sandboxes where sandbox.status == .running {
            startLogEmitter(sandboxId: sandboxId)
        }
    }

    // MARK: - Workload log emission

    public func setSandboxLogHandler(_ handler: @escaping @Sendable (String, String, String) -> Void) async {
        logHandler = handler
    }

    /// Start the sandbox's synthetic log emitter, if emission is configured
    /// and the control plane is connected. Idempotent — an emitter that is
    /// already running is left alone.
    private func startLogEmitter(sandboxId: String) {
        guard let logInterval, controlPlaneIsConnected, logEmitters[sandboxId] == nil else { return }
        logEmitters[sandboxId] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: logInterval)
                guard !Task.isCancelled else { return }
                await self?.emitLogLine(sandboxId: sandboxId)
            }
        }
    }

    private func stopLogEmitter(sandboxId: String) {
        logEmitters.removeValue(forKey: sandboxId)?.cancel()
    }

    private func emitLogLine(sandboxId: String) {
        // Re-check the connection: a disconnect cancels the emitter, but a
        // callback already queued on the actor still runs — drop it instead of
        // emitting one late line into a dead send path.
        guard controlPlaneIsConnected, let logHandler else { return }
        guard let sandbox = sandboxes[sandboxId], sandbox.status == .running else { return }
        let line = sandbox.logLinesEmitted + 1
        sandboxes[sandboxId]?.logLinesEmitted = line
        logHandler(sandboxId, "stdout", "simulated workload log line \(line)")
    }
}
