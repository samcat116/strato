#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix

/// The guest-facing HTTP listener for one network's metadata namespace
/// (STR-56).
///
/// ## The hop limit
///
/// Replies are sent with an IP TTL / hop limit of 1 by default, which is the
/// issue's "a guest cannot proxy metadata off-box" requirement. It is safe
/// because the guest is exactly one L2 hop away: both advertised routes to the
/// metadata address are on-link with an explicit zero next hop, so the guest
/// ARPs or NDs for `169.254.169.254` itself and OVN's responder answers from the
/// localport (see `docs/architecture/networking.md` §Instance metadata). A reply
/// that crosses any router therefore dies before it can be relayed to another
/// host.
///
/// The option is set on the listening socket *and* on each accepted child.
/// Linux clones the listener's `uc_ttl` onto accepted sockets and sends the
/// SYN/ACK from the listener itself, so the first setting is the load-bearing
/// one — but the two paths differ in the kernel and only one of them is
/// exercised by the loopback tests, so both are set rather than reasoned about.
///
/// ## What is bounded, and why each bound exists
///
/// Every peer here is untrusted guest code that can retry forever: the request
/// head is capped by the decoder's buffer, an idle connection is closed, the
/// number of concurrent connections is capped, and a request carrying a body is
/// refused outright (no route this service serves has one).
public actor MetadataHTTPServer {
    private let group: any EventLoopGroup
    private let responder: MetadataResponder
    /// Held in whatever width `setsockopt` takes here, spelled as NIO's own
    /// typealias because it is **not the same on every platform**: `Int32` on
    /// Darwin, `Int` on Linux. Naming either concretely compiles on one and
    /// fails on the other, and only one of those is what CI builds.
    ///
    /// Converted once, clamping rather than truncating: the value arrives from
    /// `--hop-limit`, and a nonsense one should reach the kernel as a nonsense
    /// one and be refused, never wrap around into a plausible TTL.
    private let hopLimit: ChannelOptions.Types.SocketOption.Value
    private let logger: Logger
    private var channels: [any Channel] = []
    /// Shared by every address this listener binds, so the cap is per *listener*
    /// as documented rather than per address family — a box created inside
    /// `listen` would give a dual-stack namespace twice the intended budget.
    private let connections = NIOLockedValueBox(ConnectionLedger())

    public init(group: any EventLoopGroup, responder: MetadataResponder, hopLimit: Int, logger: Logger) {
        self.group = group
        self.responder = responder
        self.hopLimit = .init(clamping: hopLimit)
        self.logger = logger
    }

    /// Binds one address and starts serving. Returns the port actually bound,
    /// which is what a test binding port 0 needs.
    @discardableResult
    public func listen(address: String, port: Int) async throws -> Int {
        let socketAddress = try SocketAddress(ipAddress: address, port: port)
        let connections = self.connections
        let responder = self.responder
        let logger = self.logger
        let hopLimitOption = Self.hopLimitOption(for: socketAddress)

        var bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 64)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            // One socket read at a time. The channel handler does not request
            // the next read until every request already decoded from the
            // current one has received its response, preserving HTTP/1.1
            // ordering and bounding stalled pipelined work.
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelInitializer { channel in
                // Refused before a single byte is read, so a connection flood
                // costs an accept and a close rather than a pipeline.
                //
                // Two caps, and the per-source one is the load-bearing half: a
                // namespace is shared by every guest on that network, so without
                // it one VM holding the whole budget open — trickling a byte
                // inside the idle timeout to stay alive — denies its neighbours
                // their metadata.
                let source = channel.remoteAddress?.ipAddress ?? "unknown"
                guard connections.withLockedValue({ $0.admit(source) }) else {
                    return channel.close()
                }
                channel.closeFuture.whenComplete { _ in
                    connections.withLockedValue { $0.release(source) }
                }

                // Built and added on the event loop, so the handlers — none of
                // which is `Sendable`, by design — never cross a concurrency
                // boundary.
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers([
                        // A guest that opens a connection and says nothing must
                        // not hold a slot against the cap above.
                        IdleStateHandler(readTimeout: .seconds(Int64(MetadataLimits.idleTimeoutSeconds))),
                        // Ahead of the decoder, because that is the only place
                        // the head's *total* size can be bounded. See the type.
                        MetadataRequestSizeHandler(),
                        // Assembled by hand rather than through
                        // `configureHTTPServerPipeline` so the size handler can
                        // sit in front of the decoder.
                        ByteToMessageHandler(
                            HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes),
                            maximumBufferSize: MetadataLimits.maxRequestHeadBytes),
                        HTTPResponseEncoder(),
                        HTTPServerPipelineHandler(),
                        MetadataChannelHandler(responder: responder, logger: logger),
                    ])
                }
            }

        // Applied to both the listener and its accepted children: see the type
        // doc. The option is family-specific, and setting the wrong family's
        // would fail the bind outright.
        if let hopLimitOption {
            bootstrap =
                bootstrap
                .serverChannelOption(hopLimitOption, value: hopLimit)
                .childChannelOption(hopLimitOption, value: hopLimit)
        }

        let channel = try await bootstrap.bind(to: socketAddress).get()
        channels.append(channel)
        logger.info(
            "Metadata listener bound",
            metadata: [
                "address": .string(address),
                "port": .stringConvertible(channel.localAddress?.port ?? port),
                "hopLimit": .stringConvertible(hopLimit),
            ])
        return channel.localAddress?.port ?? port
    }

    /// Replace what the listener serves. Called whenever the agent pushes a
    /// snapshot.
    public func update(_ snapshot: MetadataSnapshot) async {
        await responder.update(snapshot)
    }

    public func shutdown() async {
        for channel in channels {
            try? await channel.close().get()
        }
        channels = []
    }

    private static func hopLimitOption(for address: SocketAddress) -> ChannelOptions.Types.SocketOption? {
        switch address {
        case .v4:
            return .init(level: .ip, name: .init(rawValue: IP_TTL))
        case .v6:
            return .init(level: .ipv6, name: .init(rawValue: IPV6_UNICAST_HOPS))
        case .unixDomainSocket:
            // No such concept, and no way to reach one from a guest either.
            return nil
        }
    }
}

