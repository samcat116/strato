import Crypto
import Foundation
import Testing
import Vapor
import X509
@testable import App

/// Tests for the SPIFFE/SPIRE identity validation that underpins agent mTLS
/// authentication in `AgentWebSocketController`. These lock in the trust-domain
/// and agent-path checks a forged `X-Forwarded-Client-Cert` header must satisfy,
/// and the `requireClientCert` gate that prevents silent downgrade to token auth.
@Suite("SPIRE Service Tests")
struct SPIREServiceTests {

    private func makeService(
        trustDomain: String = "strato.local",
        requireClientCert: Bool = true
    ) -> SPIREService {
        let config = SPIREServiceConfig(
            enabled: true,
            trustDomain: trustDomain,
            requireClientCert: requireClientCert
        )
        return SPIREService(
            config: config,
            logger: Logger(label: "test.spire"),
            httpClient: NoopClient()
        )
    }

    // MARK: - SPIFFEIdentity parsing

    @Test("Parses a valid agent SPIFFE URI")
    func parsesValidAgentURI() throws {
        let id = try #require(SPIFFEIdentity(uri: "spiffe://strato.local/agent/agent-1"))
        #expect(id.trustDomain == "strato.local")
        #expect(id.path == "/agent/agent-1")
        #expect(id.isAgent)
        #expect(id.agentID == "agent-1")
    }

    @Test("Rejects non-spiffe scheme")
    func rejectsNonSpiffeScheme() {
        #expect(SPIFFEIdentity(uri: "https://strato.local/agent/agent-1") == nil)
    }

    // MARK: - validateAgentIdentity

    @Test("Accepts a well-formed agent identity in the configured trust domain")
    func acceptsValidAgentIdentity() async throws {
        let service = makeService()
        let id = try #require(SPIFFEIdentity(uri: "spiffe://strato.local/agent/agent-1"))
        let agentID = try await service.validateAgentIdentity(id)
        #expect(agentID == "agent-1")
    }

    @Test("Rejects a SPIFFE ID from a foreign trust domain")
    func rejectsForeignTrustDomain() async throws {
        let service = makeService(trustDomain: "strato.local")
        let id = try #require(SPIFFEIdentity(uri: "spiffe://evil.example/agent/agent-1"))
        await #expect(throws: SPIREServiceError.self) {
            _ = try await service.validateAgentIdentity(id)
        }
    }

    @Test("Rejects a non-agent identity even in the correct trust domain")
    func rejectsNonAgentIdentity() async throws {
        let service = makeService()
        let id = try #require(SPIFFEIdentity(uri: "spiffe://strato.local/workload/web"))
        await #expect(throws: SPIREServiceError.self) {
            _ = try await service.validateAgentIdentity(id)
        }
    }

    @Test("Rejects an agent identity with an empty agent name")
    func rejectsEmptyAgentName() async throws {
        let service = makeService()
        let id = try #require(SPIFFEIdentity(uri: "spiffe://strato.local/agent/"))
        await #expect(throws: SPIREServiceError.self) {
            _ = try await service.validateAgentIdentity(id)
        }
    }

    // MARK: - requireClientCert gate

    @Test("requireClientCert reflects configuration")
    func requireClientCertReflectsConfig() async {
        let strict = makeService(requireClientCert: true)
        #expect(await strict.requireClientCert)

        let lax = makeService(requireClientCert: false)
        #expect(await !lax.requireClientCert)
    }

    // MARK: - Certificate chain validation (validateCertificate)

    /// Build a service whose trust bundle is loaded from a real PEM file, exactly
    /// as the file-based production path does.
    private func makeServiceWithBundle(
        caPEM: String,
        trustDomain: String = "strato.local"
    ) async throws -> SPIREService {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spire-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bundlePath = dir.appendingPathComponent("bundle.pem").path
        try caPEM.write(toFile: bundlePath, atomically: true, encoding: .utf8)

        let config = SPIREServiceConfig(
            enabled: true,
            trustDomain: trustDomain,
            trustBundlePath: bundlePath
        )
        let service = SPIREService(
            config: config,
            logger: Logger(label: "test.spire"),
            httpClient: NoopClient()
        )
        try await service.start()
        return service
    }

    @Test("Validates a CA-signed SVID and extracts its SPIFFE ID")
    func validatesCASignedSVID() async throws {
        let pki = try TestPKI()
        let service = try await makeServiceWithBundle(caPEM: pki.caPEM)
        let leafPEM = try pki.issueLeafPEM(spiffeURI: "spiffe://strato.local/agent/agent-1")

        let id = try await service.validateCertificate(leafPEM)
        #expect(id.uri == "spiffe://strato.local/agent/agent-1")

        await service.stop()
    }

    @Test("Accepts a chain PEM with the leaf first")
    func acceptsLeafFirstChain() async throws {
        let pki = try TestPKI()
        let service = try await makeServiceWithBundle(caPEM: pki.caPEM)
        let leafPEM = try pki.issueLeafPEM(spiffeURI: "spiffe://strato.local/agent/agent-1")
        let chainPEM = leafPEM + "\n" + pki.caPEM

        let id = try await service.validateCertificate(chainPEM)
        #expect(id.agentID == "agent-1")

        await service.stop()
    }

    @Test("Rejects an SVID signed by a CA outside the trust bundle")
    func rejectsForeignCA() async throws {
        let trustedPKI = try TestPKI()
        let foreignPKI = try TestPKI()
        let service = try await makeServiceWithBundle(caPEM: trustedPKI.caPEM)
        let forgedPEM = try foreignPKI.issueLeafPEM(spiffeURI: "spiffe://strato.local/agent/agent-1")

        await #expect(throws: SPIREServiceError.self) {
            _ = try await service.validateCertificate(forgedPEM)
        }

        await service.stop()
    }

    @Test("Rejects an expired SVID even when correctly signed")
    func rejectsExpiredSVID() async throws {
        let pki = try TestPKI()
        let service = try await makeServiceWithBundle(caPEM: pki.caPEM)
        let expiredPEM = try pki.issueLeafPEM(
            spiffeURI: "spiffe://strato.local/agent/agent-1",
            notValidBefore: Date().addingTimeInterval(-7200),
            notValidAfter: Date().addingTimeInterval(-3600)
        )

        await #expect(throws: SPIREServiceError.self) {
            _ = try await service.validateCertificate(expiredPEM)
        }

        await service.stop()
    }

    @Test("Rejects a certificate without a SPIFFE SAN URI")
    func rejectsMissingSANURI() async throws {
        let pki = try TestPKI()
        let service = try await makeServiceWithBundle(caPEM: pki.caPEM)
        let noSANPEM = try pki.issueLeafPEM(spiffeURI: nil)

        await #expect(throws: SPIREServiceError.self) {
            _ = try await service.validateCertificate(noSANPEM)
        }

        await service.stop()
    }

    @Test("Rejects an SVID from a foreign trust domain")
    func rejectsSVIDFromForeignTrustDomain() async throws {
        let pki = try TestPKI()
        let service = try await makeServiceWithBundle(caPEM: pki.caPEM)
        let foreignPEM = try pki.issueLeafPEM(spiffeURI: "spiffe://evil.example/agent/agent-1")

        await #expect(throws: SPIREServiceError.self) {
            _ = try await service.validateCertificate(foreignPEM)
        }

        await service.stop()
    }

    @Test("Startup tolerates a missing trust bundle and picks it up on refresh")
    func lateTrustBundleIsPickedUp() async throws {
        let pki = try TestPKI()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spire-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bundlePath = dir.appendingPathComponent("bundle.pem").path

        // Kubernetes boot order: the control plane may start before SPIRE's
        // k8sbundle notifier publishes the bundle. Startup must not fail...
        let config = SPIREServiceConfig(
            enabled: true,
            trustDomain: "strato.local",
            trustBundlePath: bundlePath,
            bundleRefreshInterval: 0.05
        )
        let service = SPIREService(
            config: config,
            logger: Logger(label: "test.spire"),
            httpClient: NoopClient()
        )
        try await service.start()
        #expect(await !service.hasTrustBundle)

        // ...and the periodic refresh must load the bundle once it appears.
        try pki.caPEM.write(toFile: bundlePath, atomically: true, encoding: .utf8)
        for _ in 0..<200 {
            if await service.hasTrustBundle { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await service.hasTrustBundle)

        let leafPEM = try pki.issueLeafPEM(spiffeURI: "spiffe://strato.local/agent/agent-1")
        let id = try await service.validateCertificate(leafPEM)
        #expect(id.agentID == "agent-1")

        await service.stop()
    }

    @Test("Rejects validation when no trust bundle is loaded")
    func rejectsWithoutTrustBundle() async throws {
        let pki = try TestPKI()
        let service = makeService()
        #expect(await !service.hasTrustBundle)
        let leafPEM = try pki.issueLeafPEM(spiffeURI: "spiffe://strato.local/agent/agent-1")

        await #expect(throws: SPIREServiceError.self) {
            _ = try await service.validateCertificate(leafPEM)
        }
    }
}

