import Fluent
import Vapor

// JWT-SVID request authentication (issue #495).
//
// This is the request-path authentication of service accounts and workloads
// that `docs/architecture/iam.md` listed as "still future" after the workload
// registry (#491) landed: the registry could already say what a SPIFFE ID
// names, but nothing could *present* one to the HTTP API without a client
// certificate.
//
// The chain is deliberately short and each link only narrows:
//
//   1. the token verifies against the trust domain's current JWT authorities
//      and names this control plane as its audience (`JWTSVIDAuthorityStore`);
//   2. its `sub` is looked up in `workload_registrations` — a lookup key, never
//      parsed for claims;
//   3. the row resolves to a service-account or workload principal, and every
//      authorization question from there is an ordinary Cedar check against
//      that principal's role bindings.
//
// Nothing in the token grants anything. A perfectly valid SVID for an
// unregistered identity authenticates as nobody.

/// The machine principal a request authenticated as via a JWT-SVID.
struct AuthenticatedWorkload: Sendable {
    /// The verified SPIFFE ID. Kept for audit and logging, never for access
    /// decisions.
    let spiffeID: SPIFFEIdentity

    /// What the registry says the identity names.
    let resolved: ResolvedWorkload

    /// The Cedar request principal.
    let principal: IAMPrincipal

    /// When the presented token expires. Bounds how long this authentication
    /// could have been replayed from a captured token.
    let expiresAt: Date
}

struct JWTSVIDAuthenticator {

    /// Authenticate a bearer token that looks like a JWT-SVID.
    ///
    /// Returns without authenticating when the token is not JWS-shaped or when
    /// JWT-SVID authentication is not configured — both mean "not our
    /// credential", so the other bearer authenticators get their turn. Once a
    /// token *is* established as a valid JWT-SVID, failures throw: there is no
    /// other authenticator it could belong to, and a silent fall-through would
    /// turn a precise error ("this identity is not registered") into a bare
    /// 401.
    func authenticate(bearer: BearerAuthorization, for request: Request) async throws {
        // API keys (`sk_`) and CLI access tokens (`st_`) are checked by their
        // own authenticators; neither is JWS-shaped, but guard on the shape
        // rather than on their prefixes so a new token format cannot
        // accidentally land here.
        guard JWTSVIDVerification.hasCompactJWSShape(bearer.token) else { return }
        guard let store = request.application.jwtSVIDAuthorityStore else { return }

        let verified: VerifiedJWTSVID
        do {
            verified = try await store.verify(token: bearer.token)
        } catch let error as JWTSVIDVerificationError {
            // Log the specific reason; tell the caller only that the credential
            // was not accepted. Which key rotated, or which audience the token
            // actually named, is not the presenter's business.
            request.logger.info(
                "Rejected JWT-SVID",
                metadata: ["reason": .string(error.description)])
            throw Abort(.unauthorized, reason: "JWT-SVID was not accepted")
        }

        guard let resolved = try await WorkloadRegistry.resolve(spiffeID: verified.spiffeID.uri, on: request.db)
        else {
            request.logger.info(
                "JWT-SVID names an unregistered identity",
                metadata: ["spiffeID": .string(verified.spiffeID.uri)])
            throw Abort(
                .unauthorized,
                reason: "SPIFFE identity is not registered as a workload principal")
        }

        guard let principal = resolved.principal else {
            // The registry resolved this identity to an agent. Agents
            // authenticate the transport with an X.509 SVID over mTLS and are
            // not Cedar request principals — accepting a bearer token for one
            // would create an API principal the authorization model has never
            // had, on an identity whose SVID is minted on every hypervisor node.
            request.logger.warning(
                "Refused a JWT-SVID for an agent identity",
                metadata: ["spiffeID": .string(verified.spiffeID.uri)])
            throw Abort(
                .forbidden,
                reason: "Agent identities authenticate with mTLS and cannot be used as API credentials")
        }

        request.authenticatedWorkload = AuthenticatedWorkload(
            spiffeID: verified.spiffeID,
            resolved: resolved,
            principal: principal,
            expiresAt: verified.expiresAt
        )

        request.logger.debug(
            "Authenticated a workload principal via JWT-SVID",
            metadata: [
                "spiffeID": .string(verified.spiffeID.uri),
                "principal": .string(principal.subject),
            ])
    }
}

// MARK: - Request storage

extension Request {
    private struct AuthenticatedWorkloadKey: StorageKey {
        typealias Value = AuthenticatedWorkload
    }

    /// The machine principal this request authenticated as, if any.
    var authenticatedWorkload: AuthenticatedWorkload? {
        get { storage[AuthenticatedWorkloadKey.self] }
        set { storage[AuthenticatedWorkloadKey.self] = newValue }
    }

    var isWorkloadAuthenticated: Bool { authenticatedWorkload != nil }
}