// MARK: - Connection accounting

/// Live connections, in total and per source address.
struct ConnectionLedger: Sendable {
    private var total = 0
    private var bySource: [String: Int] = [:]

    /// Admits a connection from `source`, or refuses it. Counted at accept, so
    /// a refusal costs an accept and a close rather than a pipeline.
    mutating func admit(_ source: String) -> Bool {
        guard total < MetadataLimits.maxConnections else { return false }
        let owned = bySource[source, default: 0]
        guard owned < MetadataLimits.maxConnectionsPerSource else { return false }
        total += 1
        bySource[source] = owned + 1
        return true
    }

    mutating func release(_ source: String) {
        total = max(0, total - 1)
        guard let owned = bySource[source] else { return }
        // Removed at zero rather than left at zero: the key is attacker-chosen,
        // so a map that only ever grows is its own denial-of-service.
        if owned <= 1 { bySource.removeValue(forKey: source) } else { bySource[source] = owned - 1 }
    }

    var liveConnections: Int { total }
}

// MARK: - The size bound

/// Closes a connection whose current request has sent more bytes than any
/// request this service serves could need.
///
/// This exists because the obvious bound does not work. `ByteToMessageHandler`'s
/// `maximumBufferSize` limits what accumulates *between* decoder invocations,
/// and NIOHTTP1's decoder consumes each header line as it arrives — so a guest
/// sending five hundred short headers never trips it, while `HTTPHeaders` grows
/// without limit behind it. Counting raw bytes in front of the decoder is what
/// actually bounds that.
///
/// The counter resets on the way out rather than on a request boundary, which
/// is exact here for the reason it would not be in a general HTTP server: no
/// route this service serves takes a request body, so everything a guest sends
/// between two responses is head.
private final class MetadataRequestSizeHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var received = 0

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        received += unwrapInboundIn(data).readableBytes
        guard received <= MetadataLimits.maxRequestHeadBytes else {
            // No response: a guest that ignores the limit gets the connection
            // taken away, not a courteous explanation it can loop on.
            context.close(promise: nil)
            return
        }
        context.fireChannelRead(data)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        received = 0
        context.write(data, promise: promise)
    }
}

// MARK: - The channel handler

