import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import StratoShared
import Testing

@testable import StratoAgentSPIFFE

@Suite("SPIFFE update bridge trust")
struct SPIFFEUpdateBridgeTests {
    static let logger = Logger(label: "test.bridge-trust")
    static let peerID = "spiffe://strato.local/control-plane"
    static let payload = "{\"exchangeVersion\":1,\"workloadWireVersion\":70}"

    @Test("Negative control: chain-only TLS accepts a wrong workload identity", .timeLimit(.minutes(1)))
    func originalAcceptsWrongIdentity() async throws {
        let pki = try PinningTestPKI()
        try await withServer(svid: pki.rogueSVID) { port in
            let tls = try SPIFFETLSConfig.makeClientConfiguration(svid: pki.agentSVID)
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            var configuration = HTTPClient.Configuration()
            configuration.tlsConfiguration = tls
            let client = HTTPClient(eventLoopGroupProvider: .shared(group), configuration: configuration)
            do {
                let response = try await client.execute(
                    HTTPClientRequest(url: "https://127.0.0.1:\(port)/agent/update/v1"),
                    deadline: .now() + .seconds(5))
                let bytes = try await response.body.collect(upTo: 65536)
                let decoded = try JSONDecoder().decode(
                    AgentUpdateBridgeResponse.self, from: Data(bytes.readableBytesView))
                #expect(decoded.workloadWireVersion == 70)
                try await client.shutdown()
                try await group.shutdownGracefully()
            } catch {
                try? await client.shutdown()
                try? await group.shutdownGracefully()
                throw error
            }
        }
    }

    @Test("Pinned bridge accepts legitimate control plane", .timeLimit(.minutes(1)))
    func originalAcceptsLegitimate() async throws {
        let pki = try PinningTestPKI()
        try await withServer(svid: pki.controlPlaneSVID) { port in
            let response = try await fetch(port: port, svid: pki.agentSVID)
            #expect(response?.workloadWireVersion == 70)
        }
    }

