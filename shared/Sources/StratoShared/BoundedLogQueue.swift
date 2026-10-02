import Foundation

/// Lossy workload telemetry, deliberately separate from console/session flow
/// control. One serial consumer drains this FIFO; producers never await it.
/// Both bytes and entry count are bounded, including a per-entry allowance for
/// object/queue overhead. Oversize entries are rejected; pressure evicts oldest.
// NSLock keeps StratoShared's macOS 14 minimum; Synchronization.Mutex requires
// macOS 15. All mutable state is accessed exclusively through withState.
public final class BoundedLogQueue<Element: Sendable>: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public let count: Int
        public let bytes: Int
        public let dropped: Int
    }

    public enum DropReason: String, Sendable {
        case overflow
        case deliveryFailure = "delivery_failure"
        case shutdown
        case backendUnavailable = "backend_unavailable"
    }

    private struct Stored: Sendable {
        let element: Element
        let bytes: Int
    }

    private struct State: Sendable {
        var slots: [Stored?]
        var head = 0
        var count = 0
        var bytes = 0
        var dropped = 0
        var accepting = true

        mutating func pop() -> Stored? {
            guard count > 0 else { return nil }
            let entry = slots[head]!
            slots[head] = nil
            head = (head + 1) % slots.count
            count -= 1
            bytes -= entry.bytes
            return entry
        }

        var snapshot: Snapshot { Snapshot(count: count, bytes: bytes, dropped: dropped) }
    }

    public static var defaultByteLimit: Int { 4 * 1024 * 1024 }
    public let byteLimit: Int
    private let lock = NSLock()
    private var state: State
    /// Only wakeups live in AsyncStream, never log payloads. A stalled consumer
    /// retains at most one wakeup plus its explicitly limited active batch.
    public let notifications: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    // Runs under the lock to keep gauge updates ordered; must not reenter queue.
    private let onChange: @Sendable (Snapshot, Int, DropReason) -> Void

    public init(
        byteLimit: Int = BoundedLogQueue.defaultByteLimit,
        countLimit: Int = 4096,
        onChange: @escaping @Sendable (Snapshot, Int, DropReason) -> Void = { _, _, _ in }
    ) {
        precondition(byteLimit > 128 && countLimit > 0)
        self.byteLimit = byteLimit
        self.state = State(slots: Array(repeating: nil, count: countLimit))
        self.onChange = onChange
        (notifications, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    private func withState<Result>(_ body: (inout State) -> Result) -> Result {
        lock.withLock { body(&state) }
    }

    public var snapshot: Snapshot { withState { $0.snapshot } }

    @discardableResult
    public func append(_ element: Element, byteCount: Int) -> Bool {
        withState { state in
            guard state.accepting else { return false }
            var drops = 0
            guard byteCount >= 0, byteCount <= byteLimit - 128 else {
                state.dropped += 1
                onChange(state.snapshot, 1, .overflow)
                return false
            }
            let cost = byteCount + 128
            while state.count == state.slots.count || cost > byteLimit - state.bytes {
                _ = state.pop()
                drops += 1
            }
            state.slots[(state.head + state.count) % state.slots.count] = Stored(element: element, bytes: cost)
            state.count += 1
            state.bytes += cost
            state.dropped += drops
            onChange(state.snapshot, drops, .overflow)
            continuation.yield(())
            return true
        }
    }

    /// Limit the active batch as well as the queued backlog. The first entry
    /// can exceed maxBytes, but cannot exceed this queue's byteLimit.
    public func drain(maxCount: Int = 256, maxBytes: Int = 256 * 1024) -> [Element] {
        precondition(maxCount > 0 && maxBytes > 0)
        return withState { state in
            var result: [Element] = []
            var bytes = 0
            while state.count > 0 && result.count < maxCount {
                let next = state.slots[state.head]!
                if !result.isEmpty && next.bytes > maxBytes - bytes { break }
                let entry = state.pop()!
                result.append(entry.element)
                bytes += entry.bytes
            }
            onChange(state.snapshot, 0, .overflow)
            if state.count > 0 { continuation.yield(()) }
            return result
        }
    }

    /// Count an active line lost after leaving the queue (for example a
    /// failed socket send). It uses the same cumulative loss counter.
    public func recordDrop(reason: DropReason) {
        withState { state in
            state.dropped += 1
            onChange(state.snapshot, 1, reason)
        }
    }

    public func discard(reason: DropReason) {
        withState { state in
            let drops = state.count
            while state.pop() != nil {}
            state.dropped += drops
            onChange(state.snapshot, drops, reason)
        }
    }

    /// Shutdown sheds pending telemetry immediately. Cancellation belongs to
    /// the consumer's owner; no producer or continuation is left suspended.
    public func finish() {
        withState { state in
            state.accepting = false
            let drops = state.count
            while state.pop() != nil {}
            state.dropped += drops
            onChange(state.snapshot, drops, .shutdown)
            continuation.finish()
        }
    }

    deinit { continuation.finish() }
}
