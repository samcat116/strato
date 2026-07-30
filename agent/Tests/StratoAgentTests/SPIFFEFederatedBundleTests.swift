import Crypto
import Foundation
import NIOSSL
import Testing
import X509

@testable import StratoAgentSPIFFE

/// Federated-bundle support on the agent (issue #615).
///
/// Once an agent is issued in its organization's own trust domain, the control
/// plane is a *foreign* workload: its SVID is signed by the platform domain's
/// CA, which the agent's own trust bundle knows nothing about. The Workload API
/// delivers the platform roots in `X509SVIDResponse.federated_bundles`, which
/// the client used to drop on the floor — so every peer verification has to
/// select roots by the peer's trust domain, and must refuse rather than guess
/// when it holds none.
@Suite("SPIFFE federated bundles")
struct SPIFFEFederatedBundleTests {

    private static let orgTrustDomain = "org-0123456789abcdef.strato.local"
    private static let platformTrustDomain = "strato.local"
    private static let controlPlaneID = "spiffe://strato.local/control-plane"

    // MARK: - Parsing

    @Test("makeSVID carries federated bundles through, keyed by bare trust domain")
    func makeSVIDParsesFederatedBundles() throws {
        let pki = try FederationTestPKI()

        var proto = Workload_X509SVID()
        proto.spiffeID = "spiffe://\(Self.orgTrustDomain)/agent/hv-01"
        proto.x509Svid = pki.agentLeafDER
        proto.x509SvidKey = pki.agentKeyDER
        proto.bundle = pki.orgCADER

        var response = Workload_X509SVIDResponse()
        response.svids = [proto]
        // Keyed by trust domain SPIFFE ID on the wire, as SPIRE sends it.
        response.federatedBundles = ["spiffe://\(Self.platformTrustDomain)": pki.platformCADER]

        let svid = try WorkloadAPIConversion.makeSVID(from: response)

        #expect(svid.spiffeID.trustDomain == Self.orgTrustDomain)
        #expect(svid.trustBundle.count == 1)
        // Normalized to the bare name so lookups key off a parsed identity.
        #expect(Array(svid.federatedBundles.keys) == [Self.platformTrustDomain])
        #expect(svid.federatedBundles[Self.platformTrustDomain]?.count == 1)

        // The two bundles must stay distinguishable — a federated root landing
        // in `trustBundle` would be the union this design exists to avoid.
        let ownRoot = try #require(svid.trustBundle.first)
        let federatedRoot = try #require(svid.federatedBundles[Self.platformTrustDomain]?.first)
        #expect(ownRoot != federatedRoot)
        #expect(ownRoot == pki.orgCAPEM)
        #expect(federatedRoot == pki.platformCAPEM)
    }

    @Test("A response with no federated bundles yields an empty map, not a failure")
    func makeSVIDWithoutFederatedBundles() throws {
        let pki = try FederationTestPKI()

        var proto = Workload_X509SVID()
        proto.spiffeID = "spiffe://\(Self.platformTrustDomain)/agent/hv-01"
        proto.x509Svid = pki.platformAgentLeafDER
        proto.x509SvidKey = pki.agentKeyDER
        proto.bundle = pki.platformCADER

        var response = Workload_X509SVIDResponse()
        response.svids = [proto]

        let svid = try WorkloadAPIConversion.makeSVID(from: response)
        #expect(svid.federatedBundles.isEmpty)
        #expect(svid.trustBundle.count == 1)
    }

    // MARK: - Root selection

    @Test("roots(forTrustDomain:) picks the SVID's own bundle for its own domain")
    func rootsForOwnDomain() throws {
        let svid = try FederationTestPKI().orgAgentSVID
        let roots = svid.roots(forTrustDomain: Self.orgTrustDomain)
        #expect(roots == svid.trustBundle)
    }

    @Test("roots(forTrustDomain:) picks the federated bundle for a federated domain")
    func rootsForFederatedDomain() throws {
        let pki = try FederationTestPKI()
        let roots = pki.orgAgentSVID.roots(forTrustDomain: Self.platformTrustDomain)
        #expect(roots == [pki.platformCAPEM])
    }

    @Test("roots(forTrustDomain:) returns nil for a domain the SVID knows nothing about")
    func rootsForUnknownDomain() throws {
        let svid = try FederationTestPKI().orgAgentSVID
        #expect(svid.roots(forTrustDomain: "org-deadbeefdeadbeef.strato.local") == nil)
    }

    // MARK: - Pinning across the federation boundary

