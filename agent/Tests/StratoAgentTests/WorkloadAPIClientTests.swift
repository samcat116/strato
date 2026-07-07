import Crypto
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import GRPCProtobuf
import Logging
import Testing
import X509

@testable import StratoAgentSPIFFE

/// Tests for the SPIFFE Workload API client (issue #191): protobuf/DER to
/// PEM-based SVID conversion, fetching and rotation-watching against an
/// in-process fake Workload API server over a Unix domain socket, and the
/// SVIDManager rotation flow that consumes it.
@Suite("Workload API SPIFFE Client")
struct WorkloadAPIClientTests {

    private static let testLogger = Logger(label: "test.workload-api")

    // MARK: - DER splitting

    @Test("Splits concatenated DER values")
    func splitsConcatenatedDER() throws {
        let pki = try WorkloadAPITestPKI()
        let single = [UInt8](pki.caDER)
        let doubled = single + single

        let one = try WorkloadAPIConversion.splitConcatenatedDER(single)
        #expect(one.count == 1)
        #expect(one[0] == single)

        let two = try WorkloadAPIConversion.splitConcatenatedDER(doubled)
        #expect(two.count == 2)
        #expect(two[0] == single)
        #expect(two[1] == single)

        let empty = try WorkloadAPIConversion.splitConcatenatedDER([])
        #expect(empty.isEmpty)
    }

