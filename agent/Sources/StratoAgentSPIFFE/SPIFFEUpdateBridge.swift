import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import SPIFFEVerification
import StratoShared

/// The pre-registration update exchange must authenticate the same exact
/// control-plane identity as the workload WebSocket. TLS configuration alone
/// cannot express SPIFFE identity verification through AsyncHTTPClient.
public enum SPIFFEUpdateBridge {
    public static func fetch(
        url: URL,
        svid: X509SVID,
        expectedSPIFFEID: String,
        on group: any EventLoopGroup,
        logger: Logger,
        timeout: TimeAmount = .seconds(15)
    ) async throws -> AgentUpdateBridgeResponse? {
        try Task.checkCancellation()
        guard url.scheme == "https", let host = url.host,
            url.user == nil, url.password == nil
        else { throw BridgeTransportError.invalidURL }
        let pinning = try SPIFFEPeerPinning(expectedSPIFFEID: expectedSPIFFEID, svid: svid)
        let peer = SPIFFEIdentity(uri: expectedSPIFFEID)!
        let tls = try SPIFFETLSConfig.makeClientConfiguration(svid: svid, peerTrustDomain: peer.trustDomain)
        let sslContext = try NIOSSLContext(configuration: tls)
        let loop = group.any()
        let promise = loop.makePromise(of: BridgeHTTPResponse.self)
        let handler = try await loop.submit {
            NIOLoopBound(BridgeResponseHandler(url: url, promise: promise), eventLoop: loop)
        }.get()
        let verification:
            @Sendable ([NIOSSLCertificate], EventLoopPromise<NIOSSLVerificationResultWithMetadata>) -> Void = {
                certificates, result in
                SPIFFEPeerVerifier.verifyPeerChain(
                    certificates, roots: pinning.trustRoots,
                    expectedSPIFFEID: pinning.expectedSPIFFEID,
                    peerDescription: "control plane update bridge", logger: logger, promise: result)
            }
        let bootstrap = ClientBootstrap(group: loop)
            .connectTimeout(.seconds(10))
            .channelInitializer { channel in
                do {
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
                    try channel.pipeline.syncOperations.addHTTPClientHandlers()
                    try channel.pipeline.syncOperations.addHandler(handler.value)
                    return loop.makeSucceededVoidFuture()
                } catch { return loop.makeFailedFuture(error) }
            }
        let deadline = loop.scheduleTask(in: timeout) {
            handler.value.finish(.failure(BridgeTransportError.timedOut))
        }
        let connection = bootstrap.connect(host: host, port: url.port ?? 443)
        connection.whenComplete { result in
            switch result {
            case .success(let channel):
                promise.futureResult.whenComplete { _ in channel.close(promise: nil) }
            case .failure(let error): handler.value.finish(.failure(error))
            }
        }
        defer { deadline.cancel() }
        let response = try await withTaskCancellationHandler {
            try await promise.futureResult.get()
        } onCancel: {
            loop.execute { handler.value.finish(.failure(CancellationError())) }
        }
        try Task.checkCancellation()
        guard response.status != .notFound else { return nil }
        return try JSONDecoder().decode(AgentUpdateBridgeResponse.self, from: response.body)
    }
}

public enum BridgeTransportError: Error, Sendable {
    case invalidURL
    case unexpectedStatus(Int)
    case oversizedBody
    case incompleteResponse
    case timedOut
}

private struct BridgeHTTPResponse: Sendable {
    let status: HTTPResponseStatus
    let body: Data
}

/// One request, no redirects or pooling. Completion, cancellation, timeout,
/// malformed responses and TLS errors all close the connected channel.
private final class BridgeResponseHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart
    private let url: URL
    private let promise: EventLoopPromise<BridgeHTTPResponse>
    private var context: ChannelHandlerContext?
    private var status: HTTPResponseStatus?
    private var body = Data()
    private var finished = false
    private static let maximumBodyBytes = 64 << 10

    init(url: URL, promise: EventLoopPromise<BridgeHTTPResponse>) {
        self.url = url
        self.promise = promise
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if finished { context.close(promise: nil) }
    }

    func handlerRemoved(context: ChannelHandlerContext) { self.context = nil }

    func channelActive(context: ChannelHandlerContext) {
        guard !finished else { context.close(promise: nil); return }
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: url.host! + (url.port.map { ":\($0)" } ?? ""))
        headers.add(name: "Connection", value: "close")
        headers.add(name: "Accept", value: "application/json")
        headers.add(name: "Strato-Workload-Wire-Version", value: String(WireProtocol.currentVersion))
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let uri = path + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        context.write(
            wrapOutboundOut(.head(.init(version: .http1_1, method: .GET, uri: uri, headers: headers))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !finished else { return }
        switch unwrapInboundIn(data) {
        case .head(let head):
            guard head.status == .ok || head.status == .notFound else {
                finish(.failure(BridgeTransportError.unexpectedStatus(Int(head.status.code))))
                return
            }
            status = head.status
        case .body(let buffer):
            guard buffer.readableBytes <= Self.maximumBodyBytes - body.count else {
                finish(.failure(BridgeTransportError.oversizedBody))
                return
            }
            body.append(contentsOf: buffer.readableBytesView)
        case .end:
            guard let status else { finish(.failure(BridgeTransportError.incompleteResponse)); return }
            finish(.success(BridgeHTTPResponse(status: status, body: body)))
        }
    }

    func finish(_ result: Result<BridgeHTTPResponse, any Error>) {
        guard !finished else { return }
        finished = true
        promise.completeWith(result)
        context?.close(promise: nil)
    }
    func channelInactive(context: ChannelHandlerContext) {
        finish(.failure(BridgeTransportError.incompleteResponse))
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { finish(.failure(error)) }
}
