import Foundation
import Logging
import NIOCore
import NIOPosix

/// A newline-framed connection to a guest service. Kept as a protocol so the
/// VM exec bridge can be tested without a kernel VSOCK device.
public protocol GuestLineConnection: Sendable {
    func write(_ data: Data) async throws
    func nextLine(timeout: TimeInterval?) async throws -> String?
    func close() async
}

/// Host-side AF_VSOCK transport for QEMU guests. SwiftNIO owns the descriptor,
/// so a close racing an in-flight read cannot touch a recycled fd.
public actor HostVsockConnection: GuestLineConnection {
    private let channel: Channel
    private let inbound: HostVsockInboundBridge

    private init(channel: Channel, inbound: HostVsockInboundBridge) {
        self.channel = channel
        self.inbound = inbound
    }

    /// Connect to one guest CID/port, retrying boot-time refusal until the
    /// overall timeout expires.
    public static func connect(
        cid: UInt32,
        port: UInt32,
        timeout: TimeInterval = 10,
        retryInterval: TimeInterval = 0.1,
        logger: Logger = Logger(label: "StratoAgent.HostVsock")
    ) async throws -> any GuestLineConnection {
        let deadline = ContinuousClock.now + .seconds(timeout)
        var lastError: Error?

        while ContinuousClock.now < deadline {
            do {
                let bridge = HostVsockInboundBridge()
                let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                    .connectTimeout(.milliseconds(1_000))
                    .channelOption(ChannelOptions.autoRead, value: false)
                    .channelInitializer { channel in
                        do {
                            try channel.pipeline.syncOperations.addHandlers([
                                ByteToMessageHandler(HostVsockLineFrameDecoder()),
                                bridge,
                            ])
                            return channel.eventLoop.makeSucceededVoidFuture()
                        } catch {
                            return channel.eventLoop.makeFailedFuture(error)
                        }
                    }
                let address = VsockAddress(
                    cid: .init(rawValue: cid), port: .init(rawValue: port))
                let channel = try await bootstrap.connect(to: address).get()
                logger.debug(
                    "Connected to VM guest agent over vsock",
                    metadata: ["cid": "\(cid)", "port": "\(port)"])
                return HostVsockConnection(channel: channel, inbound: bridge)
            } catch {
                lastError = error
                try Task.checkCancellation()
                let remaining = deadline - ContinuousClock.now
                guard remaining > .zero else { break }
                try await Task.sleep(for: min(.seconds(retryInterval), remaining))
            }
        }

        throw HostVsockConnectionError.connectTimedOut(
            cid: cid, port: port, detail: lastError?.localizedDescription ?? "no connection attempt completed")
    }

    public func write(_ data: Data) async throws {
        guard channel.isActive else { throw HostVsockConnectionError.notConnected }
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await channel.writeAndFlush(buffer).get()
    }

    public func nextLine(timeout: TimeInterval? = nil) async throws -> String? {
        try await inbound.next(
            on: channel.eventLoop,
            timeout: timeout.map(Self.timeAmount(seconds:))
        ).get()
    }

    public func close() async {
        try? await channel.close().get()
    }

    private nonisolated static func timeAmount(seconds: TimeInterval) -> TimeAmount {
        guard seconds.isFinite, seconds > 0 else { return .milliseconds(0) }
        let milliseconds = seconds * 1_000
        guard milliseconds < Double(Int64.max) else { return .milliseconds(.max) }
        return .milliseconds(Int64(milliseconds))
    }
}

public enum HostVsockConnectionError: Error, LocalizedError, Sendable {
    case connectTimedOut(cid: UInt32, port: UInt32, detail: String)
    case readTimedOut
    case lineTooLong(Int)
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .connectTimedOut(let cid, let port, let detail):
            return "timed out connecting to vsock CID \(cid) port \(port): \(detail)"
        case .readTimedOut:
            return "timed out waiting for a guest vsock response"
        case .lineTooLong(let limit):
            return "guest vsock response exceeded \(limit) bytes without a newline"
        case .notConnected:
            return "guest vsock connection is closed"
        }
    }
}

private struct HostVsockLineFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer
    private let maximumLineLength = GuestControlProtocol.Limits.maxLineBytes

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let newlineIndex = buffer.readableBytesView.firstIndex(of: 0x0A) else {
            if buffer.readableBytes > maximumLineLength {
                throw HostVsockConnectionError.lineTooLong(maximumLineLength)
            }
            return .needMoreData
        }
        let length = newlineIndex - buffer.readableBytesView.startIndex
        let line = buffer.readSlice(length: length)!
        buffer.moveReaderIndex(forwardBy: 1)
        context.fireChannelRead(wrapInboundOut(line))
        return .continue
    }

    func decodeLast(
        context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool
    ) throws -> DecodingState {
        while case .continue = try decode(context: context, buffer: &buffer) {}
        buffer.moveReaderIndex(to: buffer.writerIndex)
        return .needMoreData
    }
}

/// Demand-driven line delivery: a guest cannot grow an unbounded host buffer
/// merely by writing faster than the exec reader consumes.
private final class HostVsockInboundBridge: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private struct Waiter {
        let id: UInt64
        let promise: EventLoopPromise<String?>
        let timeoutTask: Scheduled<Void>?
    }

    private var pending: [String] = []
    private var waiters: [Waiter] = []
    private var nextWaiterID: UInt64 = 0
    private var failure: Error?
    private var closed = false
    private var context: ChannelHandlerContext?

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }
    func handlerRemoved(context: ChannelHandlerContext) { self.context = nil }

    func next(on eventLoop: EventLoop, timeout: TimeAmount?) -> EventLoopFuture<String?> {
        eventLoop.flatSubmit {
            if !self.pending.isEmpty {
                return eventLoop.makeSucceededFuture(self.pending.removeFirst())
            }
            if let failure = self.failure { return eventLoop.makeFailedFuture(failure) }
            if self.closed { return eventLoop.makeSucceededFuture(nil) }

            let id = self.nextWaiterID
            self.nextWaiterID += 1
            let promise = eventLoop.makePromise(of: String?.self)
            let timeoutTask = timeout.map { budget in
                eventLoop.scheduleTask(in: budget) {
                    guard let index = self.waiters.firstIndex(where: { $0.id == id }) else { return }
                    self.waiters.remove(at: index)
                    promise.fail(HostVsockConnectionError.readTimedOut)
                }
            }
            self.waiters.append(Waiter(id: id, promise: promise, timeoutTask: timeoutTask))
            self.context?.read()
            return promise.futureResult
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        let line = String(decoding: buffer.readableBytesView, as: UTF8.self)
        if waiters.isEmpty {
            pending.append(line)
        } else {
            let waiter = waiters.removeFirst()
            waiter.timeoutTask?.cancel()
            waiter.promise.succeed(line)
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        if !waiters.isEmpty && pending.isEmpty { context.read() }
        context.fireChannelReadComplete()
    }

    func channelInactive(context: ChannelHandlerContext) {
        closed = true
        let waiting = waiters
        waiters = []
        waiting.forEach {
            $0.timeoutTask?.cancel()
            $0.promise.succeed(nil)
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failure = error
        let waiting = waiters
        waiters = []
        waiting.forEach {
            $0.timeoutTask?.cancel()
            $0.promise.fail(error)
        }
        context.close(promise: nil)
    }
}
