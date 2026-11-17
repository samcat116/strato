import Foundation
import NIOConcurrencyHelpers
import NIOCore

/// Byte-bounded FIFO storage for authenticated agent WebSocket frames.
/// The active frame is not retained here; at most one frame is active because
/// `AgentWebSocketFrameProcessor` has exactly one consumer task.
struct BoundedAgentFrameBuffer {
    private struct Frame {
        let data: Data
        let byteCount: Int
    }

    let byteLimit: Int
    private var frames = CircularBuffer<Frame>(initialCapacity: 16)
    private(set) var bufferedBytes = 0

    var count: Int { frames.count }

    init(byteLimit: Int) {
        precondition(byteLimit > 0)
        self.byteLimit = byteLimit
    }

    mutating func append(_ data: Data) -> Bool {
        let byteCount = data.count
        guard byteCount <= byteLimit - bufferedBytes else { return false }
        frames.append(Frame(data: data, byteCount: byteCount))
        bufferedBytes += byteCount
        return true
    }

    mutating func popFirst() -> Data? {
        guard let frame = frames.popFirst() else { return nil }
        bufferedBytes -= frame.byteCount
        return frame.data
    }
}

/// Serializes authenticated agent frames without allocating one waiting task
/// per frame. Enqueue is synchronous for NIO callbacks; one task drains the
/// bounded FIFO and awaits the async frame handler in wire order.
final class AgentWebSocketFrameProcessor: @unchecked Sendable {
    enum EnqueueResult: Equatable {
        case accepted
        case overflow
        case closed
    }

    static let defaultBufferLimitBytes = 1 << 25

    private let lock = NIOLock()
    private let handler: @Sendable (Data) async -> Void
    private var buffer: BoundedAgentFrameBuffer
    private var drainTask: Task<Void, Never>?
    private var acceptingFrames = true

    init(
        bufferLimitBytes: Int = AgentWebSocketFrameProcessor.defaultBufferLimitBytes,
        handler: @escaping @Sendable (Data) async -> Void
    ) {
        self.buffer = BoundedAgentFrameBuffer(byteLimit: bufferLimitBytes)
        self.handler = handler
    }

    func enqueue(_ data: Data) -> EnqueueResult {
        lock.withLock {
            guard acceptingFrames else { return .closed }
            guard buffer.append(data) else {
                acceptingFrames = false
                return .overflow
            }
            if drainTask == nil {
                drainTask = Task { [weak self] in
                    await self?.run()
                }
            }
            return .accepted
        }
    }

    /// Stop accepting frames and wait until every frame accepted before this
    /// call has completed its handler.
    func finishAndDrain() async {
        let task = lock.withLock {
            acceptingFrames = false
            return drainTask
        }
        await task?.value
    }

    /// Revocation drops queued frames. Wait for the already-running handler
    /// before clearing claims, so it cannot publish presence after teardown.
    func stopAndDiscard() -> Task<Void, Never>? {
        lock.withLock {
            acceptingFrames = false
            buffer = BoundedAgentFrameBuffer(byteLimit: buffer.byteLimit)
            return drainTask
        }
    }

    private func run() async {
        while let data = nextFrame() {
            await handler(data)
        }
    }

    private func nextFrame() -> Data? {
        lock.withLock {
            guard let data = buffer.popFirst() else {
                drainTask = nil
                return nil
            }
            return data
        }
    }
}
