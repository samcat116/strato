import Foundation

// MARK: - SPIFFE Identity

/// A SPIFFE ID representing a workload identity
/// Format: spiffe://trust-domain/path
public struct SPIFFEIdentity: Sendable, Equatable, Hashable, CustomStringConvertible {
    /// The trust domain (e.g., "strato.local")
    public let trustDomain: String

    /// The path identifying the workload (e.g., "/agent/agent-1")
    public let path: String

    /// Full SPIFFE ID URI
    public var uri: String {
        "spiffe://\(trustDomain)\(path)"
    }

    public var description: String {
        uri
    }

    /// Initialize from trust domain and path
    public init(trustDomain: String, path: String) {
        self.trustDomain = trustDomain
        self.path = path.hasPrefix("/") ? path : "/\(path)"
    }

    /// Parse a SPIFFE ID from URI string
    /// - Parameter uri: The SPIFFE ID URI (e.g., "spiffe://strato.local/agent/agent-1")
    /// - Returns: Parsed SPIFFEIdentity or nil if invalid
    public init?(uri: String) {
        guard uri.hasPrefix("spiffe://") else {
            return nil
        }

        let withoutScheme = String(uri.dropFirst("spiffe://".count))

        // Find first slash after trust domain
        guard let slashIndex = withoutScheme.firstIndex(of: "/") else {
            // No path specified
            self.trustDomain = withoutScheme
            self.path = "/"
            return
        }

        self.trustDomain = String(withoutScheme[..<slashIndex])
        self.path = String(withoutScheme[slashIndex...])
    }
}

// MARK: - X.509 SVID

/// An X.509 SPIFFE Verifiable Identity Document (SVID)
/// Contains the certificate, private key, and trust bundle
public struct X509SVID: Sendable {
    /// The SPIFFE ID embedded in the certificate
    public let spiffeID: SPIFFEIdentity

    /// The X.509 certificate chain (leaf first)
    /// PEM-encoded certificates
    public let certificateChain: [String]

    /// The private key for the certificate
    /// PEM-encoded private key
    public let privateKey: String

    /// Trust bundle for validating peer certificates in this SVID's **own**
    /// trust domain. PEM-encoded CA certificates.
    public let trustBundle: [String]

    /// Roots for the foreign trust domains this SVID's registration entry
    /// federates with, keyed by bare trust domain name (`strato.local`, not
    /// `spiffe://strato.local`). PEM-encoded, as `trustBundle` is.
    ///
    /// Populated from `X509SVIDResponse.federated_bundles`. Once an agent
    /// lives in its organization's own trust domain (issue #600) the control
    /// plane is a *foreign* workload — its SVID is issued by the platform
    /// domain's CA, which `trustBundle` knows nothing about — so these are the
    /// only roots that can verify it.
    ///
    /// Deliberately kept separate from `trustBundle` rather than merged into
    /// one pile: verification always selects the roots of the peer's own trust
    /// domain (`roots(forTrustDomain:)`). A union would let any federated
    /// domain's CA vouch for a peer in any other, which is exactly the
    /// cross-tenant confusion per-org trust domains exist to prevent.
    public let federatedBundles: [String: [String]]

    /// Certificate expiration time
    public let expiresAt: Date

    /// Hint for identifying this SVID (optional)
    public let hint: String?

    public init(
        spiffeID: SPIFFEIdentity,
        certificateChain: [String],
        privateKey: String,
        trustBundle: [String],
        federatedBundles: [String: [String]] = [:],
        expiresAt: Date,
        hint: String? = nil
    ) {
        self.spiffeID = spiffeID
        self.certificateChain = certificateChain
        self.privateKey = privateKey
        self.trustBundle = trustBundle
        self.federatedBundles = federatedBundles
        self.expiresAt = expiresAt
        self.hint = hint
    }

    /// The PEM roots that may verify a peer in `trustDomain`: this SVID's own
    /// bundle for its own domain, otherwise the federated bundle for that
    /// domain.
    ///
    /// Returns nil when the domain is neither — the fail-closed case. A caller
    /// that cannot name roots for its peer must refuse the connection rather
    /// than fall back to the local bundle, which would never match a foreign
    /// peer anyway and would only turn a configuration error into an opaque
    /// handshake failure.
    public func roots(forTrustDomain trustDomain: String) -> [String]? {
        if trustDomain == spiffeID.trustDomain { return trustBundle }
        return federatedBundles[trustDomain]
    }

