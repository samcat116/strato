import Crypto
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import GRPCProtobuf
import Logging
import SwiftProtobuf
import Testing
import X509

@testable import SPIREServerAPI

/// Tests for the mTLS admin path to the SPIRE server's TCP endpoint: the
/// client fetches its own SVID from a fake SPIFFE Workload API on a Unix
/// socket, then dials a fake SPIRE server over TLS that requires a client
/// certificate chained to the test CA — the Kubernetes topology, where the
/// admin API is only reachable with an admin SVID.
@Suite("SPIRE Server API Client mTLS Tests")
struct SPIREServerAPIClientMTLSTests {

    private static let testLogger = Logger(label: "test.spire-server-api-mtls")

    // MARK: - Workload API response conversion

    @Test("Converts a Workload API SVID response into identity materials")
    func convertsSVIDResponse() throws {
        let pki = try MTLSTestPKI()
        let identity = try WorkloadAPISVIDSource.makeIdentity(from: pki.workloadResponse())

        #expect(identity.spiffeID == "spiffe://strato.local/control-plane")
        // Chain is leaf + CA (concatenated DER split into two certificates).
        #expect(identity.certificateChainPEM.count == 2)
        #expect(identity.trustBundlePEM.count == 1)
        #expect(identity.privateKeyPEM.hasPrefix("-----BEGIN PRIVATE KEY-----"))
        // Expiry comes from the leaf, not the (longer-lived) CA.
        #expect(abs(identity.expiresAt.timeIntervalSince(pki.leafNotValidAfter)) < 1)

        let leaf = try Certificate(pemEncoded: identity.certificateChainPEM[0])
        #expect(leaf.notValidAfter == identity.expiresAt)
    }