    @Test("Rejects malformed DER")
    func rejectsMalformedDER() {
        #expect(throws: SPIFFEError.self) {
            _ = try WorkloadAPIConversion.splitConcatenatedDER([0x02, 0x01, 0x00])  // INTEGER, not SEQUENCE
        }
        #expect(throws: SPIFFEError.self) {
            _ = try WorkloadAPIConversion.splitConcatenatedDER([0x30, 0x10, 0x00])  // truncated
        }
    }

    // MARK: - Proto -> SVID conversion

    @Test("Converts an X509SVIDResponse to a PEM-based SVID")
    func convertsSVIDResponse() throws {
        let pki = try WorkloadAPITestPKI()
        let expiry = Date().addingTimeInterval(1800)
        let response = try pki.makeSVIDResponse(
            spiffeURI: "spiffe://strato.local/agent/agent-1",
            notValidAfter: expiry
        )

        let svid = try WorkloadAPIConversion.makeSVID(from: response)

        #expect(svid.spiffeID.uri == "spiffe://strato.local/agent/agent-1")
        // Chain contains leaf + CA, leaf first
        #expect(svid.certificateChain.count == 2)
        #expect(svid.certificateChain[0].hasPrefix("-----BEGIN CERTIFICATE-----"))
        #expect(svid.privateKey.hasPrefix("-----BEGIN PRIVATE KEY-----"))
        #expect(svid.trustBundle.count == 1)
        #expect(abs(svid.expiresAt.timeIntervalSince(expiry)) < 2)
        #expect(svid.hint == nil)

        // The PEM output must round-trip through a real X.509 parser
        let leaf = try Certificate(pemEncoded: svid.certificateChain[0])
        let leafExpiry = leaf.notValidAfter
        #expect(abs(leafExpiry.timeIntervalSince(expiry)) < 2)
    }

    @Test("Conversion output is accepted by NIOSSL for mTLS configuration")
    func conversionOutputBuildsTLSConfig() throws {
        let pki = try WorkloadAPITestPKI()
        let response = try pki.makeSVIDResponse(
            spiffeURI: "spiffe://strato.local/agent/agent-1",
            notValidAfter: Date().addingTimeInterval(1800)
        )
        let svid = try WorkloadAPIConversion.makeSVID(from: response)

        // Throws if NIOSSL rejects any of the generated PEM blocks
        let config = try SPIFFETLSConfig.makeClientConfiguration(svid: svid)
        #expect(config.certificateVerification == .noHostnameVerification)
    }

    @Test("Response without SVIDs raises noSVIDAvailable")
    func emptyResponseThrows() {
        let response = Workload_X509SVIDResponse()
        #expect(throws: SPIFFEError.self) {
            _ = try WorkloadAPIConversion.makeSVID(from: response)
        }
    }

    @Test("Converts an X509BundlesResponse keyed by trust domain")
    func convertsBundlesResponse() throws {
        let pki = try WorkloadAPITestPKI()
        var response = Workload_X509BundlesResponse()
        response.bundles = ["spiffe://strato.local": pki.caDER]

        let bundles = try WorkloadAPIConversion.makeTrustBundles(from: response)
        let bundle = try #require(bundles["spiffe://strato.local"])
        #expect(bundle.trustDomain == "strato.local")
        #expect(bundle.x509Authorities.count == 1)
        #expect(bundle.x509Authorities[0].hasPrefix("-----BEGIN CERTIFICATE-----"))
    }

    // MARK: - Against a fake Workload API server

    @Test("Fetches the initial SVID over a Unix domain socket", .timeLimit(.minutes(1)))
    func fetchesInitialSVID() async throws {
        let pki = try WorkloadAPITestPKI()
        let expiry = Date().addingTimeInterval(1800)
        let response = try pki.makeSVIDResponse(
            spiffeURI: "spiffe://strato.local/agent/agent-1",
            notValidAfter: expiry
        )

        try await withFakeWorkloadAPI(responses: [response]) { socketPath in
            let client = WorkloadAPISPIFFEClient(socketPath: socketPath, logger: Self.testLogger)
            let svid = try await client.fetchX509SVID()
            #expect(svid.spiffeID.uri == "spiffe://strato.local/agent/agent-1")
            #expect(abs(svid.expiresAt.timeIntervalSince(expiry)) < 2)
            await client.close()
        }
    }

    @Test("Watch stream delivers rotated SVIDs", .timeLimit(.minutes(1)))
    func watchDeliversRotation() async throws {
        let pki = try WorkloadAPITestPKI()
        let firstExpiry = Date().addingTimeInterval(600)
        let secondExpiry = Date().addingTimeInterval(3600)
        let responses = [
            try pki.makeSVIDResponse(
                spiffeURI: "spiffe://strato.local/agent/agent-1", notValidAfter: firstExpiry),
            try pki.makeSVIDResponse(
                spiffeURI: "spiffe://strato.local/agent/agent-1", notValidAfter: secondExpiry),
        ]

        try await withFakeWorkloadAPI(responses: responses, pauseBetween: .milliseconds(50)) { socketPath in
            let client = WorkloadAPISPIFFEClient(
                socketPath: socketPath,
                logger: Self.testLogger,
                watchRetryDelay: .milliseconds(100)
            )

            var iterator = client.watchX509SVID().makeAsyncIterator()
            let first = try #require(await iterator.next())
            let second = try #require(await iterator.next())

            #expect(abs(first.expiresAt.timeIntervalSince(firstExpiry)) < 2)
            #expect(abs(second.expiresAt.timeIntervalSince(secondExpiry)) < 2)
            await client.close()
        }
    }

    @Test("Missing socket raises workloadAPIUnavailable")
    func missingSocketThrows() async {
        let client = WorkloadAPISPIFFEClient(
            socketPath: "/tmp/strato-test-nonexistent-\(UUID().uuidString.prefix(8)).sock",
            logger: Self.testLogger
        )
        await #expect(throws: SPIFFEError.self) {
            _ = try await client.fetchX509SVID()
        }
    }

    // MARK: - SVIDManager rotation

    @Test("SVIDManager applies rotated SVIDs and notifies callbacks", .timeLimit(.minutes(1)))
    func svidManagerHandlesRotation() async throws {
        let pki = try WorkloadAPITestPKI()
        let initial = try WorkloadAPIConversion.makeSVID(
            from: pki.makeSVIDResponse(
                spiffeURI: "spiffe://strato.local/agent/agent-1",
                notValidAfter: Date().addingTimeInterval(600)))
        let rotatedExpiry = Date().addingTimeInterval(3600)
        let rotated = try WorkloadAPIConversion.makeSVID(
            from: pki.makeSVIDResponse(
                spiffeURI: "spiffe://strato.local/agent/agent-1",
                notValidAfter: rotatedExpiry))

        let mock = MockSPIFFEClient(initial: initial)
        let manager = SVIDManager(client: mock, logger: Self.testLogger)
        try await manager.start()

        let (events, eventsContinuation) = AsyncStream.makeStream(of: X509SVID.self)
        await manager.onRotation { svid in
            eventsContinuation.yield(svid)
        }

        mock.pushRotation(rotated)

        var iterator = events.makeAsyncIterator()
        let received = try #require(await iterator.next())
        #expect(abs(received.expiresAt.timeIntervalSince(rotatedExpiry)) < 2)

        // The manager's current SVID and TLS config must reflect the rotation
        let current = try await manager.getSVID()
        #expect(abs(current.expiresAt.timeIntervalSince(rotatedExpiry)) < 2)
        _ = try await manager.getTLSConfiguration()

        await manager.stop()
    }

    // MARK: - Fake server plumbing

    /// Run `body` with a fake Workload API gRPC server listening on a fresh
    /// Unix domain socket. Each FetchX509SVID call streams `responses` in order
    /// (pausing between them), mimicking SPIRE's initial-then-rotated delivery.
    private func withFakeWorkloadAPI(
        responses: [Workload_X509SVIDResponse],
        pauseBetween: Duration = .zero,
        _ body: @Sendable @escaping (String) async throws -> Void
    ) async throws {
        // Keep the path short: UDS paths have a ~104 byte limit
        let socketPath = "/tmp/strato-wl-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let transport = HTTP2ServerTransport.Posix(
            address: .unixDomainSocket(path: socketPath),
            transportSecurity: .plaintext
        )
        let service = FakeWorkloadAPIService(responses: responses, pauseBetween: pauseBetween)

        try await withGRPCServer(transport: transport, services: [service]) { _ in
            // Wait for the listener to bind before letting the client connect
            _ = try await transport.listeningAddress
            try await body(socketPath)
        }
    }
}