    /// Check if the SVID is expired
    public var isExpired: Bool {
        Date() >= expiresAt
    }

    /// Check if the SVID will expire within the given duration
    public func willExpire(within duration: TimeInterval) -> Bool {
        Date().addingTimeInterval(duration) >= expiresAt
    }

    /// Combined certificate chain as single PEM string
    public var certificateChainPEM: String {
        certificateChain.joined(separator: "\n")
    }

    /// Combined trust bundle as single PEM string
    public var trustBundlePEM: String {
        trustBundle.joined(separator: "\n")
    }
}

// MARK: - JWT SVID

/// A JWT SPIFFE Verifiable Identity Document (issue #495).
///
/// Unlike an X.509 SVID, a JWT-SVID is a bearer credential: it survives hops
/// that cannot carry a client certificate (load balancers, ingress that
/// terminates TLS), which is the whole reason it exists for programmatic
/// callers — and also why it is minted per audience and kept short-lived.
public struct JWTSVID: Sendable {
    /// The SPIFFE ID
    public let spiffeID: SPIFFEIdentity

    /// The JWT token string
    public let token: String

    /// Token expiration time
    public let expiresAt: Date

    /// Audience claims
    public let audience: [String]

    /// Hint for identifying this SVID (optional)
    public let hint: String?

    public init(
        spiffeID: SPIFFEIdentity,
        token: String,
        expiresAt: Date,
        audience: [String],
        hint: String? = nil
    ) {
        self.spiffeID = spiffeID
        self.token = token
        self.expiresAt = expiresAt
        self.audience = audience
        self.hint = hint
    }

    /// Build an SVID from a token the Workload API just issued.
    ///
    /// The response carries no expiry or audience fields, so both are read
    /// from the token's own claims — unverified, which is sound here only
    /// because the local SPIRE agent minted it (see `JWTSVIDToken`).
    ///
    /// - Parameter spiffeID: the identity the Workload API reported. It is
    ///   cross-checked against the token's `sub`: a mismatch means the agent
    ///   and the token disagree about who this is, which is never a token to
    ///   act on.
    public static func fromWorkloadAPI(
        token: String,
        spiffeID: SPIFFEIdentity,
        hint: String? = nil
    ) throws -> JWTSVID {
        let claims = try JWTSVIDToken.decodeUnverifiedClaims(token)
        guard claims.subject == spiffeID.uri else {
            throw SPIFFEError.parseError(
                "JWT-SVID subject '\(claims.subject)' does not match the reported identity '\(spiffeID.uri)'")
        }
        return JWTSVID(
            spiffeID: spiffeID,
            token: token,
            expiresAt: claims.expiresAt,
            audience: claims.audience,
            hint: hint
        )
    }

    /// Check if the token is expired
    public var isExpired: Bool {
        Date() >= expiresAt
    }

    /// Check if the token will expire within the given duration
    public func willExpire(within duration: TimeInterval) -> Bool {
        Date().addingTimeInterval(duration) >= expiresAt
    }
}

/// The result of asking the Workload API to validate a JWT-SVID.
///
/// Carries the identity the token names and the claims the agent read out of
/// it. The claims are **descriptive only**: what the identity may do is looked
/// up against the workload registry, never parsed out of the token
/// (docs/architecture/iam.md).
public struct ValidatedJWTSVID: Sendable {
    /// The SPIFFE ID of the validated token.
    public let spiffeID: SPIFFEIdentity

    /// The audience the token was validated against.
    public let audience: String

    /// The token's claims, as the Workload API reported them, flattened to
    /// their JSON-ish string forms.
    public let claims: [String: String]

    public init(spiffeID: SPIFFEIdentity, audience: String, claims: [String: String] = [:]) {
        self.spiffeID = spiffeID
        self.audience = audience
        self.claims = claims
    }
}

/// A trust domain's JWT signing keys, as the Workload API delivers them: a
/// JWKS document per trust domain.
public struct JWTBundle: Sendable {
    /// The trust domain this bundle is for.
    public let trustDomain: String

