import Foundation
import Synchronization

/// Preserves console byte order while bounding queued and in-flight output.
/// The owner closes the session when `send` refuses a chunk; dropping bytes
/// and continuing would corrupt the console protocol.
public final class OrderedByteRelay: Sendable {
    public static let defaultByteLimit = 4 * 1024 * 1024
    private struct State {
        var accepting = true
        var bytes = 0
        var chunks = 0
    }
    private final class Accounting: Sendable {
        let state = Mutex(State())
    }
    private let accounting = Accounting()
    private let continuation: AsyncStream<Data>.Continuation
    private let pump: Task<Void, Never>
    private let byteLimit: Int
    private let chunkLimit: Int

    public init(
        byteLimit: Int = OrderedByteRelay.defaultByteLimit,
        chunkLimit: Int = 1024,
        sink: @escaping @Sendable (Data) async -> Void
    ) {
        precondition(byteLimit > 0 && chunkLimit > 0)
        self.byteLimit = byteLimit
        self.chunkLimit = chunkLimit
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.continuation = continuation
        // Capture only the accounting box, not the relay that owns the pump.
        let accounting = self.accounting
        self.pump = Task {
            for await chunk in stream {
                guard !Task.isCancelled else { break }
                await sink(chunk)
                accounting.state.withLock {
                    $0.bytes -= chunk.count
                    $0.chunks -= 1
                }
            }
        }
    }

    /// False means this session must close. The budget includes the chunk
    /// currently awaiting the sink and bounds tiny chunks as well as large ones.
    @discardableResult
    public func send(_ data: Data) -> Bool {
        let result = accounting.state.withLock { state in
            guard state.accepting else { return (accepted: false, overflow: false) }
            guard !data.isEmpty else { return (accepted: true, overflow: false) }
            guard data.count <= byteLimit - state.bytes, state.chunks < chunkLimit else {
                state.accepting = false
                return (accepted: false, overflow: true)
            }
            state.bytes += data.count
            state.chunks += 1
            continuation.yield(data)
            return (accepted: true, overflow: false)
        }
        if result.overflow { cancel() }
        return result.accepted
    }

    /// Stop accepting chunks and drain those already accepted.
    public func finish() {
        accounting.state.withLock { $0.accepting = false }
        continuation.finish()
    }

    /// Close immediately when the peer is gone or its output budget is exceeded.
    public func cancel() {
        finish()
        pump.cancel()
    }
}
