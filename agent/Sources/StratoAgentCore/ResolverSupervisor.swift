import Foundation
import Logging

/// A running resolver, from the agent's side.
public protocol ResolverHandle: Sendable {
    /// False once the child has exited, however it exited.
    var isRunning: Bool { get }
    var processIdentifier: Int32 { get }
    /// When the child exited, or nil while it is still running.
    ///
    /// The *moment* matters, not just the fact: the failure counter is cleared
    /// by a run that lasted, and exits are noticed on the next reconcile — which
    /// can be `desired_state_full_refetch_seconds` later. Measuring to the
    /// moment it was noticed would make a child that died instantly look like
    /// one that ran for five minutes, which is the same bug as resetting the
    /// counter on a successful spawn, reached a different way.
    var exitedAt: Date? { get }
    /// SIGTERM, then SIGKILL after a grace period.
    func terminate() async
}

/// A resolver a previous incarnation of this agent left running.
public struct AdoptableResolver: Sendable, Equatable {
    public let pid: Int32

    public init(pid: Int32) {
        self.pid = pid
    }
}

/// Everything the supervisor does that touches the host.
///
/// Injected for `MetadataServerSpawning`'s reason, and it is the same reason
/// twice over: the half of a supervisor worth asserting is the half that
/// *stops* things, and none of it can be reached from a test while the actor
/// forks processes and writes files directly. Adoption after a restart, the
/// stop/reconcile race, and whether the failure counter actually counts
/// failures are all lifecycle questions, not process questions.
public protocol ResolverHosting: Sendable {
    /// Write the rendered Corefile and zone files, and sweep any file the
    /// rendering no longer contains. Throws so a failed write can block the
    /// start that would otherwise run against a half-written Corefile.
    func writeConfiguration(_ resolver: DesiredResolver, root: String) throws
    /// Remove the resolver's directory entirely.
    func removeConfiguration(root: String)
    /// Start CoreDNS in the host namespace.
    func spawn(root: String) throws -> any ResolverHandle
    /// A resolver a previous agent process left running, recovered from the pid
    /// file under `root`. Returned only when the pid is alive *and* is this
    /// agent's CoreDNS; otherwise the directory is swept.
    func adoptable(root: String) -> AdoptableResolver?
    func isAlive(pid: Int32) -> Bool
    /// Signal a process this agent did not fork, and so holds no handle for.
    func terminate(pid: Int32) async
}

/// Schedules one resolver restart and returns a cancellation action.
///
/// The production scheduler sleeps on the continuous clock. Tests replace it
/// with a controllable clock that runs due work inline, so crossing the backoff
/// boundary never depends on wall time or cooperative-executor timing.
struct ResolverRestartScheduler: Sendable {
    typealias Operation = @Sendable () async -> Void
    typealias Cancellation = @Sendable () -> Void

    private let scheduleOperation: @Sendable (Date, @escaping Operation) -> Cancellation

    init(_ scheduleOperation: @escaping @Sendable (Date, @escaping Operation) -> Cancellation) {
        self.scheduleOperation = scheduleOperation
    }

    func schedule(at deadline: Date, operation: @escaping Operation) -> Cancellation {
        scheduleOperation(deadline, operation)
    }

    static let continuous = ResolverRestartScheduler { deadline, operation in
        let task = Task {
            let remaining = deadline.timeIntervalSinceNow
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
            guard !Task.isCancelled else { return }
            await operation()
        }
        return { task.cancel() }
    }
}