    /// The raw JWKS document (RFC 7517), as served by the Workload API.
    public let jwksJSON: Data

    public init(trustDomain: String, jwksJSON: Data) {
        self.trustDomain = trustDomain
        self.jwksJSON = jwksJSON
    }
}

// MARK: - Trust Bundle

/// A SPIFFE trust bundle for a trust domain
public struct SPIFFETrustBundle: Sendable {
    /// The trust domain this bundle is for
    public let trustDomain: String

    /// X.509 CA certificates (PEM-encoded)
    public let x509Authorities: [String]

    /// JWT signing keys (for JWT-SVID validation)
    public let jwtAuthorities: [JWTAuthority]?

    /// When this bundle was last refreshed
    public let refreshedAt: Date

    public init(
        trustDomain: String,
        x509Authorities: [String],
        jwtAuthorities: [JWTAuthority]? = nil,
        refreshedAt: Date = Date()
    ) {
        self.trustDomain = trustDomain
        self.x509Authorities = x509Authorities
        self.jwtAuthorities = jwtAuthorities
        self.refreshedAt = refreshedAt
    }

    /// Combined authorities as single PEM string
    public var x509AuthoritiesPEM: String {
        x509Authorities.joined(separator: "\n")
    }
}

/// A JWT signing key authority
public struct JWTAuthority: Sendable {
    /// Key ID
    public let keyID: String

    /// Public key (PEM or JWK)
    public let publicKey: String

    /// Expiration time (optional)
    public let expiresAt: Date?

    public init(keyID: String, publicKey: String, expiresAt: Date? = nil) {
        self.keyID = keyID
        self.publicKey = publicKey
        self.expiresAt = expiresAt
    }
}

// MARK: - Errors

/// Errors that can occur when working with SPIFFE identities
public enum SPIFFEError: Error, LocalizedError, Sendable {
    case invalidSPIFFEID(String)
    case workloadAPIUnavailable(String)
    case noSVIDAvailable
    case svidExpired
    case trustBundleUnavailable
    case connectionFailed(String)
    case attestationFailed(String)
    case parseError(String)
    /// The Workload API returned no JWT-SVID for the requested audience.
    case noJWTSVIDAvailable
    /// The Workload API rejected a JWT-SVID as invalid for the audience.
    case jwtSVIDValidationFailed(String)
    /// The SVID source cannot perform this operation (a file-based source
    /// cannot mint or validate JWT-SVIDs — only a Workload API can).
    case unsupportedOperation(String)
    /// The SVID carries no roots for a peer's trust domain: neither its own
    /// domain nor any domain it federates with. Fail-closed counterpart of
    /// `X509SVID.roots(forTrustDomain:)` returning nil.
    case noRootsForTrustDomain(peerTrustDomain: String, ownTrustDomain: String, federated: [String])

    public var errorDescription: String? {
        switch self {
        case .invalidSPIFFEID(let id):
            return "Invalid SPIFFE ID: \(id)"
        case .workloadAPIUnavailable(let reason):
            return "SPIRE Workload API unavailable: \(reason)"
        case .noSVIDAvailable:
            return "No SVID available from SPIRE"
        case .svidExpired:
            return "SVID has expired"
        case .trustBundleUnavailable:
            return "Trust bundle not available"
        case .connectionFailed(let reason):
            return "Failed to connect to SPIRE: \(reason)"
        case .attestationFailed(let reason):
            return "Workload attestation failed: \(reason)"
        case .parseError(let details):
            return "Failed to parse SPIFFE data: \(details)"
        case .noJWTSVIDAvailable:
            return "No JWT-SVID available from SPIRE for the requested audience"
        case .jwtSVIDValidationFailed(let reason):
            return "JWT-SVID validation failed: \(reason)"
        case .unsupportedOperation(let reason):
            return "Unsupported SPIFFE operation: \(reason)"
        case .noRootsForTrustDomain(let peer, let own, let federated):
            let known = federated.isEmpty ? "none" : federated.sorted().joined(separator: ", ")
            return
                "No trust roots for peer trust domain '\(peer)': this SVID is issued in '\(own)' and federates with [\(known)]. "
                + "Establish federation between the two trust domains, or correct the pinned peer identity."
        }
    }
}