    @Test("Rejects a Workload API response with no SVIDs")
    func rejectsEmptySVIDResponse() {
        #expect(throws: SPIREServerAPIError.self) {
            _ = try WorkloadAPISVIDSource.makeIdentity(from: Workload_X509SVIDResponse())
        }
    }

    @Test("Splits concatenated DER values and rejects malformed buffers")
    func splitsConcatenatedDER() throws {
        let pki = try MTLSTestPKI()
        let concatenated = pki.leafDER + pki.caDER
        let split = try WorkloadAPISVIDSource.splitConcatenatedDER(concatenated)
        #expect(split.count == 2)
        #expect(split[0] == pki.leafDER)
        #expect(split[1] == pki.caDER)

        #expect(throws: SPIREServerAPIError.self) {
            _ = try WorkloadAPISVIDSource.splitConcatenatedDER([0x31, 0x01, 0x00])
        }
        #expect(throws: SPIREServerAPIError.self) {
            _ = try WorkloadAPISVIDSource.splitConcatenatedDER(Array(pki.leafDER.dropLast()))
        }
    }

    // MARK: - mTLS round trip

    @Test("Lists entries over mTLS with an SVID from the Workload API", .timeLimit(.minutes(1)))
    func listsEntriesOverMTLS() async throws {
        let pki = try MTLSTestPKI()
        let workloadState = FakeWorkloadAPIState(response: pki.workloadResponse())

        try await withFakeWorkloadAPI(state: workloadState) { workloadSocketPath in
            try await withTLSFakeSPIREServer(pki: pki) { port in
                // "localhost", not 127.0.0.1: the gRPC TLS transport uses the
                // target host as the SNI hostname and NIOSSL rejects IP
                // literals there (real deployments dial a DNS Service name).
                let client = SPIREServerAPIClient(
                    address: .tcp(host: "localhost", port: port),
                    transportSecurity: .mtls(
                        identityProvider: WorkloadAPISVIDSource(
                            socketPath: workloadSocketPath, logger: Self.testLogger)),
                    logger: Self.testLogger,
                    timeout: .seconds(10)
                )

                let entries = try await client.listEntries()
                #expect(entries.map(\.id) == ["entry-1"])

                // A second call reuses the cached SVID: the freshly issued
                // one-hour SVID is nowhere near its half-life.
                _ = try await client.listEntries()
                let fetchCount = await workloadState.fetchCount
                let sawSecurityHeader = await workloadState.sawSecurityHeader
                #expect(fetchCount == 1)
                #expect(sawSecurityHeader)
            }
        }
    }

    @Test("Rejects a bundle-signed server that is not spiffe://<td>/spire/server", .timeLimit(.minutes(1)))
    func rejectsImpersonatingServer() async throws {
        // A rogue workload holds a perfectly valid bundle-signed SVID; only
        // the pinned server SPIFFE ID stops it from impersonating the SPIRE
        // server to the admin client.
        let pki = try MTLSTestPKI()
        let workloadState = FakeWorkloadAPIState(response: pki.workloadResponse())

        try await withFakeWorkloadAPI(state: workloadState) { workloadSocketPath in
            try await withTLSFakeSPIREServer(
                pki: pki, serverCertDER: pki.rogueServerDER, serverKey: pki.rogueServerKey
            ) { port in
                let client = SPIREServerAPIClient(
                    address: .tcp(host: "localhost", port: port),
                    transportSecurity: .mtls(
                        identityProvider: WorkloadAPISVIDSource(
                            socketPath: workloadSocketPath, logger: Self.testLogger)),
                    logger: Self.testLogger,
                    timeout: .seconds(5)
                )
                await #expect(throws: SPIREServerAPIError.self) {
                    _ = try await client.listEntries()
                }
            }
        }
    }

    @Test("Derives the pinned server ID from the client's trust domain")
    func derivesServerSPIFFEID() throws {
        let serverID = try SPIREServerAPIClient.spireServerSPIFFEID(
            fromMemberID: "spiffe://strato.local/control-plane")
        #expect(serverID == "spiffe://strato.local/spire/server")
    }

    @Test("Plaintext against the TLS endpoint fails as unreachable", .timeLimit(.minutes(1)))
    func plaintextAgainstTLSEndpointFails() async throws {
        // The exact misconfiguration from issue #507: a plaintext client
        // pointed at SPIRE's TLS endpoint dies at the HTTP/2 preface.
        let pki = try MTLSTestPKI()
        try await withTLSFakeSPIREServer(pki: pki) { port in
            let client = SPIREServerAPIClient(
                address: .tcp(host: "127.0.0.1", port: port),
                logger: Self.testLogger,
                timeout: .seconds(5)
            )
            await #expect(throws: SPIREServerAPIError.self) {
                _ = try await client.listEntries()
            }
        }
    }

    @Test("A missing Workload API socket surfaces as workload identity unavailable")
    func missingWorkloadSocket() async throws {
        let source = WorkloadAPISVIDSource(
            socketPath: "/tmp/strato-wl-nonexistent.sock", logger: Self.testLogger)
        do {
            _ = try await source.currentIdentity()
            Issue.record("expected workloadIdentityUnavailable")
        } catch let error as SPIREServerAPIError {
            guard case .workloadIdentityUnavailable = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        }
    }

    // MARK: - Fake server plumbing

    /// Run `body` with the path of a Unix socket serving a fake SPIFFE
    /// Workload API backed by `state`.
    private func withFakeWorkloadAPI(
        state: FakeWorkloadAPIState,
        _ body: @Sendable @escaping (String) async throws -> Void
    ) async throws {
        // Keep the path short: UDS paths have a ~104 byte limit
        let socketPath = "/tmp/strato-wl-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let transport = HTTP2ServerTransport.Posix(
            address: .unixDomainSocket(path: socketPath),
            transportSecurity: .plaintext
        )
        let service = FakeWorkloadAPIService(state: state)

        try await withGRPCServer(transport: transport, services: [service]) { _ in
            _ = try await transport.listeningAddress
            try await body(socketPath)
        }
    }

    /// Run `body` with the loopback port of a fake SPIRE server that serves
    /// ListEntries over TLS and requires a client certificate chained to the
    /// test CA — like a real SPIRE server's network endpoint. Pass explicit
    /// certificate material to impersonate the server with a non-server SVID.
    private func withTLSFakeSPIREServer(
        pki: MTLSTestPKI,
        serverCertDER: [UInt8]? = nil,
        serverKey: P256.Signing.PrivateKey? = nil,
        _ body: @Sendable @escaping (Int) async throws -> Void
    ) async throws {
        let certDER = serverCertDER ?? pki.serverDER
        let key = serverKey ?? pki.serverKey
        let transport = HTTP2ServerTransport.Posix(
            address: .ipv4(host: "127.0.0.1", port: 0),
            transportSecurity: .tls(
                .mTLS(
                    certificateChain: [
                        .bytes(
                            Array(
                                WorkloadAPISVIDSource.pemEncode(
                                    der: Data(certDER), label: "CERTIFICATE"
                                ).utf8), format: .pem)
                    ],
                    privateKey: .bytes(Array(key.pemRepresentation.utf8), format: .pem)
                ) { config in
                    config.trustRoots = .certificates([
                        .bytes(
                            Array(
                                WorkloadAPISVIDSource.pemEncode(
                                    der: Data(pki.caDER), label: "CERTIFICATE"
                                ).utf8), format: .pem)
                    ])
                })
        )
        let service = FakeEntryListService()

        try await withGRPCServer(transport: transport, services: [service]) { _ in
            let address = try await transport.listeningAddress
            let port = try #require(address.ipv4?.port)
            try await body(port)
        }
    }
}

