import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix

/// HTTP client that communicates over a Unix domain socket.
/// Used to interact with the Firecracker API.
///
/// One channel per client, with round trips paired by a FIFO promise queue
/// inside the pipeline. That pairing is what makes concurrent callers safe: the
/// previous hand-rolled implementation released its actor at each `await`, so
/// two overlapping requests could both write and then race to read the socket —
/// delivering one caller's response to the other, or discarding a response
/// entirely when one read pulled in both.
///
/// Response framing (`Content-Length`, chunked encoding, pipelined boundaries)
/// is `NIOHTTP1`'s job now rather than hand-rolled string splitting.
public actor UnixSocketHTTPClient {
    /// Ceiling on a single response body. Firecracker's API returns small JSON
    /// documents; this only exists so a bogus `Content-Length` cannot make the
    /// client buffer without bound.
    private static let maxResponseBytes = 8 * 1024 * 1024

    /// Default ceiling on how long one request may wait for its response.
    ///
    /// A VMM that accepts the connection but never answers would otherwise park
    /// the caller forever and grow the handler's waiter queue without bound.
    /// Firecracker's API calls are local and fast; this only has to be far
    /// enough above normal to never fire in practice.
    public static let defaultRequestTimeout: TimeInterval = 30

    private let socketPath: String
    private let logger: Logger
    private let group: EventLoopGroup
    private let requestTimeout: TimeInterval
    private var channel: Channel?
    private var roundTrip: HTTPRoundTripHandler?

    public init(
        socketPath: String,
        logger: Logger = Logger(label: "SwiftFirecracker.HTTPClient"),
        group: EventLoopGroup? = nil,
        requestTimeout: TimeInterval = UnixSocketHTTPClient.defaultRequestTimeout
    ) {
        self.socketPath = socketPath
        self.logger = logger
        self.group = group ?? UDSChannel.defaultGroup
        self.requestTimeout = requestTimeout
    }

    /// Connects to the Unix socket.
    ///
    /// Calling this on an already-connected client closes the previous channel
    /// first, so a reconnect cannot silently orphan a live socket (and its
    /// pending round trips) by overwriting the reference.
    public func connect() async throws {
        logger.debug("Connecting to socket", metadata: ["path": "\(socketPath)"])

        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw FirecrackerError.invalidSocketPath(socketPath)
        }

        if channel != nil {
            await disconnect()
        }

        let handler = HTTPRoundTripHandler()
        // Pin to one loop so the handler's promises never hop.
        let loop = group.next()
        let channel = try await UDSChannel.connect(path: socketPath, group: loop) { channel in
            do {
                try channel.pipeline.syncOperations.addHTTPClientHandlers()
                try channel.pipeline.syncOperations.addHandlers([
                    NIOHTTPClientResponseAggregator(maxContentLength: Self.maxResponseBytes),
                    handler,
                ])
                return channel.eventLoop.makeSucceededVoidFuture()
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }
        }

        self.channel = channel
        self.roundTrip = handler
        logger.info("Connected to Firecracker socket", metadata: ["path": "\(socketPath)"])
    }

    /// Disconnects from the socket
    public func disconnect() async {
        if let channel {
            try? await channel.close().get()
        }
        channel = nil
        roundTrip = nil
        logger.debug("Disconnected from socket")
    }

    /// Sends an HTTP request and returns the response.
    ///
    /// Safe to call concurrently: each round trip is queued in pipeline order,
    /// so a response is always delivered to the caller that sent the matching
    /// request.
    public func request(
        method: HTTPMethod,
        path: String,
        body: Data? = nil
    ) async throws -> HTTPResponse {
        guard let channel, let roundTrip, channel.isActive else {
            throw FirecrackerError.notConnected
        }

        var head = HTTPRequestHead(
            version: .http1_1,
            method: .init(rawValue: method.rawValue),
            uri: path)
        head.headers.add(name: "Host", value: "localhost")
        head.headers.add(name: "Accept", value: "application/json")

        var buffer: ByteBuffer?
        if let body {
            head.headers.add(name: "Content-Type", value: "application/json")
            head.headers.add(name: "Content-Length", value: String(body.count))
            var out = channel.allocator.buffer(capacity: body.count)
            out.writeBytes(body)
            buffer = out
        }

        logger.debug(
            "Sending request",
            metadata: [
                "method": "\(method.rawValue)",
                "path": "\(path)",
                "bodySize": "\(body?.count ?? 0)",
            ])

        let response = try await roundTrip.send(
            head: head, body: buffer, on: channel.eventLoop,
            timeout: .clamping(seconds: requestTimeout)
        ).get()

        logger.debug(
            "Received response",
            metadata: [
                "statusCode": "\(response.statusCode)",
                "bodySize": "\(response.body?.count ?? 0)",
            ])

        return response
    }
}

