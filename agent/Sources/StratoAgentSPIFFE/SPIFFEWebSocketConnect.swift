import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket
import SPIFFEVerification
import WebSocketKit
import X509

// MARK: - Peer pinning

/// The control plane identity an agent connection must verify: the exact
/// SPIFFE ID the server's leaf certificate has to carry, plus the trust
/// bundle its chain must verify against.
///
/// Chaining to the trust bundle alone is not authentication of the control
/// plane — every workload in the trust domain holds a bundle-signed SVID, so
/// any of them (including another enrolled agent) could otherwise stand up a
/// rogue control plane. See issue #552.
public struct SPIFFEPeerPinning: Sendable {
    /// The exact `spiffe://` URI the peer's leaf certificate must present.
    public let expectedSPIFFEID: String
    /// Parsed trust bundle the presented chain must verify against.
    public let trustRoots: [Certificate]

    /// - Parameters:
    ///   - expectedSPIFFEID: The exact `spiffe://` URI to pin.
    ///   - trustBundlePEM: The trust bundle as PEM certificate strings (the
    ///     form SVIDs carry it in).
    public init(expectedSPIFFEID: String, trustBundlePEM: [String]) throws {
        self.expectedSPIFFEID = expectedSPIFFEID
        self.trustRoots = try trustBundlePEM.map { try Certificate(pemEncoded: $0) }
    }
}

// MARK: - Connector

