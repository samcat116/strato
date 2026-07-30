import Foundation
import Logging
import NIOCore
import NIOPosix

/// A host-initiated connection to a guest vsock port, established through a
/// Firecracker vsock device's Unix-domain socket.
///
/// Firecracker multiplexes host↔guest vsock traffic over a single UDS (the
/// `udsPath` of a ``VsockConfig``). To reach a port the guest is listening on,
/// the host opens that UDS and sends a `CONNECT <port>\n` line; Firecracker
/// replies `OK <host_port>\n` once the guest accepts, after which the socket is
/// a raw bidirectional byte stream to the guest application.
///
/// ``connect(udsPath:port:timeout:retryInterval:logger:group:)`` wraps that
/// handshake with retry/timeout, because at boot the UDS may not exist yet and
/// the guest application may not be listening yet — both surface as transient
/// failures that clear once the guest is up.
///
/// The transport is SwiftNIO. Nothing here holds a raw file descriptor across a
/// suspension point: the channel owns the descriptor, so a `close()` racing an
/// in-flight read can no longer read from a recycled fd. Reads are
/// demand-driven (`autoRead` is off), so a guest that floods the channel cannot
/// grow an unbounded buffer in the host.
public actor VsockConnection {
    private let channel: Channel
    private let inbound: VsockInboundBridge
    private let logger: Logger

    /// The host-side port Firecracker assigned to this connection, parsed from
    /// the `OK <host_port>` handshake reply. Immutable, so readable without
    /// awaiting the actor.
    public nonisolated let assignedHostPort: UInt32

    private init(channel: Channel, inbound: VsockInboundBridge, assignedHostPort: UInt32, logger: Logger) {
        self.channel = channel
        self.inbound = inbound
        self.assignedHostPort = assignedHostPort
        self.logger = logger
    }

    /// Opens a connection to `port` on the guest through the vsock UDS at
    /// `udsPath`, retrying until `timeout` elapses.
    ///
    /// - Parameters:
    ///   - udsPath: The vsock device's host Unix-domain socket path (the
    ///     `udsPath` passed to ``VsockConfig``).
    ///   - port: The vsock port the guest application is listening on.
    ///   - timeout: Total wall-clock budget for establishing the connection.
    ///     Boot-time races (missing UDS, guest not yet listening) are retried
    ///     within this budget.
    ///   - retryInterval: Delay between attempts.
    ///   - logger: Logger for diagnostics.
    ///   - group: Event loop group to run the connection on. Defaults to NIO's
    ///     process-wide singleton.
    /// - Throws: ``FirecrackerError/timeout`` if no attempt succeeds before the
    ///   budget elapses, wrapping the last underlying error. Propagates
    ///   `CancellationError` promptly if the calling task is cancelled.
    public static func connect(
        udsPath: String,
        port: UInt32,
        timeout: TimeInterval = 10.0,
        retryInterval: TimeInterval = 0.1,
        logger: Logger = Logger(label: "SwiftFirecracker.Vsock"),
        group: EventLoopGroup? = nil
    ) async throws -> VsockConnection {
        let group = group ?? UDSChannel.defaultGroup
        // Monotonic: a wall-clock deadline can be moved by an NTP step
        // mid-boot, turning a bounded retry into an unbounded one (or an
        // instant give-up).
        let deadline = ContinuousClock.now + .seconds(timeout)
        var lastError: Error?

        while ContinuousClock.now < deadline {
            do {
                // Bound each attempt by whatever budget remains, not just the
                // gap between attempts: a peer that accepts the UDS and then
                // never replies would otherwise park the handshake forever
                // inside one attempt, which the overall deadline never sees.
                let remaining = deadline - ContinuousClock.now
                let (channel, bridge, hostPort) = try await attempt(
                    udsPath: udsPath, port: port, group: group, attemptBudget: remaining)
                logger.debug(
                    "Connected to guest vsock port",
                    metadata: ["uds": "\(udsPath)", "port": "\(port)", "host_port": "\(hostPort)"])
                return VsockConnection(
                    channel: channel, inbound: bridge, assignedHostPort: hostPort, logger: logger)
            } catch {
                lastError = error
                // `try` rather than `try?`: swallowing the CancellationError
                // here would leave a cancelled caller spinning through connect
                // attempts at full speed until the budget elapsed.
                try await Task.sleep(for: .seconds(retryInterval))
            }
        }

        throw FirecrackerError.timeout(
            "Connecting to guest vsock port \(port) via \(udsPath): \(lastError?.localizedDescription ?? "no attempts")"
        )
    }

    /// Sends data to the guest.
    public func write(_ data: Data) async throws {
        guard channel.isActive else { throw FirecrackerError.notConnected }
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await channel.writeAndFlush(buffer).get()
    }

    /// Returns the next newline-delimited line from the guest, or `nil` once the
    /// guest closes the connection.
    ///
    /// The line's trailing newline is stripped. Reads are issued on demand, so
    /// nothing is buffered ahead of what a caller has asked for.
    ///
    /// - Parameter timeout: How long to wait for a line before throwing
    ///   ``FirecrackerError/timeout``. `nil` waits indefinitely — correct for a
    ///   long-lived streaming reader, which is ended by ``close()`` rather than
    ///   by a deadline. A guest that accepts the connection and then wedges
    ///   without sending a full line is exactly what this bounds.
    public func nextLine(timeout: TimeInterval? = nil) async throws -> String? {
        try await inbound.next(
            on: channel.eventLoop,
            timeout: timeout.map { .clamping(seconds: $0) }
        ).get()
    }

    /// Closes the underlying channel. Idempotent.
    ///
    /// Unlike the previous raw-descriptor implementation, a `close()` racing an
    /// in-flight ``nextLine()`` is safe: NIO owns the descriptor and will not
    /// release it while the channel is still servicing reads. A pending
    /// `nextLine()` completes with `nil` rather than reading from whatever the
    /// kernel handed the recycled fd to next.
    public func close() async {
        try? await channel.close().get()
    }

    // MARK: - Handshake

    /// One connection attempt: open the UDS, perform the `CONNECT`/`OK`
    /// handshake in the pipeline, and return the live channel plus the assigned
    /// host port. Any failure closes the channel before throwing so a retry
    /// starts clean.
    private static func attempt(
        udsPath: String, port: UInt32, group: EventLoopGroup, attemptBudget: Duration
    ) async throws -> (Channel, VsockInboundBridge, UInt32) {
        // Pin the channel and its handshake promise to one loop (an EventLoop
        // is itself an EventLoopGroup), so completing the promise from the
        // handler never costs a cross-loop hop.
        let loop = group.next()
        let handshakePromise = loop.makePromise(of: UInt32.self)
        let bridge = VsockInboundBridge()

        // Deadline for this attempt's handshake, cancelled the moment it
        // settles. Without it a peer that accepts and stays silent parks here
        // forever, regardless of the caller's overall budget.
        let handshakeTimeout = loop.scheduleTask(in: .clamping(attemptBudget)) {
            handshakePromise.fail(
                FirecrackerError.timeout("vsock handshake did not complete before the deadline"))
        }
        handshakePromise.futureResult.whenComplete { _ in handshakeTimeout.cancel() }

        let channel: Channel
        do {
            channel = try await UDSChannel.connect(path: udsPath, group: loop) { channel in
                do {
                    // Reads are demand-driven; the bridge asks for more only
                    // when a consumer is waiting.
                    try channel.syncOptions?.setOption(.autoRead, value: false)
                    try channel.pipeline.syncOperations.addHandlers([
                        VsockHandshakeHandler(port: port, promise: handshakePromise),
                        ByteToMessageHandler(LineFrameDecoder()),
                        bridge,
                    ])
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
        } catch {
            // The pipeline never came up, so nothing will ever complete the
            // promise. Fail it explicitly — a promise dropped uncompleted trips
            // NIO's leak check, and the connect retry loop hits this path on
            // every attempt while the guest is still booting.
            handshakePromise.fail(error)
            throw error
        }

        do {
            let hostPort = try await handshakePromise.futureResult.get()
            return (channel, bridge, hostPort)
        } catch {
            try? await channel.close().get()
            throw error
        }
    }
}

/// Performs the `CONNECT <port>` / `OK <host_port>` handshake, then removes
/// itself from the pipeline so the raw guest stream flows to the framing
/// handlers behind it.
private final class VsockHandshakeHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let port: UInt32
    private let promise: EventLoopPromise<UInt32>
    private var buffer = ByteBuffer()
    private var completed = false

    /// The reply is one short line; cap the buffer so a misbehaving peer that
    /// never sends a newline cannot grow it without bound.
    private static let maxReplyBytes = 64

    init(port: UInt32, promise: EventLoopPromise<UInt32>) {
        self.port = port
        self.promise = promise
    }

    func channelActive(context: ChannelHandlerContext) {
        var out = context.channel.allocator.buffer(capacity: 24)
        out.writeString("CONNECT \(port)\n")
        context.writeAndFlush(self.wrapOutboundOut(out), promise: nil)
        // autoRead is off, so ask for the reply explicitly.
        context.read()
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !completed else {
            context.fireChannelRead(data)
            return
        }

        var incoming = self.unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)

        guard let newlineIndex = buffer.readableBytesView.firstIndex(of: 0x0A) else {
            if buffer.readableBytes > Self.maxReplyBytes {
                fail(
                    context: context,
                    error: FirecrackerError.connectionFailed(
                        "vsock handshake reply exceeded \(Self.maxReplyBytes) bytes without a newline"))
            } else {
                context.read()  // need more before we can decide
            }
            return
        }

        let lineLength = newlineIndex - buffer.readableBytesView.startIndex
        let line =
            buffer.readString(length: lineLength)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        buffer.moveReaderIndex(forwardBy: 1)  // consume the newline

        // Firecracker replies "OK <assigned_host_port>" on success and resets
        // the socket on failure, so any non-OK line is an error.
        guard line.hasPrefix("OK ") else {
            fail(
                context: context,
                error: FirecrackerError.connectionFailed("vsock handshake rejected: \(line)"))
            return
        }
        guard let hostPort = UInt32(line.dropFirst(3).trimmingCharacters(in: .whitespaces)) else {
            fail(
                context: context,
                error: FirecrackerError.deserializationError(
                    "Unparseable vsock handshake reply: \(line)"))
            return
        }

        completed = true
        promise.succeed(hostPort)

        // Anything the guest already sent after the reply belongs downstream.
        let leftover = buffer
        buffer = ByteBuffer()
        if leftover.readableBytes > 0 {
            context.fireChannelRead(self.wrapInboundOut(leftover))
        }
        context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !completed {
            promise.fail(
                FirecrackerError.connectionFailed("vsock handshake closed before reply"))
            completed = true
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !completed {
            promise.fail(error)
            completed = true
        }
        context.fireErrorCaught(error)
    }

    private func fail(context: ChannelHandlerContext, error: Error) {
        completed = true
        promise.fail(error)
        context.close(promise: nil)
    }
}

/// Bridges decoded inbound lines to async consumers, with demand-driven reads.
///
/// All state is touched only on the channel's event loop: the handler callbacks
/// run there by definition, and ``next(on:)`` hops onto it before inspecting
/// anything.
private final class VsockInboundBridge: ChannelInboundHandler, @unchecked Sendable {
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

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }

    /// The next line, `nil` once the peer has closed.
    func next(on eventLoop: EventLoop, timeout: TimeAmount?) -> EventLoopFuture<String?> {
        eventLoop.flatSubmit {
            if !self.pending.isEmpty {
                return eventLoop.makeSucceededFuture(self.pending.removeFirst())
            }
            if let failure = self.failure {
                return eventLoop.makeFailedFuture(failure)
            }
            if self.closed {
                return eventLoop.makeSucceededFuture(nil)
            }

            let id = self.nextWaiterID
            self.nextWaiterID += 1
            let promise = eventLoop.makePromise(of: String?.self)

            // Time out this one read rather than tearing down the whole
            // connection to escape a wedged guest.
            let timeoutTask = timeout.map { budget in
                eventLoop.scheduleTask(in: budget) {
                    guard let index = self.waiters.firstIndex(where: { $0.id == id }) else { return }
                    self.waiters.remove(at: index)
                    promise.fail(
                        FirecrackerError.timeout("Waiting for a line from the guest vsock port"))
                }
            }

            self.waiters.append(Waiter(id: id, promise: promise, timeoutTask: timeoutTask))
            // Demand one more read now that someone is actually waiting.
            self.context?.read()
            return promise.futureResult
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = self.unwrapInboundIn(data)
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
        // Still someone waiting and nothing buffered? Keep the demand alive.
        if !waiters.isEmpty && pending.isEmpty {
            context.read()
        }
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
