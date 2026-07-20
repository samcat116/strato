import Foundation
import Logging
import NIOCore
import NIOPosix

/// A `QGATransport` that opens real Unix-domain-socket channels to a VM's qga
/// port (`<vmStoragePath>/<vmId>/qga.sock`) using SwiftNIO (issue #563).
///
/// Bound to one socket path. Uses the shared global NIO event-loop group, so it
/// owns no lifecycle of its own — matching the fire-and-forget, one-connection-
/// per-probe usage the guest agent's chardev expects.
public struct NIOQGATransport: QGATransport {
    private let socketPath: String
    private let group: EventLoopGroup
    private let logger: Logger

    public init(
        socketPath: String,
        group: EventLoopGroup = NIOSingletons.posixEventLoopGroup,
        logger: Logger
    ) {
        self.socketPath = socketPath
        self.group = group
        self.logger = logger
    }

    public func openChannel() async throws -> any QGAByteChannel {
        let handler = QGAInboundHandler()
        let channel = try await ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }
            .connect(unixDomainSocketPath: socketPath)
            .get()
        return NIOQGAByteChannel(channel: channel, handler: handler)
    }
}

/// Bridges a NIO `Channel` to the `QGAByteChannel` async surface. Inbound bytes
/// are buffered by `QGAInboundHandler` and handed to `readSome()`; EOF and
/// errors surface as an empty read or a throw.
private final class NIOQGAByteChannel: QGAByteChannel, @unchecked Sendable {
    private let channel: Channel
    private let handler: QGAInboundHandler

    init(channel: Channel, handler: QGAInboundHandler) {
        self.channel = channel
        self.handler = handler
    }

    func write(_ bytes: [UInt8]) async throws {
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        try await channel.writeAndFlush(buffer).get()
    }

    func readSome() async throws -> [UInt8] {
        try await handler.readSome()
    }

    func close() async {
        try? await channel.close().get()
    }
}

/// Accumulates inbound bytes off the event loop and satisfies one pending
/// `readSome()` at a time. Cancellation of the awaiting task fails the pending
/// read so a `StageBudget` timeout can unwind a probe against a silent guest.
private final class QGAInboundHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let lock = NSLock()
    private var pending: [UInt8] = []
    private var closed = false
    private var failure: Error?
    private var waiter: CheckedContinuation<[UInt8], Error>?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
        guard !bytes.isEmpty else { return }
        resumeOrBuffer(bytes: bytes)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(with: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(with: error)
        context.close(promise: nil)
    }

    /// Awaits the next inbound chunk. Returns an empty array once the channel is
    /// closed and drained (EOF).
    func readSome() async throws -> [UInt8] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], Error>) in
                lock.lock()
                if !pending.isEmpty {
                    let bytes = pending
                    pending.removeAll(keepingCapacity: true)
                    lock.unlock()
                    continuation.resume(returning: bytes)
                    return
                }
                if let failure {
                    lock.unlock()
                    continuation.resume(throwing: failure)
                    return
                }
                if closed {
                    lock.unlock()
                    continuation.resume(returning: [])  // EOF
                    return
                }
                waiter = continuation
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let continuation = waiter
            waiter = nil
            lock.unlock()
            continuation?.resume(throwing: CancellationError())
        }
    }

    private func resumeOrBuffer(bytes: [UInt8]) {
        lock.lock()
        if let continuation = waiter {
            waiter = nil
            lock.unlock()
            continuation.resume(returning: bytes)
            return
        }
        pending.append(contentsOf: bytes)
        lock.unlock()
    }

    private func finish(with error: Error?) {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        if failure == nil { failure = error }
        let continuation = waiter
        waiter = nil
        // A waiter parked with nothing buffered gets EOF (empty) or the error.
        let bufferedEmpty = pending.isEmpty
        lock.unlock()
        if let continuation {
            if let error {
                continuation.resume(throwing: error)
            } else if bufferedEmpty {
                continuation.resume(returning: [])
            }
            // If bytes are still buffered, the next readSome drains them and a
            // subsequent one observes EOF.
        }
    }
}
