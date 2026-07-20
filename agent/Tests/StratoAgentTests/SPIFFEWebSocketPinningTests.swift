import Crypto
import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket
import Testing
import WebSocketKit
import X509

@testable import StratoAgentSPIFFE

/// Tests for the agent's pinned-identity control-plane connection (issue
/// #552): the TLS server must present not just a bundle-signed certificate
/// but the exact pinned control-plane SPIFFE ID. A rogue workload holding a
/// perfectly valid SVID from the same trust domain — the certificate that a
/// chain-only check would accept — must be refused.
@Suite("SPIFFE WebSocket pinning")
struct SPIFFEWebSocketPinningTests {

    private static let logger = Logger(label: "test.spiffe-ws-pinning")
    private static let controlPlaneID = "spiffe://strato.local/control-plane"

    // MARK: - Pinning material

    @Test("SPIFFEPeerPinning parses PEM trust bundles")
    func pinningParsesTrustBundle() throws {
        let pki = try PinningTestPKI()
        let pinning = try SPIFFEPeerPinning(
            expectedSPIFFEID: Self.controlPlaneID, trustBundlePEM: [pki.caPEM])
        #expect(pinning.expectedSPIFFEID == Self.controlPlaneID)
        #expect(pinning.trustRoots.count == 1)

        #expect(throws: (any Error).self) {
            _ = try SPIFFEPeerPinning(
                expectedSPIFFEID: Self.controlPlaneID, trustBundlePEM: ["not a certificate"])
        }
    }

    // MARK: - Connection-level verification

    @Test("Connects and echoes when the server presents the pinned SPIFFE ID", .timeLimit(.minutes(1)))
    func connectsToPinnedControlPlane() async throws {
        let pki = try PinningTestPKI()
        try await withTLSWebSocketServer(serverSVID: pki.controlPlaneSVID) { port in
            let echoed = try await connectAndEcho(port: port, pki: pki)
            #expect(echoed == "echo:ping")
        }
    }

    @Test(
        "Refuses a bundle-signed workload SVID that is not the control plane",
        .timeLimit(.minutes(1)))
    func refusesRogueTrustDomainWorkload() async throws {
        // The attack from issue #552: the server's certificate chains to the
        // trust bundle (it is a real SVID from the same SPIRE deployment) but
        // belongs to another workload. Chain verification alone accepts it;
        // only the pinned-identity check refuses.
        let pki = try PinningTestPKI()
        try await withTLSWebSocketServer(serverSVID: pki.rogueSVID) { port in
            await #expect(throws: (any Error).self) {
                _ = try await connectAndEcho(port: port, pki: pki)
            }
        }
    }

    @Test(
        "Refuses a certificate with the pinned ID that does not chain to the bundle",
        .timeLimit(.minutes(1)))
    func refusesForeignCertificateWithPinnedID() async throws {
        // The converse attack: right SPIFFE ID, wrong issuer. The URI SAN
        // matches but the chain walk against the trust bundle must fail.
        let pki = try PinningTestPKI()
        try await withTLSWebSocketServer(serverSVID: pki.foreignControlPlaneSVID) { port in
            await #expect(throws: (any Error).self) {
                _ = try await connectAndEcho(port: port, pki: pki)
            }
        }
    }

    @Test("Rejects a non-wss URL", .timeLimit(.minutes(1)))
    func rejectsNonWSSURL() async throws {
        let pki = try PinningTestPKI()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let tlsConfiguration = try SPIFFETLSConfig.makeClientConfiguration(svid: pki.agentSVID)
        let pinning = try SPIFFEPeerPinning(
            expectedSPIFFEID: Self.controlPlaneID, trustBundlePEM: [pki.caPEM])

        await #expect(throws: (any Error).self) {
            try await SPIFFEWebSocketConnector.connect(
                to: "ws://127.0.0.1:1/agent/ws",
                headers: HTTPHeaders(),
                tlsConfiguration: tlsConfiguration,
                pinning: pinning,
                maxFrameSize: 1 << 24,
                on: group,
                logger: Self.logger,
                onUpgrade: { _ in }
            ).get()
        }
        try? await group.shutdownGracefully()
    }

    // MARK: - Client plumbing

    /// Connect to the in-process server with the agent's SVID and pinned
    /// control-plane ID, send one text frame, and return the reply.
    private func connectAndEcho(port: Int, pki: PinningTestPKI) async throws -> String {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        // The real client path: mTLS material from the agent SVID via
        // SPIFFETLSConfig, identity pinning from the trust bundle.
        let tlsConfiguration = try SPIFFETLSConfig.makeClientConfiguration(svid: pki.agentSVID)
        let pinning = try SPIFFEPeerPinning(
            expectedSPIFFEID: Self.controlPlaneID, trustBundlePEM: [pki.caPEM])

        do {
            let echoed: String = try await withCheckedThrowingContinuation { continuation in
                let resumed = ResumeGuard()
                let future = SPIFFEWebSocketConnector.connect(
                    to: "wss://127.0.0.1:\(port)/agent/ws?name=test-agent",
                    headers: HTTPHeaders(),
                    tlsConfiguration: tlsConfiguration,
                    pinning: pinning,
                    maxFrameSize: 1 << 24,
                    on: group,
                    logger: Self.logger
                ) { ws in
                    ws.onText { ws, text in
                        if resumed.claim() {
                            continuation.resume(returning: text)
                        }
                        _ = ws.close()
                    }
                    ws.send("ping")
                }
                future.whenFailure { error in
                    if resumed.claim() {
                        continuation.resume(throwing: error)
                    }
                }
            }
            try? await group.shutdownGracefully()
            return echoed
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    /// Single-use latch so the continuation resumes exactly once whichever of
    /// success/failure fires first.
    private final class ResumeGuard: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if resumed { return false }
            resumed = true
            return true
        }
    }

    // MARK: - In-process TLS WebSocket server

    /// Run `body` with the loopback port of a TLS WebSocket echo server
    /// presenting `serverSVID` and requiring a client certificate chained to
    /// that SVID's trust bundle — the shape of the control plane's Envoy
    /// front end.
    private func withTLSWebSocketServer(
        serverSVID: X509SVID,
        _ body: (Int) async throws -> Void
    ) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        // Built by hand rather than via SPIFFETLSConfig.makeServerConfiguration:
        // that helper's `.fullVerification` hostname-matches the *client*
        // certificate, which an SVID (URI SAN only) can never satisfy. The
        // real deployment's server side is Envoy with SPIFFE SAN matchers;
        // here it's enough to require a client certificate that chains to the
        // trust bundle.
        var serverTLS = TLSConfiguration.makeServerConfiguration(
            certificateChain: try serverSVID.certificateChain.map {
                .certificate(try NIOSSLCertificate(bytes: [UInt8]($0.utf8), format: .pem))
            },
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: [UInt8](serverSVID.privateKey.utf8), format: .pem))
        )
        serverTLS.trustRoots = .certificates(
            try serverSVID.trustBundle.map { try NIOSSLCertificate(bytes: [UInt8]($0.utf8), format: .pem) })
        serverTLS.certificateVerification = .noHostnameVerification
        let sslContext = try NIOSSLContext(configuration: serverTLS)

        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: 1 << 24,
            automaticErrorHandling: true,
            shouldUpgrade: { channel, _ in
                channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { channel, _ in
                WebSocket.server(on: channel) { ws in
                    ws.onText { ws, text in
                        ws.send("echo:\(text)")
                    }
                }
            }
        )

        let serverChannel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                do {
                    try channel.pipeline.syncOperations.addHandler(
                        NIOSSLServerHandler(context: sslContext))
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(
                        withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in })
                    )
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()

        do {
            let port = try #require(serverChannel.localAddress?.port)
            try await body(port)
        } catch {
            try? await serverChannel.close()
            try? await group.shutdownGracefully()
            throw error
        }
        try? await serverChannel.close()
        try? await group.shutdownGracefully()
    }
}

