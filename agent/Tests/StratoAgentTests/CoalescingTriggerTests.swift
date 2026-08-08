import Foundation
import Logging
import Testing

@testable import StratoAgentCore

/// The coalescing between a hypervisor's lifecycle events and the agent's
/// observed-state reports (STR-135). The supervisor that produces those events
/// needs a live libvirtd and so has no unit tests; this — the part that decides
/// how many reports a burst becomes, and that two never overlap — does not.
@Suite("Coalescing trigger")
struct CoalescingTriggerTests {

    /// Records when the action ran and how many were running at once.
    private actor Recorder {
        private(set) var starts = 0
        private(set) var runs = 0
        private(set) var concurrent = 0
        private(set) var peakConcurrent = 0
        private let delay: Duration

        init(delay: Duration = .zero) {
            self.delay = delay
        }

        func run() async {
            starts += 1
            concurrent += 1
            peakConcurrent = max(peakConcurrent, concurrent)
            if delay > .zero { try? await Task.sleep(for: delay) }
            concurrent -= 1
            runs += 1
        }

        /// Polls until `runs` reaches `count`, in the shape of
        /// `MockActuator.waitForReports`.
        func waitForRuns(_ count: Int, timeoutMillis: Int = 5000) async -> Bool {
            for _ in 0..<(timeoutMillis / 5) {
                if runs >= count { return true }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return runs >= count
        }

        /// Polls until the action has *entered* `count` times — the hook that
        /// lets a test signal while a run is provably still in flight, rather
        /// than guessing at it with a sleep.
        func waitForStarts(_ count: Int, timeoutMillis: Int = 5000) async -> Bool {
            for _ in 0..<(timeoutMillis / 5) {
                if starts >= count { return true }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return starts >= count
        }
    }

    private static let interval: Duration = .milliseconds(50)

    private func makeTrigger(_ recorder: Recorder) -> CoalescingTrigger {
        CoalescingTrigger(interval: Self.interval, logger: Logger(label: "test")) {
            await recorder.run()
        }
    }

    /// The leading edge: the common case is one guest changing, and it must not
    /// pay the coalescing window as latency.
    @Test("A single signal runs promptly")
    func singleSignalRunsImmediately() async {
        let recorder = Recorder()
        let trigger = makeTrigger(recorder)

        await trigger.signal()
        #expect(await recorder.waitForRuns(1))
        // And nothing schedules a second run from one signal.
        try? await Task.sleep(for: Self.interval * 3)
        #expect(await recorder.runs == 1)
        await trigger.stop()
    }

    /// The property the whole design exists for: a host-wide power cycle emits
    /// a transition per VM, and a report is a full re-reading that answers every
    /// request preceding it, so fifty signals must never become fifty reports.
    ///
    /// One or two, not exactly one: whether the leading run wins the actor
    /// after the burst has landed or partway through it is a scheduling detail,
    /// and pinning it would be a timing assertion dressed up as a behavioural
    /// one. `coalescedSignals` is the deterministic half — every signal after
    /// the first found a run pending or in flight.
    @Test("A burst collapses instead of becoming one run per signal")
    func burstCollapses() async {
        let recorder = Recorder()
        let trigger = makeTrigger(recorder)

        for _ in 0..<50 { await trigger.signal() }

        #expect(await recorder.waitForRuns(1))
        try? await Task.sleep(for: Self.interval * 4)
        let runs = await recorder.runs
        #expect(runs <= 2, "50 signals became \(runs) runs")
        #expect(await trigger.runCount == runs)
        #expect(await trigger.coalescedSignals == 49)
        await trigger.stop()
    }

    /// The other half: signals that arrive too late to join the leading run
    /// cannot be dropped — they may describe a transition it did not see — so
    /// they get exactly one trailing run. Two per interval is the worst case
    /// the design admits, and this pins the "one, not one each".
    ///
    /// Deterministic by construction rather than by timing: the run is held
    /// open for well longer than the burst takes to issue, and the burst does
    /// not start until the action has provably entered.
    @Test("Signals arriving during a run earn exactly one trailing run")
    func signalsDuringARunEarnOneTrailingRun() async {
        let recorder = Recorder(delay: .milliseconds(300))
        let trigger = makeTrigger(recorder)

        await trigger.signal()
        #expect(await recorder.waitForStarts(1))
        for _ in 0..<20 { await trigger.signal() }

        #expect(await recorder.waitForRuns(2))
        try? await Task.sleep(for: .milliseconds(500))
        #expect(await recorder.runs == 2)
        // All twenty found a run in flight or one already pending behind it.
        #expect(await trigger.coalescedSignals == 20)
        await trigger.stop()
    }

    @Test("Signals spaced wider than the interval each run")
    func spacedSignalsAreNotCoalesced() async {
        let recorder = Recorder()
        let trigger = makeTrigger(recorder)

        for i in 1...3 {
            await trigger.signal()
            // Waited out rather than slept past, so a loaded machine cannot
            // turn "spaced apart" into "overlapping" and make this a timing
            // assertion.
            #expect(await recorder.waitForRuns(i))
            try? await Task.sleep(for: Self.interval * 2)
        }
        #expect(await recorder.runs == 3)
        #expect(await trigger.coalescedSignals == 0)
        await trigger.stop()
    }

    /// The property `sendObservedStateReport`'s epoch guard depends on: two
    /// reports in flight means the older one discards itself, so a trigger that
    /// overlapped runs could produce reports none of which ever transmits.
    @Test("Runs never overlap, however hard the trigger is signalled")
    func runsNeverOverlap() async {
        let recorder = Recorder(delay: .milliseconds(40))
        let trigger = makeTrigger(recorder)

        for _ in 0..<200 {
            await trigger.signal()
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(await recorder.waitForRuns(2))
        #expect(await recorder.peakConcurrent == 1)
        await trigger.stop()
    }

    @Test("stop() drops a pending run and makes later signals inert")
    func stopDropsPendingWork() async {
        let recorder = Recorder(delay: .milliseconds(40))
        let trigger = makeTrigger(recorder)

        await trigger.signal()
        #expect(await recorder.waitForRuns(1))
        // Arrives inside the window that follows the run just completed, so it
        // is armed-but-not-yet-fired — the pending run stop() has to drop.
        await trigger.signal()
        await trigger.stop()

        let after = await recorder.runs
        try? await Task.sleep(for: Self.interval * 4)
        #expect(await recorder.runs == after)

        await trigger.signal()
        try? await Task.sleep(for: Self.interval * 4)
        #expect(await recorder.runs == after)
    }
}
