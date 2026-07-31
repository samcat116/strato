import Foundation

/// A single-consumer, order-preserving hand-off from a NIO channel's event loop
/// to an `async` sink.
///
/// The console bridge used to spawn a detached `Task` per socket read and await
/// the sink inside it. Detached tasks are scheduled independently, so two reads
/// could reach the sink transposed — and once the sink suspends (sending a
/// WebSocket frame does), a third could interleave between them. For a text
/// console that shows up as rare scrambled output. For a byte stream with a
/// handshake and length-prefixed messages — RFB — it is fatal: the client reads
/// a framebuffer rectangle where it expects a message header and never
/// recovers.
///
/// This is the discipline the sandbox exec path already uses (see
/// `SandboxExecWebSocketController`'s pump): producers `yield` synchronously,
/// preserving arrival order, and exactly one consumer task drains the stream,
/// so the sink is entered once at a time and in order.
public final class OrderedByteRelay: @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation

    /// The task draining the stream. Held so the owner can cancel it, and so
    /// the relay's lifetime is explicit rather than implicit in a detached task.
    private let pump: Task<Void, Never>

    /// Starts a relay that feeds every chunk to `sink`, in order.
    ///
    /// The buffer is unbounded on purpose: dropping a chunk mid-stream corrupts
    /// the byte stream just as reordering would, so there is nothing safer to
    /// do under pressure than queue. RFB is request-driven — QEMU sends no
    /// framebuffer update until the client asks for the next one — so a slow
    /// consumer throttles the producer at the protocol level rather than
    /// growing this queue without bound.
    public init(sink: @escaping @Sendable (Data) async -> Void) {
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        self.pump = Task {
            for await chunk in stream {
                await sink(chunk)
            }
        }
    }

    /// Enqueues a chunk. Synchronous and non-suspending, so it is safe to call
    /// from a channel handler on its event loop — and so arrival order *is*
    /// enqueue order.
    public func send(_ data: Data) {
        continuation.yield(data)
    }

    /// Stops accepting chunks and lets the pump finish the ones already queued.
    public func finish() {
        continuation.finish()
    }

    /// Stops the pump without draining. For teardown where the peer is already
    /// gone and the remaining bytes have nowhere to go.
    public func cancel() {
        continuation.finish()
        pump.cancel()
    }
}
