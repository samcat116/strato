import Logging
import NIOCore
import NIOSSL
import X509

/// Verifies that a TLS peer is one specific SPIFFE workload, not merely a
/// member of the trust domain.
///
/// SPIFFE SVIDs carry a `spiffe://` URI SAN and no DNS name, so hostname
/// verification cannot apply — and chaining to the trust domain's CA alone is
/// not enough either: every workload in the domain holds a bundle-signed SVID,
/// so a DNS/routing compromise could put any of them in front of the
/// connection. Callers pin the peer's expected SPIFFE ID and install this
/// verifier as the connection's custom verification callback, which
/// chain-verifies the presented certificates against the trust bundle and then
/// requires that exact URI SAN on the leaf.
///
/// Used by the control plane's SPIRE server admin client (pinning
/// `spiffe://<td>/spire/server`) and by the agent's control-plane WebSocket
/// (pinning the configured control-plane SPIFFE ID) — see issue #552.
public enum SPIFFEPeerVerifier {
    /// Replacement peer-certificate verification for SPIFFE mTLS connections:
    /// chain-verify the presented certificates against the trust bundle and
    /// require the leaf to carry exactly the pinned SPIFFE ID as a URI SAN.
    /// Runs instead of BoringSSL's verification (NIOSSL custom callbacks
    /// replace it entirely), which is why the chain walk is done here with
    /// swift-certificates.
    ///
    /// - Parameters:
    ///   - presented: The certificate chain the peer presented, leaf first.
    ///   - roots: The SPIFFE trust bundle to chain-verify against.
    ///   - expectedSPIFFEID: The exact `spiffe://` URI the leaf must carry.
    ///   - peerDescription: Who the peer is supposed to be ("SPIRE server",
    ///     "control plane"), for log messages.
    ///   - logger: Where rejections are logged (with the reason).
    ///   - promise: The promise the TLS handshake is waiting on.
    public static func verifyPeerChain(
        _ presented: [NIOSSLCertificate],
        roots: [Certificate],
        expectedSPIFFEID: String,
        peerDescription: String,
        logger: Logger,
        promise: EventLoopPromise<NIOSSLVerificationResultWithMetadata>
    ) {
        let fail: (String) -> Void = { reason in
            logger.warning(
                "Rejected \(peerDescription) certificate",
                metadata: ["reason": .string(reason)])
            promise.succeed(.failed)
        }

        let leaf: Certificate
        let intermediates: [Certificate]
        do {
            let chain = try presented.map { try Certificate(derEncoded: $0.toDERBytes()) }
            guard let first = chain.first else {
                fail("peer presented no certificate")
                return
            }
            leaf = first
            intermediates = Array(chain.dropFirst())
        } catch {
            fail("failed to parse presented certificate chain: \(error)")
            return
        }

        // The identity check is what stops any other bundle-signed workload
        // from impersonating the peer.
        let uriSANs =
            (try? leaf.extensions.subjectAlternativeNames)?
            .flatMap { names in
                names.compactMap { name -> String? in
                    if case .uniformResourceIdentifier(let uri) = name { return uri }
                    return nil
                }
            } ?? []
        guard uriSANs.contains(expectedSPIFFEID) else {
            fail("leaf SPIFFE ID \(uriSANs) does not match pinned \(expectedSPIFFEID)")
            return
        }

        // Chain verification is async (swift-certificates); bridge it onto
        // the promise the TLS handshake is waiting on.
        Task {
            var verifier = Verifier(rootCertificates: CertificateStore(roots)) {
                RFC5280Policy()
            }
            let result = await verifier.validate(
                leaf: leaf, intermediates: CertificateStore(intermediates))
            switch result {
            case .validCertificate:
                promise.succeed(.certificateVerified(VerificationMetadata(nil)))
            case .couldNotValidate(let failures):
                fail("certificate does not chain to the trust bundle: \(failures)")
            }
        }
    }
}
