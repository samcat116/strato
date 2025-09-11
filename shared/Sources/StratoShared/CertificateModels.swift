import Foundation

// MARK: - Certificate Authentication Models

/// Certificate Signing Request submitted by agents during enrollment
public struct CertificateSigningRequest: Codable, Sendable {
    public let publicKeyPEM: String
    public let agentId: String
    public let commonName: String
    public let agentMetadata: AgentMetadata
    
    public init(
        publicKeyPEM: String,
        agentId: String,
        commonName: String,
        agentMetadata: AgentMetadata
    ) {
        self.publicKeyPEM = publicKeyPEM
        self.agentId = agentId
        self.commonName = commonName
        self.agentMetadata = agentMetadata
    }
}

/// Metadata about the agent requesting a certificate
public struct AgentMetadata: Codable, Sendable {
    public let hostname: String
    public let platform: String // "linux", "darwin", etc.
    public let version: String
    public let capabilities: [String]
    public let tpmAvailable: Bool
    
    public init(
        hostname: String,
        platform: String,
        version: String,
        capabilities: [String],
        tpmAvailable: Bool = false
    ) {
        self.hostname = hostname
        self.platform = platform
        self.version = version
        self.capabilities = capabilities
        self.tpmAvailable = tpmAvailable
    }
}

/// Enrollment request containing JWT token and CSR
public struct AgentEnrollmentRequest: Codable, Sendable {
    public let joinToken: String // JWT token
    public let csr: CertificateSigningRequest
    
    public init(joinToken: String, csr: CertificateSigningRequest) {
        self.joinToken = joinToken
        self.csr = csr
    }
}

/// Response containing issued certificate and CA bundle
public struct AgentEnrollmentResponse: Codable, Sendable {
    public let certificatePEM: String
    public let caBundlePEM: String
    public let expiresAt: Date
    public let spiffeURI: String
    public let renewalEndpoint: String
    
    public init(
        certificatePEM: String,
        caBundlePEM: String,
        expiresAt: Date,
        spiffeURI: String,
        renewalEndpoint: String
    ) {
        self.certificatePEM = certificatePEM
        self.caBundlePEM = caBundlePEM
        self.expiresAt = expiresAt
        self.spiffeURI = spiffeURI
        self.renewalEndpoint = renewalEndpoint
    }
}

/// Certificate renewal request
public struct CertificateRenewalRequest: Codable, Sendable {
    public let csr: CertificateSigningRequest
    
    public init(csr: CertificateSigningRequest) {
        self.csr = csr
    }
}

/// SPIFFE Identity representation
public struct SPIFFEIdentity: Codable, Sendable {
    public let trustDomain: String
    public let path: String
    
    public var uri: String {
        return "spiffe://\(trustDomain)\(path)"
    }
    
    public init(trustDomain: String, path: String) {
        self.trustDomain = trustDomain
        self.path = path
    }
    
    public init(uri: String) throws {
        guard uri.hasPrefix("spiffe://") else {
            throw SPIFFEError.invalidURI("URI must start with spiffe://")
        }
        
        let withoutScheme = String(uri.dropFirst("spiffe://".count))
        let components = withoutScheme.split(separator: "/", maxSplits: 1)
        
        guard components.count >= 1 else {
            throw SPIFFEError.invalidURI("URI must contain trust domain")
        }
        
        self.trustDomain = String(components[0])
        self.path = components.count > 1 ? "/" + String(components[1]) : ""
    }
}

public enum SPIFFEError: Error, LocalizedError {
    case invalidURI(String)
    case invalidTrustDomain(String)
    case invalidPath(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidURI(let message):
            return "Invalid SPIFFE URI: \(message)"
        case .invalidTrustDomain(let message):
            return "Invalid trust domain: \(message)"
        case .invalidPath(let message):
            return "Invalid path: \(message)"
        }
    }
}

/// Certificate authority information
public struct CAInfo: Codable, Sendable {
    public let certificatePEM: String
    public let trustDomain: String
    public let validFrom: Date
    public let validTo: Date
    
    public init(
        certificatePEM: String,
        trustDomain: String,
        validFrom: Date,
        validTo: Date
    ) {
        self.certificatePEM = certificatePEM
        self.trustDomain = trustDomain
        self.validFrom = validFrom
        self.validTo = validTo
    }
}