/// Establishes a `wss://` WebSocket connection that verifies the server is
/// one specific SPIFFE workload.
///
/// websocket-kit's `WebSocket.connect` builds its own channel pipeline from a
/// `TLSConfiguration`, which has no way to carry a custom verification
/// callback — and `.noHostnameVerification` (the only mode compatible with
/// URI-SAN-only SVID certificates) would otherwise leave "chains to the
/// bundle" as the sole check. So this connector builds the pipeline itself:
/// `ClientBootstrap` → `NIOSSLClientHandler` with a pinned-identity
/// verification callback → HTTP upgrade → hand the upgraded channel to
/// websocket-kit's channel-taking entry point.
public enum SPIFFEWebSocketConnector {
    /// Connect to `url` (must be `wss://`), verifying the server against
    /// `pinning`, and invoke `onUpgrade` with the established WebSocket.
    ///
    /// The returned future completes when the HTTP upgrade finishes (after
    /// TLS verification succeeded), or fails if the connection, handshake, or
    /// upgrade fails.
    public static func connect(
        to url: String,
        headers: HTTPHeaders,
        tlsConfiguration: TLSConfiguration,
        pinning: SPIFFEPeerPinning,
        maxFrameSize: Int,
        on eventLoopGroup: any EventLoopGroup,
        logger: Logger,
        onUpgrade: @Sendable @escaping (WebSocket) -> Void
    ) -> EventLoopFuture<Void> {
        let eventLoop = eventLoopGroup.any()
        guard let parsed = URL(string: url), parsed.scheme == "wss", let host = parsed.host else {
            return eventLoop.makeFailedFuture(SPIFFEWebSocketError.invalidURL(url))
        }
        let port = parsed.port ?? 443
        let path = parsed.path.isEmpty ? "/" : parsed.path
        let query = parsed.query

        let upgradePromise = eventLoop.makePromise(of: Void.self)
        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .channelInitializer { channel in
                do {
                    let sslContext = try NIOSSLContext(configuration: tlsConfiguration)
                    // NIOSSL custom verification callbacks replace BoringSSL's
                    // verification entirely: the verifier chain-walks against
                    // the trust bundle AND requires the pinned SPIFFE ID as a
                    // URI SAN on the leaf.
                    let verification: NIOSSLCustomVerificationCallbackWithMetadata = { certificates, promise in
                        SPIFFEPeerVerifier.verifyPeerChain(
                            certificates,
                            roots: pinning.trustRoots,
                            expectedSPIFFEID: pinning.expectedSPIFFEID,
                            peerDescription: "control plane",
                            logger: logger,
                            promise: promise
                        )
                    }
                    let tlsHandler: NIOSSLClientHandler
                    do {
                        tlsHandler = try NIOSSLClientHandler(
                            context: sslContext, serverHostname: host,
                            customVerificationCallbackWithMetadata: verification)
                    } catch let error as NIOSSLExtraError where error == .cannotUseIPAddressInSNI {
                        tlsHandler = try NIOSSLClientHandler(
                            context: sslContext, serverHostname: nil,
                            customVerificationCallbackWithMetadata: verification)
                    }
                    try channel.pipeline.syncOperations.addHandler(tlsHandler)

                    let requestHandler = WebSocketUpgradeRequestHandler(
                        host: host, path: path, query: query, headers: headers,
                        upgradePromise: upgradePromise)
                    let requestHandlerBox = NIOLoopBound(requestHandler, eventLoop: channel.eventLoop)

                    let websocketUpgrader = NIOWebSocketClientUpgrader(
                        maxFrameSize: maxFrameSize,
                        automaticErrorHandling: true,
                        upgradePipelineHandler: { channel, _ in
                            WebSocket.client(on: channel, config: .init(), onUpgrade: onUpgrade)
                        }
                    )
                    let upgradeConfig: NIOHTTPClientUpgradeConfiguration = (
                        upgraders: [websocketUpgrader],
                        completionHandler: { _ in
                            upgradePromise.succeed(())
                            channel.pipeline.syncOperations.removeHandler(
                                requestHandlerBox.value, promise: nil)
                        }
                    )
                    try channel.pipeline.syncOperations.addHTTPClientHandlers(
                        leftOverBytesStrategy: .forwardBytes,
                        withClientUpgrade: upgradeConfig
                    )
                    try channel.pipeline.syncOperations.addHandler(requestHandler)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        let connect = bootstrap.connect(host: host, port: port)
        connect.cascadeFailure(to: upgradePromise)
        return connect.flatMap { _ in upgradePromise.futureResult }
    }
}

public enum SPIFFEWebSocketError: Error, CustomStringConvertible, Sendable {
    case invalidURL(String)
    case invalidResponseStatus(HTTPResponseHead)

    public var description: String {
        switch self {
        case .invalidURL(let url):
            return "invalid wss:// URL: \(url)"
        case .invalidResponseStatus(let head):
            return "WebSocket upgrade refused: \(head.status)"
        }
    }
}

// MARK: - Upgrade request handler

/// Sends the HTTP GET upgrade request once the TLS handshake completes and
/// surfaces a non-upgrade response as an error. Mirrors websocket-kit's
/// internal `HTTPUpgradeRequestHandler`, which is not public.
final class WebSocketUpgradeRequestHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let host: String
    private let path: String
    private let query: String?
    private let headers: HTTPHeaders
    private let upgradePromise: EventLoopPromise<Void>

    private var requestSent = false

    init(host: String, path: String, query: String?, headers: HTTPHeaders, upgradePromise: EventLoopPromise<Void>) {
        self.host = host
        self.path = path
        self.query = query
        self.headers = headers
        self.upgradePromise = upgradePromise
    }

    func channelActive(context: ChannelHandlerContext) {
        self.sendRequest(context: context)
        context.fireChannelActive()
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive {
            self.sendRequest(context: context)
        }
    }

    private func sendRequest(context: ChannelHandlerContext) {
        // This handler can be poked twice, once in handlerAdded and once in
        // channelActive; the request must only go out once.
        if self.requestSent {
            return
        }
        self.requestSent = true

        var headers = self.headers
        headers.add(name: "Host", value: self.host)

        var uri = self.path.hasPrefix("/") ? self.path : "/" + self.path
        if let query = self.query {
            uri += "?\(query)"
        }
        let requestHead = HTTPRequestHead(
            version: HTTPVersion(major: 1, minor: 1),
            method: .GET,
            uri: uri,
            headers: headers
        )
        context.write(self.wrapOutboundOut(.head(requestHead)), promise: nil)

        let emptyBuffer = context.channel.allocator.buffer(capacity: 0)
        context.write(self.wrapOutboundOut(.body(.byteBuffer(emptyBuffer))), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // `NIOHTTPClientUpgradeHandler` consumes the first response in the
        // success case; any response seen here is an upgrade refusal.
        let clientResponse = self.unwrapInboundIn(data)
        switch clientResponse {
        case .head(let responseHead):
            self.upgradePromise.fail(SPIFFEWebSocketError.invalidResponseStatus(responseHead))
        case .body:
            break
        case .end:
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        self.upgradePromise.fail(error)
        context.close(promise: nil)
    }
}
