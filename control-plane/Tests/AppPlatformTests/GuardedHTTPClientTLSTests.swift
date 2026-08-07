import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOSSL
import Testing
import Vapor
import X509

@testable import App

/// Pins the load-bearing assumption behind `GuardedHTTPClient`: overriding
/// resolution overrides *only* resolution. Every production guarded fetch that
/// carries a credential — the OIDC token exchange, a registry token realm, a
/// signed webhook — is HTTPS, and each one relies on the certificate still
/// being verified against the hostname while the connection goes to the address
/// `SSRFGuard` approved. If that were wrong, the failure is either a total
/// outage across all four subsystems or a certificate validated against an IP,
/// and the plain-HTTP tests elsewhere in the suite would stay green either way.
///
/// The origin here serves TLS on `127.0.0.1` with a certificate valid for the
/// name `localhost` and nothing else, so the two cases are separable: a request
/// to `https://localhost:<port>` must succeed (pinned to the address, verified
/// against the name), and a request to any other name pinned to the same
/// address must fail the handshake.
@Suite("Guarded HTTP Client TLS", .serialized)
struct GuardedHTTPClientTLSTests {
    /// A throwaway CA plus a server leaf for `localhost`, minted per test run.
    private struct TestPKI {
        let caPEM: String
        let leafPEM: String
        let leafKeyPEM: String

        init() throws {
            let caKey = P256.Signing.PrivateKey()
            let caPrivateKey = Certificate.PrivateKey(caKey)
            let caName = try DistinguishedName {
                CommonName("Guarded Fetch Test CA \(UUID().uuidString.prefix(8))")
            }
            let ca = try Certificate(
                version: .v3,
                serialNumber: .init(),
                publicKey: caPrivateKey.publicKey,
                notValidBefore: Date().addingTimeInterval(-3600),
                notValidAfter: Date().addingTimeInterval(3600),
                issuer: caName,
                subject: caName,
                signatureAlgorithm: .ecdsaWithSHA256,
                extensions: try Certificate.Extensions {
                    Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                    Critical(KeyUsage(keyCertSign: true))
                },
                issuerPrivateKey: caPrivateKey
            )

            let leafKey = P256.Signing.PrivateKey()
            let leaf = try Certificate(
                version: .v3,
                serialNumber: .init(),
                publicKey: Certificate.PrivateKey(leafKey).publicKey,
                notValidBefore: Date().addingTimeInterval(-60),
                notValidAfter: Date().addingTimeInterval(3600),
                issuer: caName,
                subject: try DistinguishedName { CommonName("localhost") },
                signatureAlgorithm: .ecdsaWithSHA256,
                extensions: try Certificate.Extensions {
                    Critical(BasicConstraints.notCertificateAuthority)
                    KeyUsage(digitalSignature: true, keyEncipherment: true)
                    // The whole point of the suite: this name, and no other.
                    SubjectAlternativeNames([.dnsName("localhost")])
                },
                issuerPrivateKey: caPrivateKey
            )

            caPEM = try ca.serializeAsPEM().pemString
            leafPEM = try leaf.serializeAsPEM().pemString
            leafKeyPEM = leafKey.pemRepresentation
        }
    }

    /// An HTTPS origin bound to `127.0.0.1`, and a client application holding a
    /// guarded client that trusts the test CA and pins to that address.
    private func withTLSOrigin(
        _ test: (Application, Int, NIOLockedValueBox<Int>) async throws -> Void
    ) async throws {
        let pki = try TestPKI()
        var env = Environment.testing
        env.arguments = ["vapor"]

        let origin = try await Application.make(env)
        origin.logger.logLevel = .error
        origin.http.server.configuration.tlsConfiguration = .makeServerConfiguration(
            certificateChain: [
                .certificate(try NIOSSLCertificate(bytes: Array(pki.leafPEM.utf8), format: .pem))
            ],
            privateKey: .privateKey(
                try NIOSSLPrivateKey(bytes: Array(pki.leafKeyPEM.utf8), format: .pem))
        )
        let hits = NIOLockedValueBox(0)
        origin.get("ping") { _ -> String in
            hits.withLockedValue { $0 += 1 }
            return "pong"
        }
        try await origin.server.start(address: .hostname("127.0.0.1", port: 0))

        let app = try await Application.make(env)
        app.logger.logLevel = .error
        var clientTLS = TLSConfiguration.makeClientConfiguration()
        clientTLS.trustRoots = .certificates([
            try NIOSSLCertificate(bytes: Array(pki.caPEM.utf8), format: .pem)
        ])
        app.guardedHTTPClient = GuardedHTTPClient(
            app: app, validator: { _ in ["127.0.0.1"] }, tlsConfiguration: clientTLS)

        func teardown() async {
            await origin.server.shutdown()
            try? await origin.asyncShutdown()
            try? await app.asyncShutdown()
        }

        do {
            guard let port = origin.http.server.shared.localAddress?.port else {
                Issue.record("origin server did not report a bound port")
                await teardown()
                return
            }
            try await test(app, port, hits)
        } catch {
            await teardown()
            throw error
        }
        await teardown()
    }

    private func get(_ url: String) -> ClientRequest {
        ClientRequest(
            method: .GET, url: URI(string: url), headers: [:], body: nil, timeout: .seconds(30))
    }

    /// The certificate names `localhost`; the connection goes to `127.0.0.1`
    /// because that is what the guard approved. Both have to be true at once for
    /// this to pass — a handshake verified against the pinned address would fail
    /// (no IP SAN), and an unpinned client would be resolving the name itself.
    @Test("A pinned HTTPS fetch verifies the certificate against the hostname")
    func pinnedFetchValidatesAgainstHostname() async throws {
        try await withTLSOrigin { app, port, hits in
            let response = try await app.guardedHTTPClient.send(
                self.get("https://localhost:\(port)/ping"))

            #expect(response.status == .ok)
            #expect(response.body.map { String(buffer: $0) } == "pong")
            #expect(hits.withLockedValue { $0 } == 1)
        }
    }

    /// The same address, the same trusted CA, a different name: the handshake
    /// must fail. This is what says hostname verification is still running —
    /// without it the pin would let any approved address answer for any name.
    @Test("A pinned HTTPS fetch still rejects a certificate for another name")
    func pinnedFetchRejectsMismatchedHostname() async throws {
        try await withTLSOrigin { app, port, hits in
            await #expect(throws: (any Error).self) {
                try await app.guardedHTTPClient.send(
                    self.get("https://not-localhost.test:\(port)/ping"))
            }
            #expect(hits.withLockedValue { $0 } == 0)
        }
    }
}