    @Test("Pinning a cross-domain control plane verifies against the federated roots")
    func pinningSelectsFederatedRoots() throws {
        let pki = try FederationTestPKI()
        let pinning = try SPIFFEPeerPinning(
            expectedSPIFFEID: Self.controlPlaneID, svid: pki.orgAgentSVID)

        #expect(pinning.expectedSPIFFEID == Self.controlPlaneID)
        // The platform CA, not the org CA this agent's own SVID chains to.
        #expect(pinning.trustRoots.count == 1)
        let root = try #require(pinning.trustRoots.first)
        let rootPEM = try root.serializeAsPEM().pemString
        #expect(rootPEM == pki.platformCAPEM.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(rootPEM != pki.orgCAPEM.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test("Pinning in a single trust domain is unchanged")
    func pinningSameDomainUnchanged() throws {
        let pki = try FederationTestPKI()
        // The pre-#600 shape: agent and control plane both in the platform
        // domain, SVID carrying no federated bundles at all. #492's pin must
        // keep working exactly as before.
        let pinning = try SPIFFEPeerPinning(
            expectedSPIFFEID: Self.controlPlaneID, svid: pki.platformAgentSVID)
        #expect(pinning.trustRoots.count == 1)
        let rootPEM = try #require(pinning.trustRoots.first).serializeAsPEM().pemString
        #expect(rootPEM == pki.platformCAPEM.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test("Pinning fails closed when no roots exist for the pinned domain")
    func pinningFailsClosedWithoutFederation() throws {
        let pki = try FederationTestPKI()
        // An org-domain agent whose entry was provisioned without
        // `federatesWith` — the exact misconfiguration this phase has to make
        // loud. Falling back to the local bundle would only turn it into an
        // opaque handshake failure at every reconnect.
        let unfederated = X509SVID(
            spiffeID: SPIFFEIdentity(trustDomain: Self.orgTrustDomain, path: "/agent/hv-01"),
            certificateChain: pki.orgAgentSVID.certificateChain,
            privateKey: pki.orgAgentSVID.privateKey,
            trustBundle: pki.orgAgentSVID.trustBundle,
            expiresAt: pki.orgAgentSVID.expiresAt
        )

        #expect(throws: SPIFFEError.self) {
            _ = try SPIFFEPeerPinning(expectedSPIFFEID: Self.controlPlaneID, svid: unfederated)
        }
    }

    @Test("Pinning rejects a malformed pinned identity")
    func pinningRejectsMalformedID() throws {
        let svid = try FederationTestPKI().orgAgentSVID
        #expect(throws: SPIFFEError.self) {
            _ = try SPIFFEPeerPinning(expectedSPIFFEID: "not-a-spiffe-id", svid: svid)
        }
    }

    // MARK: - Client TLS configuration

    @Test("Client configuration trusts the peer domain's roots, not the SVID's own")
    func clientConfigurationUsesPeerDomainRoots() throws {
        let pki = try FederationTestPKI()

        // Unlike the WebSocket path there is no pinning callback here (the
        // artifact downloader has none), so these roots are the only check.
        let federated = try SPIFFETLSConfig.makeClientConfiguration(
            svid: pki.orgAgentSVID, peerTrustDomain: Self.platformTrustDomain)
        let expectedPlatform = try NIOSSLCertificate(bytes: [UInt8](pki.platformCAPEM.utf8), format: .pem)
        guard case .certificates(let federatedRoots) = federated.trustRoots else {
            Issue.record("expected explicit trust roots for the federated peer")
            return
        }
        #expect(federatedRoots == [expectedPlatform])

        // Omitting the peer domain keeps the pre-#600 behavior: the SVID's own.
        let own = try SPIFFETLSConfig.makeClientConfiguration(svid: pki.orgAgentSVID)
        let expectedOrg = try NIOSSLCertificate(bytes: [UInt8](pki.orgCAPEM.utf8), format: .pem)
        guard case .certificates(let ownRoots) = own.trustRoots else {
            Issue.record("expected explicit trust roots for the SVID's own domain")
            return
        }
        #expect(ownRoots == [expectedOrg])
        #expect(ownRoots != federatedRoots)
    }