/// One connection's worth of HTTP, translated to and from `MetadataResponder`.
///
/// Deliberately thin: everything that decides *what* to answer lives in the
/// responder, where it is asserted without a socket. What is here is framing,
/// the two refusals that can be made before the responder is involved, and the
/// logging rule.
private final class MetadataChannelHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let responder: MetadataResponder
    private let logger: Logger
    private var head: HTTPRequestHead?
    private var sawBody = false
    private var queuedRequests: [(head: HTTPRequestHead, hadBody: Bool)] = []
    private var isAnswering = false

    init(responder: MetadataResponder, logger: Logger) {
        self.responder = responder
        self.logger = logger
    }

    func channelActive(context: ChannelHandlerContext) {
        context.fireChannelActive()
        context.read()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            self.sawBody = false
        case .body:
            sawBody = true
        case .end:
            guard let head else { return }
            self.head = nil
            queuedRequests.append((head, sawBody))
            answerNext(context: context)
        }
    }

    // `Any` is required by NIO's ChannelInboundHandler callback signature.
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent {
            context.close(promise: nil)
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        // Includes the decoder giving up on an over-long request head. Nothing
        // to say to the peer that it did not already choose.
        logger.debug("Metadata connection closed on error", metadata: ["error": .string("\(error)")])
        context.close(promise: nil)
    }

    private func answerNext(context: ChannelHandlerContext) {
        guard !isAnswering, !queuedRequests.isEmpty else { return }
        isAnswering = true
        let request = queuedRequests.removeFirst()
        answer(context: context, head: request.head, hadBody: request.hadBody)
    }

    private func answer(context: ChannelHandlerContext, head: HTTPRequestHead, hadBody: Bool) {
        let keepAlive = head.isKeepAlive

        guard !hadBody else {
            // No route here reads a body, so accepting one is free memory for a
            // guest to waste.
            finish(
                context: context, response: MetadataResponse(status: 400, body: "unexpected request body"),
                keepAlive: false)
            return
        }
        guard let peer = context.channel.remoteAddress?.ipAddress,
            let source = MetadataCallerAddress(peer)
        else {
            // No usable peer address means no caller identity, and identity is
            // the entire security model of an instance metadata service.
            finish(context: context, response: MetadataResponse(status: 404, body: "not found"), keepAlive: false)
            return
        }

        let request = MetadataRequest(
            method: head.method.rawValue,
            target: head.uri,
            headers: MetadataHeaders(head.headers.map { (name: $0.name, value: $0.value) }),
            source: source)
        // The responder is an actor, so answering suspends. `context` and this
        // handler are event-loop state and neither is `Sendable`; carrying them
        // across the suspension in a loop-bound box is how NIO says "this comes
        // back to the same loop".
        let bound = NIOLoopBound((context, self), eventLoop: context.eventLoop)
        let logger = self.logger

        context.eventLoop.makeFutureWithTask { [responder] in
            await responder.respond(to: request, at: .now)
        }.whenComplete { result in
            let (context, handler) = bound.value
            let response: MetadataResponse
            switch result {
            case .success(let value): response = value
            case .failure: response = MetadataResponse(status: 500, body: "internal error")
            }
            // Method, target, status and source — never a header dictionary and
            // never the token, not even a prefix of one. Adding exactly that is
            // the natural debugging instinct, and it would write guests'
            // credentials into the agent's log.
            logger.debug(
                "Metadata request",
                metadata: [
                    "method": .string(request.method),
                    "target": .string(request.target),
                    "status": .stringConvertible(response.status),
                    "source": .string(request.source.description),
                ])
            handler.finish(context: context, response: response, keepAlive: keepAlive)
        }
    }

    private func finish(context: ChannelHandlerContext, response: MetadataResponse, keepAlive: Bool) {
        let bound = NIOLoopBound((context, self), eventLoop: context.eventLoop)
        write(context: context, response: response, keepAlive: keepAlive).whenComplete { result in
            let (context, handler) = bound.value
            handler.isAnswering = false

            guard case .success = result, keepAlive, context.channel.isActive else {
                handler.queuedRequests.removeAll(keepingCapacity: false)
                if context.channel.isActive { context.close(promise: nil) }
                return
            }

            handler.answerNext(context: context)
            if !handler.isAnswering { context.read() }
        }
    }

    private func write(
        context: ChannelHandlerContext, response: MetadataResponse, keepAlive: Bool
    ) -> EventLoopFuture<Void> {
        var headers = HTTPHeaders()
        for header in response.headers { headers.add(name: header.name, value: header.value) }
        headers.add(name: "content-length", value: String(response.body.utf8.count))
        if !keepAlive { headers.add(name: "connection", value: "close") }

        let responseHead = HTTPResponseHead(
            version: .http1_1, status: HTTPResponseStatus(statusCode: response.status), headers: headers)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: response.body.utf8.count)
        buffer.writeString(response.body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        return context.writeAndFlush(wrapOutboundOut(.end(nil)))
    }
}