/// Serialises request/response round trips over one channel.
///
/// Requests are enqueued and written in the same event-loop tick, so the queue
/// order always matches the order the bytes hit the wire — which is what makes
/// pairing responses back to callers correct for pipelined requests.
///
/// All state is touched only on the channel's event loop.
private final class HTTPRoundTripHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = NIOHTTPClientResponseFull
    typealias OutboundOut = HTTPClientRequestPart

    private struct Waiter {
        let promise: EventLoopPromise<HTTPResponse>
        let timeoutTask: Scheduled<Void>?
    }

    private var waiters: [Waiter] = []
    private var context: ChannelHandlerContext?
    private var failure: Error?

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }

    func send(
        head: HTTPRequestHead, body: ByteBuffer?, on eventLoop: EventLoop, timeout: TimeAmount
    ) -> EventLoopFuture<HTTPResponse> {
        eventLoop.flatSubmit {
            if let failure = self.failure {
                return eventLoop.makeFailedFuture(failure)
            }
            guard let context = self.context else {
                return eventLoop.makeFailedFuture(FirecrackerError.notConnected)
            }

            let promise = eventLoop.makePromise(of: HTTPResponse.self)

            // Responses are consumed strictly in order, so a timed-out request
            // cannot simply be dropped from the middle of the queue without
            // mis-pairing every response behind it. Fail the whole channel
            // instead: an unanswered request means the VMM is not talking to us
            // any more, and reconnecting is the only sound recovery.
            let timeoutTask = eventLoop.scheduleTask(in: timeout) { [weak self] in
                guard let self, let context = self.context else { return }
                let error = FirecrackerError.timeout(
                    "Firecracker did not answer \(head.method.rawValue) \(head.uri) in time")
                self.failAll(error, context: context)
                context.close(promise: nil)
            }
            self.waiters.append(Waiter(promise: promise, timeoutTask: timeoutTask))

            context.write(self.wrapOutboundOut(.head(head)), promise: nil)
            if let body {
                context.write(self.wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
            }
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)

            return promise.futureResult
        }
    }

    /// Fails every outstanding round trip and records the error so later
    /// requests fail fast rather than queueing onto a dead channel.
    private func failAll(_ error: Error, context: ChannelHandlerContext) {
        failure = error
        let waiting = waiters
        waiters = []
        waiting.forEach {
            $0.timeoutTask?.cancel()
            $0.promise.fail(error)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let full = self.unwrapInboundIn(data)

        guard !waiters.isEmpty else {
            // A response with nothing outstanding means the peer is not
            // speaking the protocol we think it is; drop the connection rather
            // than mis-attribute it to the next request.
            let error = FirecrackerError.deserializationError(
                "Received an HTTP response with no request outstanding")
            failure = error
            context.close(promise: nil)
            return
        }

        var headers: [String: String] = [:]
        for header in full.head.headers {
            headers[header.name.lowercased()] = header.value
        }

        let body = full.body.map { Data($0.readableBytesView) }
        let waiter = waiters.removeFirst()
        waiter.timeoutTask?.cancel()
        waiter.promise.succeed(
            HTTPResponse(
                statusCode: Int(full.head.status.code),
                headers: headers,
                body: (body?.isEmpty ?? true) ? nil : body))
    }

    func channelInactive(context: ChannelHandlerContext) {
        failAll(
            failure ?? FirecrackerError.connectionFailed("Firecracker closed the API socket"),
            context: context)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failAll(error, context: context)
        context.close(promise: nil)
    }
}

/// HTTP methods supported by Firecracker API
public enum HTTPMethod: String, Sendable {
    case GET
    case PUT
    case PATCH
    case DELETE
}

/// HTTP response from Firecracker
public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data?

    public var isSuccess: Bool {
        statusCode >= 200 && statusCode < 300
    }
}