    @Test("Client configuration fails closed for a peer domain it holds no roots for")
    func clientConfigurationFailsClosed() throws {
        let pki = try FederationTestPKI()
        #expect(throws: SPIFFEError.self) {
            _ = try SPIFFETLSConfig.makeClientConfiguration(
                svid: pki.orgAgentSVID, peerTrustDomain: "org-deadbeefdeadbeef.strato.local")
        }
    }

    @Test("Peer verification is skipped entirely when the caller opts out")
    func clientConfigurationWithoutVerification() throws {
        let pki = try FederationTestPKI()
        // No roots are selected at all, so an unknown peer domain must not
        // throw — there is nothing to fail closed about.
        let config = try SPIFFETLSConfig.makeClientConfiguration(
            svid: pki.orgAgentSVID, peerTrustDomain: "nowhere.example", verifyPeer: false)
        #expect(config.certificateVerification == CertificateVerification.none)
    }
}

// MARK: - Test PKI

private enum FederationTestPKIError: Error {
    case malformedPEM
}

/// Two independent CAs standing in for a platform trust domain and one
/// organization's, plus the SVIDs each issues.
private struct FederationTestPKI {
    let platformCAPEM: String
    let platformCADER: Data
    let orgCAPEM: String
    let orgCADER: Data

    /// An agent in the org domain, federated with the platform domain — what
    /// enrollment provisions once per-org trust domains are on.
    let orgAgentSVID: X509SVID
    /// An agent in the platform domain with no federation — the pre-#600 shape.
    let platformAgentSVID: X509SVID

    let agentLeafDER: Data
    let platformAgentLeafDER: Data
    let agentKeyDER: Data

    init() throws {
        let (platformCA, platformKey, platformName) = try Self.makeCA(commonName: "Platform SPIRE CA")
        let (orgCA, orgKey, orgName) = try Self.makeCA(commonName: "Org SPIRE CA")

        platformCAPEM = try platformCA.serializeAsPEM().pemString + "\n"
        orgCAPEM = try orgCA.serializeAsPEM().pemString + "\n"
        platformCADER = try Self.der(of: platformCA)
        orgCADER = try Self.der(of: orgCA)

        let agentKey = P256.Signing.PrivateKey()
        agentKeyDER = agentKey.derRepresentation

        let orgLeaf = try Self.makeLeaf(
            commonName: "hv-01",
            uri: "spiffe://org-0123456789abcdef.strato.local/agent/hv-01",
            key: agentKey, issuerName: orgName, issuerKey: orgKey)
        let platformLeaf = try Self.makeLeaf(
            commonName: "hv-01",
            uri: "spiffe://strato.local/agent/hv-01",
            key: agentKey, issuerName: platformName, issuerKey: platformKey)

        agentLeafDER = try Self.der(of: orgLeaf)
        platformAgentLeafDER = try Self.der(of: platformLeaf)

        orgAgentSVID = X509SVID(
            spiffeID: SPIFFEIdentity(
                trustDomain: "org-0123456789abcdef.strato.local", path: "/agent/hv-01"),
            certificateChain: [try orgLeaf.serializeAsPEM().pemString],
            privateKey: agentKey.pemRepresentation,
            trustBundle: [orgCAPEM],
            federatedBundles: ["strato.local": [platformCAPEM]],
            expiresAt: orgLeaf.notValidAfter
        )

        platformAgentSVID = X509SVID(
            spiffeID: SPIFFEIdentity(trustDomain: "strato.local", path: "/agent/hv-01"),
            certificateChain: [try platformLeaf.serializeAsPEM().pemString],
            privateKey: agentKey.pemRepresentation,
            trustBundle: [platformCAPEM],
            expiresAt: platformLeaf.notValidAfter
        )
    }

    /// DER bytes of a certificate, by way of its PEM form — the Workload API
    /// delivers concatenated DER, and going through PEM avoids depending on a
    /// serializer this test target does not link.
    private static func der(of certificate: Certificate) throws -> Data {
        let pem = try certificate.serializeAsPEM().pemString
        let body =
            pem
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let der = Data(base64Encoded: body) else {
            throw FederationTestPKIError.malformedPEM
        }
        return der
    }

    private static func makeCA(
        commonName: String
    ) throws -> (Certificate, Certificate.PrivateKey, DistinguishedName) {
        let key = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let name = try DistinguishedName { CommonName(commonName) }
        let certificate = try Certificate(
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
                KeyUsage(keyCertSign: true)
            },
            issuerPrivateKey: key
        )
        return (certificate, key, name)
    }

    private static func makeLeaf(
        commonName: String,
        uri: String,
        key: P256.Signing.PrivateKey,
        issuerName: DistinguishedName,
        issuerKey: Certificate.PrivateKey
    ) throws -> Certificate {
        try Certificate(
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
                SubjectAlternativeNames([.uniformResourceIdentifier(uri)])
            },
            issuerPrivateKey: issuerKey
        )
    }
}
