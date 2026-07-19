import Foundation

/// Per-stage time budgets for long VM operations (reconciliation phase 2,
/// issue #260). A multi-GB image download and a QMP process spawn have wildly
/// different legitimate durations, so each stage gets its own budget instead
/// of one hard-coded envelope around the whole operation.
public enum StageBudgetError: Error, LocalizedError, Sendable {
    case exceeded(stage: String, seconds: Int)

    public var errorDescription: String? {
        switch self {
        case .exceeded(let stage, let seconds):
            return "Stage \"\(stage)\" exceeded its \(seconds)s budget"
        }
    }
}

public enum StageBudget {
    /// Default budgets per stage of VM creation.
    public static let imageMaterializationSeconds = 1200  // download + qcow2 conversion of multi-GB images
    public static let hypervisorSpawnSeconds = 60  // process launch + QMP handshake
    // A live QMP query answers in milliseconds; a bound here keeps a dead/hung
    // QMP channel (e.g. a re-adopted VM whose control socket went inactive) from
    // blocking the reconcile — and, because status queries share the QEMU
    // service, from wedging every other operation behind them.
    public static let statusQuerySeconds = 10
    // Lifecycle round-trips over the hypervisor's control channel (boot, pause,
    // resume, shutdown, disk hot-plug). Healthy calls answer in milliseconds.
    // The bound matters because these share the hypervisor actor with every
    // other operation, so an unbounded one wedges the whole backend (issue #516).
    public static let hypervisorControlSeconds = 30
    // Re-adopting an orphan: connect to its control socket and read status.
    // The reported hang was here — a connect that succeeded against a socket
    // whose peer never spoke, with nothing to time it out.
    public static let adoptionSeconds = 30
    // How long the agent may go without observing a hypervisor before it stops
    // waiting and reports its last known view instead. Liveness reporting must
    // not be hostage to hypervisor progress.
    public static let observationSeconds = 5

    /// Run `operation`, failing with `StageBudgetError.exceeded` if it does
    /// not complete within `seconds`. The operation is cancelled on timeout
    /// (best effort), and — crucially — stages that ignore cancellation still
    /// stop blocking the caller.
    ///
    /// That last guarantee is why this cannot be a task group. A group awaits
    /// every child before it returns or rethrows, so cancelling a child parked
    /// on a non-cancellation-aware continuation (an unanswered QMP round-trip,
    /// say) leaves the group suspended forever: the budget itself hangs, in
    /// exactly the case it exists to bound (issue #516). The operation
    /// therefore runs in an *unstructured* task, which the caller can walk
    /// away from. A wedged stage leaks that task — unavoidable, since it is
    /// stuck — but the caller is freed on schedule.
    public static func run<T: Sendable>(
        seconds: Int,
        stage: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let outcome = FirstOutcome<T>()

        // Inherits the caller's context (actor, priority, task locals) so the
        // stage behaves as if it ran inline.
        let work = Task {
            do {
                outcome.resolve(.success(try await operation()))
            } catch {
                outcome.resolve(.failure(error))
            }
        }
        // Detached: the deadline must fire even if the caller's executor is
        // the thing that is wedged.
        let deadline = Task.detached {
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            outcome.resolve(.failure(StageBudgetError.exceeded(stage: stage, seconds: seconds)))
        }
        defer {
            work.cancel()
            deadline.cancel()
        }

        return try await withTaskCancellationHandler {
            try await outcome.value()
        } onCancel: {
            outcome.resolve(.failure(CancellationError()))
        }
    }
}

/// A one-shot result slot: the first of the operation, the deadline, or
/// cancellation to resolve it wins, and later resolutions are ignored.
///
/// Registration and resolution share one lock so a deadline that fires before
/// the caller parks cannot slip through the gap — the caller then observes the
/// stored result instead of waiting for a resolution that already happened.
private final class FirstOutcome<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, any Error>?
    private var continuation: CheckedContinuation<T, any Error>?

    func resolve(_ value: Result<T, any Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = value
        let waiter = continuation
        continuation = nil
        lock.unlock()
        waiter?.resume(with: value)
    }

    func value() async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }
}