    @Test("Rejects same-bundle wrong identity and correct identity from foreign issuer", .timeLimit(.minutes(1)))
    func rejectsWrongPeers() async throws {
        let pki = try PinningTestPKI()
        for server in [pki.rogueSVID, pki.foreignControlPlaneSVID] {
            try await withServer(svid: server) { port in
                await #expect(throws: (any Error).self) { try await fetch(port: port, svid: pki.agentSVID) }
            }
        }
        try await withServer(svid: pki.controlPlaneSVID) { port in
            await #expect(throws: (any Error).self) {
                try await fetch(
                    port: port, svid: pki.agentSVID, expectedID: "spiffe://strato.local/other-control-plane")
            }
        }
    }

    @Test("Only authenticated 404 permits legacy fallback; errors and redirects fail closed", .timeLimit(.minutes(1)))
    func statusAndDecoding() async throws {
        let pki = try PinningTestPKI()
        try await withServer(svid: pki.controlPlaneSVID, status: .notFound) { port in
            let response = try await fetch(port: port, svid: pki.agentSVID)
            #expect(response == nil)
        }
        try await withServer(svid: pki.rogueSVID, status: .notFound) { port in
            await #expect(throws: (any Error).self) { try await fetch(port: port, svid: pki.agentSVID) }
        }
        for status in [HTTPResponseStatus.unauthorized, .forbidden, .found, .internalServerError] {
            try await withServer(svid: pki.controlPlaneSVID, status: status) { port in
                await #expect(throws: BridgeTransportError.self) { try await fetch(port: port, svid: pki.agentSVID) }
            }
        }
        try await withServer(svid: pki.controlPlaneSVID, body: "invalid JSON") { port in
            await #expect(throws: DecodingError.self) { try await fetch(port: port, svid: pki.agentSVID) }
        }
        try await withServer(svid: pki.controlPlaneSVID, body: String(repeating: "x", count: 65537)) { port in
            await #expect(throws: BridgeTransportError.self) { try await fetch(port: port, svid: pki.agentSVID) }
        }
        await #expect(throws: BridgeTransportError.self) {
            try await fetch(port: 1, svid: pki.agentSVID, scheme: "http")
        }
    }

    @Test("Closure, timeout and cancellation release the request", .timeLimit(.minutes(1)))
    func boundedLifetime() async throws {
        let pki = try PinningTestPKI()
        try await withServer(svid: pki.controlPlaneSVID, action: "close") { port in
            await #expect(throws: (any Error).self) { try await fetch(port: port, svid: pki.agentSVID) }
        }
        try await withServer(svid: pki.controlPlaneSVID, action: "stall") { port in
            await #expect(throws: BridgeTransportError.self) {
                try await fetch(port: port, svid: pki.agentSVID, timeout: .milliseconds(100))
            }
            let request = Task { try await fetch(port: port, svid: pki.agentSVID) }
            try await Task.sleep(for: .milliseconds(100))
            request.cancel()
            await #expect(throws: CancellationError.self) { try await request.value }
            let cancelled = Task { try await fetch(port: port, svid: pki.agentSVID) }
            cancelled.cancel()
            await #expect(throws: CancellationError.self) { try await cancelled.value }
        }
    }

    @Test("Fresh SVID snapshots select federated peer roots and rotated material", .timeLimit(.minutes(1)))
    func federationAndRotation() async throws {
        for _ in 0..<2 {
            let pki = try PinningTestPKI()
            let own = try PinningTestPKI(agentTrustDomain: "org.strato.local")
            let federated = X509SVID(
                spiffeID: own.agentSVID.spiffeID,
                certificateChain: own.agentSVID.certificateChain, privateKey: own.agentSVID.privateKey,
                trustBundle: [own.caPEM], federatedBundles: ["strato.local": [pki.caPEM]],
                expiresAt: pki.agentSVID.expiresAt)
            try await withServer(svid: pki.controlPlaneSVID, clientRoots: [own.caPEM]) { port in
                let response = try await fetch(port: port, svid: federated)
                #expect(response?.workloadWireVersion == 70)
                let missing = X509SVID(
                    spiffeID: federated.spiffeID, certificateChain: federated.certificateChain,
                    privateKey: federated.privateKey, trustBundle: federated.trustBundle,
                    expiresAt: federated.expiresAt)
                await #expect(throws: SPIFFEError.self) { try await fetch(port: port, svid: missing) }
            }
        }
    }

    func fetch(
        port: Int, svid: X509SVID, scheme: String = "https",
        expectedID: String = peerID, timeout: TimeAmount = .seconds(5)
    ) async throws -> AgentUpdateBridgeResponse? {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let response = try await SPIFFEUpdateBridge.fetch(
                url: URL(string: "\(scheme)://127.0.0.1:\(port)/agent/update/v1")!,
                svid: svid, expectedSPIFFEID: expectedID, on: group,
                logger: Self.logger, timeout: timeout)
            try await group.shutdownGracefully()
            return response
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func withServer(
        svid: X509SVID, status: HTTPResponseStatus = .ok, body: String = payload,
        action: String = "reply", clientRoots: [String]? = nil, _ test: (Int) async throws -> Void
    ) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var config = TLSConfiguration.makeServerConfiguration(
            certificateChain: try svid.certificateChain.map {
                .certificate(try NIOSSLCertificate(bytes: Array($0.utf8), format: .pem))
            }, privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(svid.privateKey.utf8), format: .pem)))
        config.trustRoots = .certificates(
            try (clientRoots ?? svid.trustBundle).map { try NIOSSLCertificate(bytes: Array($0.utf8), format: .pem) })
        config.certificateVerification = .noHostnameVerification
        let context = try NIOSSLContext(configuration: config)
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                do {
                    try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(
                        BridgeTestServer(status: status, body: body, action: action))
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch { return channel.eventLoop.makeFailedFuture(error) }
            }.bind(host: "127.0.0.1", port: 0).get()
        do {
            try await test(server.localAddress!.port!)
            try await server.close().get()
            try await group.shutdownGracefully()
        } catch {
            try? await server.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
    }
}

private final class BridgeTestServer: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    let status: HTTPResponseStatus
    let body: String
    let action: String
    init(status: HTTPResponseStatus, body: String, action: String) {
        self.status = status; self.body = body; self.action = action
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = unwrapInboundIn(data) else { return }
        if action == "close" { context.close(promise: nil); return }
        if action == "stall" { return }
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: String(body.utf8.count))
        headers.add(name: "Connection", value: "close")
        if status == .found { headers.add(name: "Location", value: "http://127.0.0.1:1/unsafe") }
        context.write(wrapOutboundOut(.head(.init(version: .http1_1, status: status, headers: headers))), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { context.close(promise: nil) }
}
