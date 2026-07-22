import Fluent
import Foundation
import Vapor

/// An agent that has authenticated over the mTLS sidecar: its identity (trust
/// domain + name), and the organization its trust domain resolves to.
///
/// `organizationID` is nil for the platform trust domain — where every agent
/// lives until per-org trust domains are switched on. It is a registry lookup
/// that scopes a Cedar principal, never an authorization claim in itself
/// (`docs/architecture/iam.md`, issue #491).
struct AuthenticatedAgent: Sendable {
    let identity: AgentIdentity
    let organizationID: UUID?

    /// The agent's name within its trust domain. Safe for display and for the
    /// register response; **not** a key — use `identity.key` for that.
    var name: String { identity.name }
}

/// Authenticates a request as a Strato agent from the `X-Forwarded-Client-Cert`
/// (XFCC) header injected by the Envoy mTLS sidecar.
///
/// Shared by every HTTP surface agents reach through the sidecar — the agent
/// WebSocket upgrade and the image/artifact download route (issue #493) — so
/// the trust rules stay identical everywhere: the header is only accepted from
/// the pod-local loopback peer, the asserted identity is re-verified against
/// the SPIRE trust bundle when the certificate is forwarded, and the identity
/// must be an agent SVID in the configured trust domain.
enum AgentMTLSAuthenticator {
    /// Whether the request carries a forwarded client certificate at all.
    /// Envoy's mTLS listener always sets the header (`SANITIZE_SET` with
    /// `require_client_certificate`), so its presence is what distinguishes an
    /// agent request from one arriving over the ordinary HTTP listener.
    static func hasClientCertificate(_ req: Request) -> Bool {
        req.headers.contains(name: "X-Forwarded-Client-Cert")
    }

    /// Whether the request arrived over the pod-local loopback interface, i.e. from
    /// the co-located Envoy sidecar that terminates mTLS, rather than directly over
    /// the pod network. Envoy forwards to the control plane on 127.0.0.1, so only
    /// loopback peers may be trusted to have passed through certificate verification.
    static func requestArrivedViaLocalSidecar(_ req: Request) -> Bool {
        guard let ip = req.remoteAddress?.ipAddress else { return false }
        return ip == "127.0.0.1" || ip == "::1" || ip == "::ffff:127.0.0.1"
    }

    /// Extract the client's SPIFFE ID from the X-Forwarded-Client-Cert header and,
    /// when Envoy also forwarded the certificate itself (`Cert=`/`Chain=`),
    /// independently re-verify that certificate against the SPIRE trust bundle and
    /// require its SAN URI to match the `URI=` field. This means a compromised or
    /// misconfigured proxy cannot assert an identity it does not hold a
    /// SPIRE-issued certificate for. Returns nil (after logging why) on any failure.
    ///
    /// The returned organization is the one the certificate's trust domain
    /// belongs to, or nil for the platform trust domain. When no bundle is
    /// available to verify against, the org is resolved from the claimed
    /// domain alone — Envoy has already verified the certificate in that case.
    static func extractVerifiedSPIFFEID(
        req: Request, spireService: SPIREService
    ) async -> (identity: SPIFFEIdentity, organizationID: UUID?)? {
        guard let xfcc = req.headers.first(name: "X-Forwarded-Client-Cert") else {
            return nil
        }

        guard let element = XFCCElement.parseNearestHop(header: xfcc) else {
            req.logger.warning("XFCC header present but unparseable", metadata: ["xfcc": .string(xfcc)])
            return nil
        }

        guard let uriString = element.uri, let claimedID = SPIFFEIdentity(uri: uriString) else {
            req.logger.warning("XFCC header present but no valid SPIFFE URI found", metadata: ["xfcc": .string(xfcc)])
            return nil
        }

        // Chain= includes the leaf (leaf first); Cert= is the leaf alone.
        if let certificatePEM = element.chainPEM ?? element.certPEM {
            guard await spireService.hasTrustBundle else {
                // No bundle to verify against: accept Envoy's verification alone,
                // as before cert forwarding was enabled. Deployments that configure
                // a trust bundle get the stronger check automatically.
                req.logger.warning(
                    "XFCC forwarded a client certificate but no SPIRE trust bundle is configured; relying on Envoy's verification only"
                )
                return (claimedID, await spireService.organization(forTrustDomain: claimedID.trustDomain))
            }

            do {
                let verified = try await spireService.validateCertificate(certificatePEM)
                guard verified.identity == claimedID else {
                    req.logger.error(
                        "XFCC URI does not match the SAN URI of the forwarded client certificate",
                        metadata: [
                            "claimed": .string(claimedID.uri),
                            "verified": .string(verified.identity.uri),
                        ])
                    return nil
                }
                req.logger.debug(
                    "Extracted SPIFFE ID from XFCC", metadata: ["spiffeID": .string(claimedID.uri)])
                return (claimedID, verified.organizationID)
            } catch {
                req.logger.error(
                    "Forwarded client certificate failed verification against the SPIRE trust bundle: \(error)",
                    metadata: ["claimed": .string(claimedID.uri)])
                return nil
            }
        }

        req.logger.debug("Extracted SPIFFE ID from XFCC", metadata: ["spiffeID": .string(claimedID.uri)])
        return (claimedID, await spireService.organization(forTrustDomain: claimedID.trustDomain))
    }

    /// The full HTTP-flavored authentication path: loopback provenance check,
    /// XFCC extraction and re-verification, then agent-identity validation.
    /// Returns the authenticated agent's identity and resolved organization;
    /// throws an `Abort` suitable for returning from an HTTP route on any
    /// failure. WebSocket callers compose the granular pieces above instead,
    /// because their failures are reported as close codes rather than HTTP
    /// statuses.
    static func authenticateAgent(req: Request) async throws -> AuthenticatedAgent {
        guard let spireService = req.application.spireService, await spireService.isEnabled else {
            req.logger.error(
                "Refusing agent mTLS request: agent authentication requires SPIRE, which is not configured")
            throw Abort(
                .serviceUnavailable,
                reason: "Agent authentication requires SPIRE, which is not configured on this control plane")
        }

        guard requestArrivedViaLocalSidecar(req) else {
            req.logger.warning(
                "Rejecting X-Forwarded-Client-Cert from non-loopback peer (possible mTLS spoofing)",
                metadata: [
                    "remoteAddress": .string(req.remoteAddress?.ipAddress ?? "unknown")
                ])
            throw Abort(.forbidden, reason: "Client certificate header not accepted from this source")
        }

        guard let verified = await extractVerifiedSPIFFEID(req: req, spireService: spireService) else {
            // extractVerifiedSPIFFEID already logged the specific failure
            throw Abort(.unauthorized, reason: "Invalid client certificate identity")
        }

        do {
            _ = try await spireService.validateAgentIdentity(verified.identity)
        } catch {
            req.logger.error("SPIFFE ID validation failed: \(error)")
            throw Abort(.forbidden, reason: "SPIFFE identity validation failed")
        }

        guard let identity = verified.identity.agentIdentity else {
            throw Abort(.forbidden, reason: "SPIFFE identity validation failed")
        }
        // The workload registry is authoritative for the *mapping* (issue
        // #491): a URI registered to a different principal is rejected even
        // with a valid agent path, and a first-seen identity is registered.
        try await WorkloadRegistry.requireAgentRegistration(identity: identity, on: req.db)
        return AuthenticatedAgent(identity: identity, organizationID: verified.organizationID)
    }
}