// MARK: - Test PKI

/// A miniature SPIRE-shaped PKI in the agent's own SVID types: one CA, a
/// control-plane server SVID, a rogue workload SVID from the same trust
/// domain, an agent client SVID, and a foreign-CA certificate claiming the
/// control plane's SPIFFE ID.
private struct PinningTestPKI {
    let caPEM: String
    let controlPlaneSVID: X509SVID
    let rogueSVID: X509SVID
    let agentSVID: X509SVID
    let foreignControlPlaneSVID: X509SVID

    init() throws {
        let (ca, caKey, caName) = try Self.makeCA(commonName: "Test SPIRE CA")
        caPEM = try ca.serializeAsPEM().pemString

        let (foreignCA, foreignCAKey, foreignCAName) = try Self.makeCA(commonName: "Foreign CA")

        func makeSVID(
            commonName: String,
            spiffePath: String,
            issuerName: DistinguishedName,
            issuerKey: Certificate.PrivateKey,
            trustBundlePEM: [String]
        ) throws -> X509SVID {
            let key = P256.Signing.PrivateKey()
            let leaf = try Certificate(
                version: .v3,
                serialNumber: .init(),
                publicKey: Certificate.PrivateKey(key).publicKey,
                notValidBefore: Date().addingTimeInterval(-60),
                notValidAfter: Date().addingTimeInterval(3600),
                issuer: issuerName,
                subject: try DistinguishedName { CommonName(commonName) },
                signatureAlgorithm: .ecdsaWithSHA256,
                extensions: try Certificate.Extensions {
                    Critical(BasicConstraints.notCertificateAuthority)
                    KeyUsage(digitalSignature: true)
                    SubjectAlternativeNames([
                        .uniformResourceIdentifier("spiffe://strato.local\(spiffePath)")
                    ])
                },
                issuerPrivateKey: issuerKey
            )
            return X509SVID(
                spiffeID: SPIFFEIdentity(trustDomain: "strato.local", path: spiffePath),
                certificateChain: [try leaf.serializeAsPEM().pemString],
                privateKey: key.pemRepresentation,
                trustBundle: trustBundlePEM,
                expiresAt: leaf.notValidAfter
            )
        }

        controlPlaneSVID = try makeSVID(
            commonName: "control-plane",
            spiffePath: "/control-plane",
            issuerName: caName,
            issuerKey: caKey,
            trustBundlePEM: [caPEM]
        )

        // A valid SVID from the same trust domain that is NOT the control
        // plane: chain verification alone would accept it as a server.
        rogueSVID = try makeSVID(
            commonName: "rogue-workload",
            spiffePath: "/agent/rogue",
            issuerName: caName,
            issuerKey: caKey,
            trustBundlePEM: [caPEM]
        )

        agentSVID = try makeSVID(
            commonName: "test-agent",
            spiffePath: "/agent/test-agent",
            issuerName: caName,
            issuerKey: caKey,
            trustBundlePEM: [caPEM]
        )

        // Claims the control plane's SPIFFE ID but is signed by a different
        // CA. Its trust bundle is the REAL CA so the server side still
        // accepts the agent's client certificate — isolating the client-side
        // chain-walk failure.
        foreignControlPlaneSVID = try makeSVID(
            commonName: "foreign-control-plane",
            spiffePath: "/control-plane",
            issuerName: foreignCAName,
            issuerKey: foreignCAKey,
            trustBundlePEM: [caPEM]
        )
        _ = foreignCA
    }

    private static func makeCA(
        commonName: String
    ) throws -> (Certificate, Certificate.PrivateKey, DistinguishedName) {
        let key = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let name = try DistinguishedName {
            CommonName("\(commonName) \(UUID().uuidString.prefix(8))")
        }
        let ca = try Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: key.publicKey,
            notValidBefore: Date().addingTimeInterval(-3600),
            notValidAfter: Date().addingTimeInterval(86400),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                Critical(KeyUsage(keyCertSign: true))
            },
            issuerPrivateKey: key
        )
        return (ca, key, name)
    }
}
