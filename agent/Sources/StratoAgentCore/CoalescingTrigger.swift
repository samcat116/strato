import Logging

/// Runs an action in response to bursts of signals, at most once per interval
/// and never twice at the same time (STR-135).
///
/// Written for one caller — the agent turning hypervisor lifecycle events into
/// observed-state reports — and its three properties are all load-bearing for
/// that caller rather than general good manners:
///
/// - **Two runs are never in flight at once.** `sendObservedStateReport` stamps
///   an epoch when it starts assembling and re-checks it immediately before
///   sending, so an overlapping report finds itself superseded and drops. Fire
///   faster than a report completes without serializing and the result is a
///   stream of reports of which *none* transmits. Serializing here is what
///   keeps that epoch a supersession guard rather than a starvation bug.
/// - **`signal()` never awaits the action.** Its caller is a pump draining a
///   bounded, drop-oldest event stream; blocking it turns back pressure into
///   silent event loss. A cheap signal keeps the loss where it was designed to
///   be — in the hypervisor's own buffer, where the periodic sync covers it.
/// - **The first signal after a quiet period runs immediately.** Leading edge,
///   so the common case (one guest changed) pays no added latency at all; the
///   interval only bites during a burst.
///
/// Worst case is two runs per interval — one leading, one trailing for whatever
/// arrived while the leading run was in flight — and the steady state under
/// continuous signalling is one per interval.
///
/// The clock is injected as a concrete `ContinuousClock` rather than an
/// `any Clock`, matching `DesiredStatePoller`: the tests run in real time with a
/// short interval, which is the repo's existing bargain.
public actor CoalescingTrigger {
    public typealias Action = @Sendable () async -> Void

    /// The window the agent coalesces lifecycle events into.
    ///
    /// A report is O(VMs) sequential status round trips plus a full domain-list
    /// sweep for the host's resources, and a host-wide power cycle emits
    /// stopped → started → resumed *per VM*, so mapping events to reports 1:1
    /// is quadratic in the fleet size. 500 ms caps the event-driven rate at two
    /// reports a second on the worst host while staying well inside the "within
    /// a second or two" this exists to deliver.
    public static let observedStateInterval: Duration = .milliseconds(500)

    private let interval: Duration
    private let logger: Logger
    private let clock: ContinuousClock
    private let action: Action

    /// A signal has arrived that no run has answered yet.
    private var pending = false
    /// An action is executing right now.
    private var running = false
    /// The armed run — sleeping out the interval, or executing the action.
    /// Held for the whole of both so `stop()` can wait for it.
    private var timer: Task<Void, Never>?
    private var lastRunEnded: ContinuousClock.Instant?
    private var stopped = false

    /// Counters for tests and for diagnostics.
    public private(set) var runCount = 0
    public private(set) var coalescedSignals = 0

    public init(
        interval: Duration,
        logger: Logger,
        clock: ContinuousClock = ContinuousClock(),
        action: @escaping Action
    ) {
        self.interval = interval
        self.logger = logger
        self.clock = clock
        self.action = action
    }

    /// Ask for a run. Returns without executing the action, always.
    public func signal() {
        guard !stopped else { return }
        if pending || running { coalescedSignals += 1 }
        pending = true
        schedule()
    }

    /// Stop, dropping anything pending and waiting out a run already executing
    /// so a caller tearing the agent down doesn't leave one behind.
    public func stop() async {
        stopped = true
        pending = false
        guard let timer else { return }
        self.timer = nil
        timer.cancel()
        await timer.value
    }

    /// Arm the next run, if one is wanted and none is already armed.
    private func schedule() {
        guard !stopped, pending, !running, timer == nil else { return }

        // Zero on the first signal after a quiet period — the leading edge.
        let delay: Duration
        if let lastRunEnded {
            let elapsed = clock.now - lastRunEnded
            delay = elapsed >= interval ? .zero : interval - elapsed
        } else {
            delay = .zero
        }

        timer = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await self?.run()
        }
    }

    private func run() async {
        guard !stopped, pending else {
            timer = nil
            return
        }
        pending = false
        running = true
        await action()
        running = false
        runCount += 1
        lastRunEnded = clock.now
        logger.trace(
            "Coalesced trigger ran",
            metadata: [
                "runs": .stringConvertible(runCount),
                "coalesced": .stringConvertible(coalescedSignals),
            ])
        // Cleared last, so a signal arriving while the action ran finds the
        // trigger armed rather than racing a second run into it.
        timer = nil
        schedule()
    }
}