// MARK: - Test PKI

/// A miniature SPIRE-shaped PKI: one CA, a server certificate for the SPIRE
/// server's TLS endpoint, and a client SVID for the control plane — plus the
/// DER encodings the Workload API would deliver.
private struct MTLSTestPKI {
    let caDER: [UInt8]
    let serverDER: [UInt8]
    let serverKey: P256.Signing.PrivateKey
    let rogueServerDER: [UInt8]
    let rogueServerKey: P256.Signing.PrivateKey
    let leafDER: [UInt8]
    let leafKey: P256.Signing.PrivateKey
    let leafNotValidAfter: Date

    init() throws {
        let caKey = P256.Signing.PrivateKey()
        let caPrivateKey = Certificate.PrivateKey(caKey)
        let caName = try DistinguishedName {
            CommonName("Test SPIRE CA \(UUID().uuidString.prefix(8))")
        }
        let ca = try Certificate(
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
        caDER = try ca.serializeAsPEM().derBytes

        func issueLeaf(
            commonName: String, spiffeURI: String, key: P256.Signing.PrivateKey, notValidAfter: Date
        ) throws -> Certificate {
            try Certificate(
                version: .v3,
                serialNumber: .init(),
                publicKey: Certificate.PrivateKey(key).publicKey,
                notValidBefore: Date().addingTimeInterval(-60),
                notValidAfter: notValidAfter,
                issuer: caName,
                subject: try DistinguishedName { CommonName(commonName) },
                signatureAlgorithm: .ecdsaWithSHA256,
                extensions: try Certificate.Extensions {
                    Critical(BasicConstraints.notCertificateAuthority)
                    KeyUsage(digitalSignature: true)
                    SubjectAlternativeNames([.uniformResourceIdentifier(spiffeURI)])
                },
                issuerPrivateKey: caPrivateKey
            )
        }

        serverKey = P256.Signing.PrivateKey()
        let server = try issueLeaf(
            commonName: "spire-server",
            spiffeURI: "spiffe://strato.local/spire/server",
            key: serverKey,
            notValidAfter: Date().addingTimeInterval(3600)
        )
        serverDER = try server.serializeAsPEM().derBytes

        // A bundle-signed workload SVID that is NOT the SPIRE server: chain
        // verification alone would accept it as a TLS server certificate.
        rogueServerKey = P256.Signing.PrivateKey()
        let rogue = try issueLeaf(
            commonName: "rogue-workload",
            spiffeURI: "spiffe://strato.local/agent/rogue",
            key: rogueServerKey,
            notValidAfter: Date().addingTimeInterval(3600)
        )
        rogueServerDER = try rogue.serializeAsPEM().derBytes

        leafKey = P256.Signing.PrivateKey()
        leafNotValidAfter = Date().addingTimeInterval(3600)
        let leaf = try issueLeaf(
            commonName: "control-plane",
            spiffeURI: "spiffe://strato.local/control-plane",
            key: leafKey,
            notValidAfter: leafNotValidAfter
        )
        leafDER = try leaf.serializeAsPEM().derBytes
    }

    /// The X509SVIDResponse a SPIRE agent would deliver for the control
    /// plane: leaf+CA chain and PKCS#8 key as concatenated DER.
    func workloadResponse() -> Workload_X509SVIDResponse {
        var svid = Workload_X509SVID()
        svid.spiffeID = "spiffe://strato.local/control-plane"
        svid.x509Svid = Data(leafDER + caDER)
        svid.x509SvidKey = leafKey.derRepresentation
        svid.bundle = Data(caDER)

        var response = Workload_X509SVIDResponse()
        response.svids = [svid]
        return response
    }
}

// MARK: - Fake Workload API service

private actor FakeWorkloadAPIState {
    let response: Workload_X509SVIDResponse
    private(set) var fetchCount = 0
    private(set) var sawSecurityHeader = false

    init(response: Workload_X509SVIDResponse) {
        self.response = response
    }

    func recordFetch(securityHeader: Bool) {
        fetchCount += 1
        sawSecurityHeader = securityHeader
    }
}

/// Minimal SPIFFE Workload API serving a canned FetchX509SVID response.
private struct FakeWorkloadAPIService: RegistrableRPCService {
    let state: FakeWorkloadAPIState