// MARK: - Test PKI

/// A miniature single-CA PKI mirroring what a SPIRE server issues: short-lived
/// leaf certificates carrying the workload's SPIFFE ID as a SAN URI.
struct TestPKI {
    let caCertificate: Certificate
    let caPEM: String
    private let caPrivateKey: Certificate.PrivateKey
    private let caName: DistinguishedName

    init() throws {
        caPrivateKey = Certificate.PrivateKey(P256.Signing.PrivateKey())
        caName = try DistinguishedName {
            CommonName("Test SPIRE CA \(UUID().uuidString.prefix(8))")
        }
        caCertificate = try Certificate(
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
        caPEM = try caCertificate.serializeAsPEM().pemString
    }

    /// Issue a leaf certificate signed by the test CA, optionally carrying a
    /// SPIFFE ID as its SAN URI, and return it PEM-encoded.
    func issueLeafPEM(
        spiffeURI: String?,
        notValidBefore: Date = Date().addingTimeInterval(-60),
        notValidAfter: Date = Date().addingTimeInterval(3600)
    ) throws -> String {
        let leafKey = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let subject = try DistinguishedName {
            CommonName("test-workload")
        }

        let extensions: Certificate.Extensions
        if let spiffeURI {
            extensions = try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                KeyUsage(digitalSignature: true)
                SubjectAlternativeNames([.uniformResourceIdentifier(spiffeURI)])
            }
        } else {
            extensions = try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                KeyUsage(digitalSignature: true)
            }
        }

        let leaf = try Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: leafKey.publicKey,
            notValidBefore: notValidBefore,
            notValidAfter: notValidAfter,
            issuer: caName,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: caPrivateKey
        )
        return try leaf.serializeAsPEM().pemString
    }
}

/// Minimal `Client` stand-in: the SPIRE identity-validation paths under test never
/// perform outbound requests, so this never needs to succeed.
private struct NoopClient: Client {
    var eventLoop: any EventLoop { EmbeddedEventLoop() }

    func delegating(to eventLoop: any EventLoop) -> any Client { self }

    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        eventLoop.makeFailedFuture(Abort(.notImplemented))
    }
}
