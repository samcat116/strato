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

    /// Trust bundle for validating peer certificates
    /// PEM-encoded CA certificates
    public let trustBundle: [String]

    /// Certificate expiration time
    public let expiresAt: Date

    /// Hint for identifying this SVID (optional)
    public let hint: String?

    public init(
        spiffeID: SPIFFEIdentity,
        certificateChain: [String],
        privateKey: String,
        trustBundle: [String],
        expiresAt: Date,
        hint: String? = nil
    ) {
        self.spiffeID = spiffeID
        self.certificateChain = certificateChain
        self.privateKey = privateKey
        self.trustBundle = trustBundle
        self.expiresAt = expiresAt
        self.hint = hint
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

// MARK: - JWT SVID (for future use)

/// A JWT SPIFFE Verifiable Identity Document
public struct JWTSVID: Sendable {
    /// The SPIFFE ID
    public let spiffeID: SPIFFEIdentity

    /// The JWT token string
    public let token: String

    /// Token expiration time
    public let expiresAt: Date

    /// Audience claims
    public let audience: [String]

    public init(
        spiffeID: SPIFFEIdentity,
        token: String,
        expiresAt: Date,
        audience: [String]
    ) {
        self.spiffeID = spiffeID
        self.token = token
        self.expiresAt = expiresAt
        self.audience = audience
    }

    /// Check if the token is expired
    public var isExpired: Bool {
        Date() >= expiresAt
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
        }
    }
}
