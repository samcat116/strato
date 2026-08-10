import Logging

/// Runs an action in response to bursts of signals, at most once per interval
/// and never twice at the same time (STR-135).
///
/// Written for one caller — the agent turning hypervisor lifecycle events into
/// observed-state reports — and its three properties are all load-bearing for
/// that caller rather than general good manners:
///
/// - **Two *trigger-initiated* runs are never in flight at once.** Scoped
///   deliberately: `sendObservedStateReport` has other callers, and
///   `Agent.convergenceDidChange()` is one of them — the reconciler calls it
///   directly, unserialized, once per convergence transition. So this actor
///   cannot promise that two reports never assemble at once, and nothing may
///   be built on the assumption that it does; the epoch check on those other
///   paths is load-bearing and must stay. What it does promise is that the
///   *event-driven* runs, which a guest can drive at will, do not pile up on
///   their own. That matters because `sendObservedStateReport` stamps an epoch
///   when it starts assembling and re-checks it before sending: firing faster
///   than a report completes yields a stream of reports of which none
///   transmits, and newest-wins supersession only helps if something eventually
///   finishes.
/// - **`signal()` never awaits the action.** Its caller is a pump draining a
///   bounded, drop-oldest event stream; blocking it turns back pressure into
///   silent event loss. A cheap signal keeps the loss where it was designed to
///   be — in the hypervisor's own buffer, where the next full desired-state
///   payload covers it.
/// - **The first signal after a quiet period runs immediately.** Leading edge,
///   so the common case (one guest changed) pays no added latency at all; the
///   interval only bites during a burst.
///
/// The rate bound is one run per *(action duration + interval)*, not one per
/// interval: the next run is scheduled from when the last one **ended**, so a
/// slow action spaces runs out further rather than letting them stack. Under
/// continuous signalling that is the steady state; a burst against an idle
/// trigger costs at most two runs — one leading, one trailing for whatever
/// arrived while the leading run was still in flight.
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
    /// is quadratic in the fleet size.
    ///
    /// 500 ms is the *idle-host* spacing — small enough to stay well inside the
    /// "within a second or two" this exists to deliver. It is not the bound on
    /// a loaded one, and reading it as "at most two reports a second" gets the
    /// worst host backwards: because runs are spaced from when the last ended,
    /// a host where a report takes three seconds settles at roughly one report
    /// per three and a half, not two per second. The interval adds to the
    /// report's own cost rather than competing with it, which is the safe
    /// direction and the reason a single number can be used here at all.
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
