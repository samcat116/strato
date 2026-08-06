import Crypto
import Foundation
import X509

@testable import StratoAgentSPIFFE

/// Generates SPIRE-like SVID material: a CA and short-lived leaf certificates
/// carrying SPIFFE IDs, packaged as the protobuf responses of the two local
/// SPIRE agent APIs.
///
/// Shared between `WorkloadAPIClientTests` and `DelegatedIdentityClientTests`
/// precisely because the two APIs package the *same* material differently — the
/// Workload API concatenates a certificate chain into one DER blob while the
/// Delegated Identity API sends `repeated bytes`, and only a common generator
/// makes that difference visible instead of incidental.
struct SPIFFETestPKI {
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
        let material = try makeLeaf(spiffeURI: spiffeURI, notValidAfter: notValidAfter)

        var svid = Workload_X509SVID()
        svid.spiffeID = spiffeURI
        // The Workload API concatenates the chain into a single DER blob.
        svid.x509Svid = material.leafDER + caDER
        svid.x509SvidKey = material.keyDER
        svid.bundle = caDER

        var response = Workload_X509SVIDResponse()
        response.svids = [svid]
        return response
    }

    /// Build a Delegated Identity response for one SVID.
    ///
    /// Two shape differences from `makeSVIDResponse` that the delegated client
    /// must handle and the Workload API client must not: `cert_chain` is
    /// `repeated bytes` — already split, one element per certificate — and the
    /// SPIFFE ID is a `{trust_domain, path}` message rather than a URI string.
    /// There is no inline bundle at all.
    func makeDelegatedSVIDResponse(
        trustDomain: String,
        path: String,
        notValidAfter: Date,
        federatesWith: [String] = [],
        hint: String = ""
    ) throws -> Spire_Api_Agent_Delegatedidentity_V1_SubscribeToX509SVIDsResponse {
        let material = try makeLeaf(
            spiffeURI: "spiffe://\(trustDomain)\(path)", notValidAfter: notValidAfter)

        var id = Spire_Api_Types_SPIFFEID()
        id.trustDomain = trustDomain
        id.path = path

        var svid = Spire_Api_Types_X509SVID()
        svid.id = id
        svid.certChain = [material.leafDER, caDER]
        svid.expiresAt = Int64(notValidAfter.timeIntervalSince1970)
        svid.hint = hint

        var withKey = Spire_Api_Agent_Delegatedidentity_V1_X509SVIDWithKey()
        withKey.x509Svid = svid
        withKey.x509SvidKey = material.keyDER

        var response = Spire_Api_Agent_Delegatedidentity_V1_SubscribeToX509SVIDsResponse()
        response.x509Svids = [withKey]
        response.federatesWith = federatesWith
        return response
    }

    /// The delegated bundle stream, keyed the way SPIRE 1.9.6 actually keys it.
    ///
    /// `delegatedidentity.proto` says `ca_certificates` is "a map keyed by trust
    /// domain name", but the implementation writes `caCerts[td.IDString()]` —
    /// the trust domain SPIFFE ID. Set `keyByBareName` to produce the form the
    /// comment describes, so the conversion is pinned against both.
    func makeDelegatedBundlesResponse(
        trustDomains: [String],
        keyByBareName: Bool = false
    ) -> Spire_Api_Agent_Delegatedidentity_V1_SubscribeToX509BundlesResponse {
        var response = Spire_Api_Agent_Delegatedidentity_V1_SubscribeToX509BundlesResponse()
        response.caCertificates = Dictionary(
            uniqueKeysWithValues: trustDomains.map {
                (keyByBareName ? $0 : "spiffe://\($0)", caDER)
            })
        return response
    }

    // MARK: - Private

    private struct LeafMaterial {
        let leafDER: Data
        let keyDER: Data
    }

    private func makeLeaf(spiffeURI: String, notValidAfter: Date) throws -> LeafMaterial {
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
        return LeafMaterial(
            leafDER: try Self.derData(from: leaf),
            keyDER: leafKey.derRepresentation
        )
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
