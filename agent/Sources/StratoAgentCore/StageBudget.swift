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
    /// not complete within `seconds`. The operation task is cancelled on
    /// timeout (best effort — stages that ignore cancellation still stop
    /// blocking the caller).
    public static func run<T: Sendable>(
        seconds: Int,
        stage: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw StageBudgetError.exceeded(stage: stage, seconds: seconds)
            }
            guard let result = try await group.next() else {
                throw StageBudgetError.exceeded(stage: stage, seconds: seconds)
            }
            group.cancelAll()
            return result
        }
    }
}