/// Runs the single CoreDNS that serves every resolver-enabled network on this
/// host (STR-40).
///
/// The lifecycle half of the resolver. What to render lives in
/// `CoreDNSZoneRenderer` and what to do lives in `ResolverSupervisionPolicy`;
/// this owns the state machine between them, and delegates every host effect to
/// `ResolverHosting` so the state machine is testable.
///
/// ## Why one process for the whole host
///
/// The resolver terminates in the **host** namespace (`ResolverHostPortPlan`),
/// which is what gives it egress to forward with — see ADR 0008. One namespace
/// means one process can bind every network's addresses, and CoreDNS keys a
/// server block on its zone *and* its `bind` addresses, so two networks can
/// serve the same zone name with different contents from it. The addresses
/// being distinct per network is what makes that work.
///
/// It also concentrates the blast radius, which is why nothing routine here
/// restarts the process: a restart is a resolution gap for *every* network on
/// the host, so a config change is written and left to the Corefile's `reload`.
///
/// ## Why this is not part of the network reconcile's authority half
///
/// A resolver serves the guests on *this* host, so it runs wherever they do,
/// including on agents that may not author topology. Its input is the same
/// per-NIC opt-out the chassis namespace uses, and it converges alongside it —
/// before the authority guard.
public actor ResolverSupervisor {
    private let root: String
    private let host: any ResolverHosting
    private let now: @Sendable () -> Date
    private let restartScheduler: ResolverRestartScheduler
    private let logger: Logger

    private var state = ResolverState()
    private var adopted = false
    private var scheduledRestart: (deadline: Date, cancel: ResolverRestartScheduler.Cancellation)?

    private struct ResolverState {
        var handle: (any ResolverHandle)?
        /// A process this agent did not fork — one a previous incarnation
        /// started and this one adopted. There is no handle for it, so liveness
        /// is probed by pid instead.
        var adoptedPID: Int32?
        var configurationDigest: String?
        /// The inputs the cached rendering was built from, so an unchanged host
        /// skips the render entirely — see `ResolverRenderKey`.
        var renderKey: ResolverRenderKey?
        /// The last rendering, reused whenever `renderKey` still matches.
        var rendering: DesiredResolver?
        var consecutiveFailures = 0
        /// When the current child was started, so an exit can be judged against
        /// how long it survived rather than against the fact that `fork`
        /// succeeded. See `recordExit`.
        var startedAt: Date?
        /// When a restart may next be attempted. Nil means immediately.
        var nextStartAllowedAt: Date?

        /// Whether something is serving right now.
        ///
        /// The adopted arm is load-bearing: without it an adopted CoreDNS reads
        /// as "not running" on the first reconcile after an agent restart, and
        /// the supervisor starts a **second** one — which then fails to bind and
        /// crash-loops beside a healthy one. With a single host-wide process
        /// that second start would take DNS away from every network at once,
        /// so it matters more here than it did per network.
        func isRunning(isAlive: (Int32) -> Bool) -> Bool {
            if let handle { return handle.isRunning }
            if let adoptedPID { return isAlive(adoptedPID) }
            return false
        }
    }

    public init(
        root: String,
        host: any ResolverHosting,
        now: @escaping @Sendable () -> Date = Date.init,
        logger: Logger
    ) {
        self.root = root
        self.host = host
        self.now = now
        self.restartScheduler = .continuous
        self.logger = logger
    }

    init(
        root: String,
        host: any ResolverHosting,
        now: @escaping @Sendable () -> Date,
        restartScheduler: ResolverRestartScheduler,
        logger: Logger
    ) {
        self.root = root
        self.host = host
        self.now = now
        self.restartScheduler = restartScheduler
        self.logger = logger
    }

    /// Converge this host's resolver toward `request`.
    ///
    /// Nil ≙ a sync with no opinion, which stops nothing — the contract every
    /// other level-triggered list in the agent carries, and the one that matters
    /// most here: a control plane that cannot describe this host must not take
    /// DNS away from every network on it. A request with no networks *is* an
    /// opinion and stops the process.
    public func reconcile(_ request: ResolverRenderRequest?) async {
        guard let request else { return }
        if !adopted {
            adoptFromDisk()
            adopted = true
        }

        // A child that died on its own is not running, whatever the map says.
        // Recording the exit here rather than from a termination callback is
        // what makes the failure accounting deterministic — and it is the shape
        // `MetadataServerSupervisor` already uses for the same job.
        if state.handle?.isRunning == false { recordExit() }

        // Render only what moved. The key folds in every network's per-zone
        // `recordsHash` and its three other inputs, so a steady-state sync —
        // which is nearly all of them — costs a few string comparisons instead
        // of rebuilding every zone file on the host.
        let key = request.renderKey
        if state.renderKey != key || state.rendering == nil {
            state.rendering = request.render()
            state.renderKey = key
        }
        guard let desired = state.rendering else { return }

        // A pending restart was scheduled for an earlier non-empty desired
        // state. Once the host serves no resolver-enabled network, that work is
        // no longer authorized even if there is no live process for `.stop` to
        // reap.
        if desired.servesNothing { cancelScheduledRestart() }

        for action in ResolverSupervisionPolicy.actions(
            desired: desired, observed: observedState())
        {
            switch action {
            case .writeConfiguration: write(desired)
            case .start: start(desired)
            case .stop: await stop()
            }
        }
    }

    /// Stops the resolver, for agent shutdown. A draining host must not keep
    /// answering for networks it no longer converges.
    public func shutdown() async { await stop() }

    /// Whether this host is serving. For tests and the agent's diagnostics.
    public func isServing() -> Bool { state.isRunning(isAlive: host.isAlive) }

    /// Consecutive failures recorded. Exposed so the escalation this counter
    /// drives is assertable — it was not, and a bug that made the whole backoff
    /// unreachable survived because of it.
    public func failures() -> Int { state.consecutiveFailures }

    private func observedState() -> ObservedResolver {
        ObservedResolver(
            pid: state.handle?.processIdentifier ?? state.adoptedPID,
            running: state.isRunning(isAlive: host.isAlive),
            configurationDigest: state.configurationDigest,
            consecutiveFailures: state.consecutiveFailures)
    }

    // MARK: - Effects

    private func write(_ desired: DesiredResolver) {
        do {
            try host.writeConfiguration(desired, root: root)
            state.configurationDigest = desired.configurationDigest
            for diagnostic in desired.diagnostics {
                logger.warning(
                    "Resolver zone rendering skipped a record", metadata: ["detail": .string(diagnostic)])
            }
        } catch {
            logger.error(
                "Failed to write resolver configuration",
                metadata: ["error": .string(error.localizedDescription)])
            // Leave the digest unset so the next pass rewrites and retries
            // rather than believing the files on disk match what was rendered.
            state.configurationDigest = nil
        }
    }

    private func start(_ desired: DesiredResolver) {
        if let allowed = state.nextStartAllowedAt, allowed > now() {
            // Still inside the backoff window. Returning silently is deliberate:
            // this runs on every sync, and a log line per suppressed retry would
            // drown the one that explains the failure.
            scheduleRestart(at: allowed)
            return
        }
        // A scheduled retry and an ordinary desired-state reconcile can become
        // runnable together. Actor isolation serializes them, and this liveness
        // check makes the second arrival a no-op rather than a second CoreDNS.
        guard !state.isRunning(isAlive: host.isAlive) else {
            cancelScheduledRestart()
            return
        }
        // Nothing was written yet — the write failed, and starting CoreDNS
        // against a missing or half-written Corefile is how a crash loop starts.
        guard state.configurationDigest != nil else { return }

        do {
            let handle = try host.spawn(root: root)
            state.handle = handle
            state.adoptedPID = nil
            state.startedAt = now()
            state.nextStartAllowedAt = nil
            cancelScheduledRestart()
            // Deliberately *not* clearing `consecutiveFailures` here. A
            // successful `fork` proves nothing: the failures this backoff exists
            // for spawn cleanly and exit a moment later, so clearing on spawn
            // pins the delay at its first step and the crash-loop threshold is
            // never reached. Only a run that lasted clears it — see `recordExit`.
            logger.info(
                "Started the host resolver",
                metadata: ["pid": .stringConvertible(handle.processIdentifier)])
        } catch {
            state.consecutiveFailures += 1
            state.nextStartAllowedAt = now().addingTimeInterval(
                delaySeconds(state.consecutiveFailures))
            if let deadline = state.nextStartAllowedAt { scheduleRestart(at: deadline) }
            log(failure: error.localizedDescription)
        }
    }

    /// Records the child's exit, so this reconciliation can schedule its retry.
    ///
    /// **The failure counter is cleared by a run, never by a spawn.** The
    /// failures this backoff exists for — a Corefile CoreDNS refuses to parse,
    /// an address it cannot bind — `fork` perfectly well and exit a moment
    /// later, so resetting on a successful spawn would pin the delay at its
    /// first step and `crashLoopThreshold` would never be reached. Judging the
    /// exit by how long the child survived is what makes the escalation
    /// reachable, and it still forgives the ordinary case.
    private func recordExit() {
        guard state.handle?.isRunning == false else { return }
        let exitedAt = state.handle?.exitedAt ?? now()
        let ranFor = state.startedAt.map { exitedAt.timeIntervalSince($0) } ?? 0
        state.handle = nil
        state.startedAt = nil
        if ResolverSupervisionPolicy.runProvedHealthy(ranForSeconds: ranFor) {
            state.consecutiveFailures = 0
        }
        state.consecutiveFailures += 1
        state.nextStartAllowedAt = now().addingTimeInterval(delaySeconds(state.consecutiveFailures))
        log(failure: "exited after \(Int(ranFor))s")
    }

    private func stop() async {
        cancelScheduledRestart()
        // The pid this call is stopping, captured before the suspension below.
        // `terminate` sleeps through its SIGTERM→SIGKILL grace, and a reconcile
        // can interleave in that window: if it re-desires the resolver it will
        // see the entry as not running and start a fresh CoreDNS, whose handle
        // this call would then discard along with its config directory — leaving
        // an unsupervised process bound to every network's address that nothing
        // can ever find again.
        let stopping = state.handle?.processIdentifier ?? state.adoptedPID
        guard stopping != nil else { return }
        if let handle = state.handle {
            await handle.terminate()
        } else if let pid = state.adoptedPID, host.isAlive(pid: pid) {
            await host.terminate(pid: pid)
        }
        let current = state.handle?.processIdentifier ?? state.adoptedPID
        guard current == stopping else { return }
        state = ResolverState()
        host.removeConfiguration(root: root)
        logger.info("Stopped the host resolver")
    }

    // MARK: - Restart scheduling

    /// Own exactly one wakeup for the current backoff deadline.
    private func scheduleRestart(at deadline: Date) {
        if scheduledRestart?.deadline == deadline { return }
        cancelScheduledRestart()
        let cancel = restartScheduler.schedule(at: deadline) { [weak self] in
            await self?.restartIfNeeded(at: deadline)
        }
        scheduledRestart = (deadline, cancel)
    }

    /// Re-check desired and observed state when the backoff expires. Both may
    /// have changed while this task slept, so the deadline is a generation
    /// token and the supervision policy remains the authority for whether a
    /// start is still wanted.
    private func restartIfNeeded(at deadline: Date) {
        guard scheduledRestart?.deadline == deadline,
            state.nextStartAllowedAt == deadline
        else { return }
        scheduledRestart = nil

        // A scheduler returning early must not bypass the backoff. The
        // production scheduler does not, but this keeps the invariant local.
        if deadline > now() {
            scheduleRestart(at: deadline)
            return
        }
        guard let desired = state.rendering,
            ResolverSupervisionPolicy.actions(
                desired: desired, observed: observedState()
            ).contains(.start)
        else { return }
        start(desired)
    }

    private func cancelScheduledRestart() {
        scheduledRestart?.cancel()
        scheduledRestart = nil
    }

    // MARK: - Restart adoption

    /// Rebuilds state from disk on the first pass after an agent restart.
    ///
    /// A CoreDNS started by a previous agent process is still serving every
    /// network on this host, and killing it to start an identical one would cost
    /// all of them their resolver for the length of a process start — for
    /// nothing. So a recorded pid that is still alive is *adopted*: left
    /// running, and its configuration rewritten in place if desired state moved.
    ///
    /// Adoption is deliberately weak. The agent cannot re-parent a process it
    /// did not fork, so it holds no handle for an adopted child and cannot
    /// observe its exit; what it records instead is "something is serving",
    /// which the next reconcile re-checks.
    private func adoptFromDisk() {
        guard let candidate = host.adoptable(root: root) else { return }
        // No digest recorded: the adopted process's configuration is whatever
        // the previous agent wrote, and the first reconcile should rewrite it
        // rather than assume it still matches desired state. The rewrite costs
        // no restart — the Corefile's `reload` and the `file` plugin's watch are
        // what the adopted process picks it up with.
        state = ResolverState(handle: nil, adoptedPID: candidate.pid, configurationDigest: nil)
        logger.info(
            "Adopted a running host resolver", metadata: ["pid": .stringConvertible(candidate.pid)])
    }

    // MARK: - Helpers

    private nonisolated func delaySeconds(_ failures: Int) -> TimeInterval {
        let delay = ResolverSupervisionPolicy.restartDelay(consecutiveFailures: failures)
        return TimeInterval(delay.components.seconds)
    }

    private func log(failure: String) {
        let metadata: Logger.Metadata = [
            "failures": .stringConvertible(state.consecutiveFailures),
            "detail": .string(failure),
        ]
        // Below the threshold this is what a restart during a zone edit looks
        // like; above it, something is wrong that a retry will not fix — and it
        // is every network on this host, not one.
        if ResolverSupervisionPolicy.isCrashLooping(consecutiveFailures: state.consecutiveFailures) {
            logger.error("The host resolver is crash-looping", metadata: metadata)
        } else {
            logger.warning("The host resolver exited; will restart", metadata: metadata)
        }
    }
}
