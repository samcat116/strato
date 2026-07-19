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
/// Cancellation of a waiter does not cancel the shared operation, since other waiters may
/// still need its result.
public actor SingleFlight<Value: Sendable> {
    /// The in-flight operation per key, tagged with an id so a finishing operation only
    /// retires its own entry and never a successor that has since taken the slot.
    private var inFlight: [String: (id: UInt64, task: Task<Value, any Error>)] = [:]
    private var nextID: UInt64 = 0

    public init() {}

    /// Runs `operation` for `key`, or joins the execution already in flight for that key.
    /// Both the value and any thrown error are shared by every caller in the same flight.
    public func run(key: String, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        if let existing = inFlight[key] {
            return try await existing.task.value
        }

        nextID += 1
        let id = nextID
        // Retire inside the task, before it resolves, so the entry is gone by the time any
        // waiter observes the outcome. A caller that arrives after this flight ends therefore
        // starts a fresh one rather than inheriting a stale failure.
        let task = Task<Value, any Error> {
            do {
                let value = try await operation()
                await self.retire(key: key, id: id)
                return value
            } catch {
                await self.retire(key: key, id: id)
                throw error
            }
        }
        inFlight[key] = (id: id, task: task)
        return try await task.value
    }

    /// Number of keys currently in flight. Exposed for tests.
    public var inFlightCount: Int { inFlight.count }

    private func retire(key: String, id: UInt64) {
        if inFlight[key]?.id == id {
            inFlight.removeValue(forKey: key)
        }
    }
}
