import Foundation
import NIOConcurrencyHelpers
import NIOCore

/// Byte-bounded FIFO storage for authenticated agent WebSocket frames.
/// The active frame is not retained here; at most one frame is active because
/// `AgentWebSocketFrameProcessor` has exactly one consumer task.
struct BoundedAgentFrameBuffer {
    private struct Frame {
        let text: String
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

    mutating func append(_ text: String) -> Bool {
        let byteCount = text.utf8.count
        guard byteCount <= byteLimit - bufferedBytes else { return false }
        frames.append(Frame(text: text, byteCount: byteCount))
        bufferedBytes += byteCount
        return true
    }

    mutating func popFirst() -> String? {
        guard let frame = frames.popFirst() else { return nil }
        bufferedBytes -= frame.byteCount
        return frame.text
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
    private let handler: @Sendable (String) async -> Void
    private var buffer: BoundedAgentFrameBuffer
    private var drainTask: Task<Void, Never>?
    private var acceptingFrames = true

    init(
        bufferLimitBytes: Int = AgentWebSocketFrameProcessor.defaultBufferLimitBytes,
        handler: @escaping @Sendable (String) async -> Void
    ) {
        self.buffer = BoundedAgentFrameBuffer(byteLimit: bufferLimitBytes)
        self.handler = handler
    }

    func enqueue(_ text: String) -> EnqueueResult {
        lock.withLock {
            guard acceptingFrames else { return .closed }
            guard buffer.append(text) else {
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

    private func run() async {
        while let text = nextFrame() {
            await handler(text)
        }
    }

    private func nextFrame() -> String? {
        lock.withLock {
            guard let text = buffer.popFirst() else {
                drainTask = nil
                return nil
            }
            return text
        }
    }
}
