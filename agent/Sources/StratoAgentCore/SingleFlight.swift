import Foundation

/// Coalesces concurrent asynchronous work by key: callers arriving for a key that already
/// has work in flight await that same operation instead of starting a redundant one.
///
/// This is the complement to `SerialTaskQueue`. That primitive orders work that must all
/// happen, one item after another; this one collapses work that only needs to happen once,
/// so N concurrent callers see one execution and N copies of its result. Image downloads are
/// the motivating case: two workloads placed on the same agent against the same not-yet-cached
/// image would otherwise each check the cache, each see a miss, and each download to the same
/// destination — with the loser of the publish race failing an otherwise healthy create.
///
/// The key is retired as soon as the operation finishes, so this is strictly a dedup window
/// around in-flight work and never a cache: a later caller re-runs the operation (and, for the
/// image cache, sees the now-populated cache on its own check).
///
/// **Cancellation.** A cancelled waiter stops waiting and throws `CancellationError`; it does
/// not cancel the shared operation, which the remaining waiters still need. Waiters must be
/// individually cancellable because callers wrap this in deadlines — `StageBudget.run` enforces
/// its budget by cancelling the operation task, and a waiter that ignored that would sit past
/// its budget waiting on someone else's download. The operation runs to completion even if
/// every waiter leaves, since a finished download still populates the cache for the next
/// caller.
public actor SingleFlight<Value: Sendable> {
    /// One in-flight execution and the callers parked on its result.
    private struct Flight {
        /// Distinguishes this execution from a successor that later takes the same key.
        let id: UInt64
        var waiters: [UInt64: CheckedContinuation<Value, any Error>] = [:]
    }

    /// Raised when the flight a caller meant to join finished before it could park on the
    /// result. The caller runs its own flight instead; never surfaced to callers.
    private struct FlightVanished: Error {}

    private var flights: [String: Flight] = [:]
    private var nextID: UInt64 = 0

    public init() {}

    /// Runs `operation` for `key`, or joins the execution already in flight for that key.
    /// Both the value and any thrown error are shared by every caller in the same flight.
    public func run(key: String, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        while true {
            let waiterID = allocateID()
            if flights[key] == nil {
                start(key: key, operation: operation)
            }
            do {
                return try await park(key: key, waiterID: waiterID)
            } catch is FlightVanished {
                continue  // it finished while we were parking; start our own
            }
        }
    }

    /// Number of keys currently in flight. Exposed for tests.
    public var inFlightCount: Int { flights.count }

    private func allocateID() -> UInt64 {
        nextID += 1
        return nextID
    }

    /// Begins an execution for `key`, resuming every parked waiter when it settles.
    private func start(key: String, operation: @escaping @Sendable () async throws -> Value) {
        let flightID = allocateID()
        flights[key] = Flight(id: flightID)
        Task {
            let result: Result<Value, any Error>
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
            self.finish(key: key, flightID: flightID, result: result)
        }
    }

    /// Suspends until this key's flight settles, or until the calling task is cancelled.
    private func park(key: String, waiterID: UInt64) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard flights[key] != nil else {
                    continuation.resume(throwing: FlightVanished())
                    return
                }
                // Cancelled before parking: the handler below already ran and found no
                // continuation to resume, so check here or this waiter never wakes.
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                flights[key]?.waiters[waiterID] = continuation
            }
        } onCancel: {
            Task { await self.abandon(key: key, waiterID: waiterID) }
        }
    }

    /// Hands `result` to every waiter and retires the key, guarding against retiring a
    /// successor flight that has since taken the slot.
    private func finish(key: String, flightID: UInt64, result: Result<Value, any Error>) {
        guard let flight = flights[key], flight.id == flightID else { return }
        flights.removeValue(forKey: key)
        for continuation in flight.waiters.values {
            continuation.resume(with: result)
        }
    }

    /// Drops one cancelled waiter, leaving the flight running for the others.
    private func abandon(key: String, waiterID: UInt64) {
        guard let continuation = flights[key]?.waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(throwing: CancellationError())
    }
}