// MARK: - Fake Workload API service

/// Minimal SpiffeWorkloadAPI implementation: streams a fixed list of SVID
/// responses to every FetchX509SVID call.
private struct FakeWorkloadAPIService: RegistrableRPCService {
    let responses: [Workload_X509SVIDResponse]
    let pauseBetween: Duration

    func registerMethods<Transport: ServerTransport>(with router: inout RPCRouter<Transport>) {
        router.registerHandler(
            forMethod: MethodDescriptor(
                service: ServiceDescriptor(fullyQualifiedService: "SpiffeWorkloadAPI"),
                method: "FetchX509SVID"
            ),
            deserializer: ProtobufDeserializer<Workload_X509SVIDRequest>(),
            serializer: ProtobufSerializer<Workload_X509SVIDResponse>()
        ) { request, _ in
            // Per the SPIFFE spec, servers must reject calls lacking this header
            guard request.metadata["workload.spiffe.io"].contains("true") else {
                throw RPCError(code: .invalidArgument, message: "security header missing")
            }
            let responses = self.responses
            let pause = self.pauseBetween
            return StreamingServerResponse { writer in
                for (index, response) in responses.enumerated() {
                    if index > 0 {
                        try await Task.sleep(for: pause)
                    }
                    try await writer.write(response)
                }
                return [:]
            }
        }
    }
}

// MARK: - Mock SPIFFE client

/// SPIFFEClientProtocol stub with an externally driven rotation stream.
private final class MockSPIFFEClient: SPIFFEClientProtocol, Sendable {
    private let initial: X509SVID
    private let stream: AsyncStream<X509SVID>
    private let continuation: AsyncStream<X509SVID>.Continuation

    init(initial: X509SVID) {
        self.initial = initial
        (self.stream, self.continuation) = AsyncStream.makeStream(of: X509SVID.self)
    }

    func fetchX509SVID() async throws -> X509SVID { initial }

    func fetchTrustBundles() async throws -> [String: SPIFFETrustBundle] { [:] }

    nonisolated func watchX509SVID() -> AsyncStream<X509SVID> { stream }

    func close() async {}

    func pushRotation(_ svid: X509SVID) {
        continuation.yield(svid)
    }
}

// MARK: - Test PKI

/// Generates SPIRE-like SVID material: a CA and short-lived leaf certificates
/// carrying SPIFFE IDs, packaged as Workload API protobuf responses (DER).
private struct WorkloadAPITestPKI {
    let caDER: Data
    private let caPrivateKey: Certificate.PrivateKey
    private let caName: DistinguishedName

    init() throws {
        caPrivateKey = Certificate.PrivateKey(P256.Signing.PrivateKey())
        caName = try DistinguishedName {
            CommonName("Test SPIRE CA \(UUID().uuidString.prefix(8))")
        }
        let caCertificate = try Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: caPrivateKey.publicKey,
            notValidBefore: Date().addingTimeInterval(-3600),
            notValidAfter: Date().addingTimeInterval(86400),
            issuer: caName,
            subject: caName,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                Critical(KeyUsage(keyCertSign: true))
            },
            issuerPrivateKey: caPrivateKey
        )
        caDER = try Self.derData(from: caCertificate)
    }

    /// Build a complete Workload API response for one SVID: leaf + CA chain,
    /// PKCS#8 key, and the CA as trust bundle.
    func makeSVIDResponse(
        spiffeURI: String,
        notValidAfter: Date
    ) throws -> Workload_X509SVIDResponse {
        let leafKey = P256.Signing.PrivateKey()
        let leaf = try Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: Certificate.PrivateKey(leafKey).publicKey,
            notValidBefore: Date().addingTimeInterval(-60),
            notValidAfter: notValidAfter,
            issuer: caName,
            subject: try DistinguishedName {
                CommonName("test-workload")
            },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                KeyUsage(digitalSignature: true)
                SubjectAlternativeNames([.uniformResourceIdentifier(spiffeURI)])
            },
            issuerPrivateKey: caPrivateKey
        )

        var svid = Workload_X509SVID()
        svid.spiffeID = spiffeURI
        svid.x509Svid = try Self.derData(from: leaf) + caDER
        svid.x509SvidKey = leafKey.derRepresentation
        svid.bundle = caDER

        var response = Workload_X509SVIDResponse()
        response.svids = [svid]
        return response
    }

    /// DER bytes of a certificate, obtained by stripping its PEM envelope
    /// (avoids a direct SwiftASN1 dependency in this test target).
    private static func derData(from certificate: Certificate) throws -> Data {
        let pem = try certificate.serializeAsPEM().pemString
        let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body) else {
            throw SPIFFEError.parseError("Failed to decode test certificate PEM")
        }
        return der
    }
}