    func registerMethods<Transport: ServerTransport>(with router: inout RPCRouter<Transport>) {
        router.registerHandler(
            forMethod: MethodDescriptor(
                service: ServiceDescriptor(fullyQualifiedService: "SpiffeWorkloadAPI"),
                method: "FetchX509SVID"
            ),
            deserializer: ProtobufDeserializer<Workload_X509SVIDRequest>(),
            serializer: ProtobufSerializer<Workload_X509SVIDResponse>()
        ) { request, _ in
            let hasHeader = request.metadata[stringValues: "workload.spiffe.io"]
                .contains("true")
            await self.state.recordFetch(securityHeader: hasHeader)
            let response = await self.state.response
            return StreamingServerResponse { writer in
                try await writer.write(response)
                return [:]
            }
        }
    }
}

// MARK: - Fake SPIRE entry service

/// Minimal SPIRE server Entry API returning a single fixed entry.
private struct FakeEntryListService: RegistrableRPCService {
    func registerMethods<Transport: ServerTransport>(with router: inout RPCRouter<Transport>) {
        router.registerHandler(
            forMethod: MethodDescriptor(
                service: ServiceDescriptor(fullyQualifiedService: "spire.api.server.entry.v1.Entry"),
                method: "ListEntries"
            ),
            deserializer: ProtobufDeserializer<Spire_Api_Server_Entry_V1_ListEntriesRequest>(),
            serializer: ProtobufSerializer<Spire_Api_Server_Entry_V1_ListEntriesResponse>()
        ) { _, _ in
            let response: Spire_Api_Server_Entry_V1_ListEntriesResponse = {
                var entry = Spire_Api_Types_Entry()
                entry.id = "entry-1"
                var response = Spire_Api_Server_Entry_V1_ListEntriesResponse()
                response.entries = [entry]
                return response
            }()
            return StreamingServerResponse { writer in
                try await writer.write(response)
                return [:]
            }
        }
    }
}
