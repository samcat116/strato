import Foundation
import AsyncHTTPClient
import Crypto
import NIOFoundationCompat
import Logging

/// Client for fetching and managing JSON Web Key Sets (JWKS)
public actor JWKSClient {
    private let httpClient: HTTPClient
    private let logger = Logger(label: "SwiftSSF.JWKSClient")
    private var keyCache: [String: JWKSet] = [:]
    private let cacheTimeout: TimeInterval = 3600 // 1 hour
    
    public init(httpClient: HTTPClient) {
        self.httpClient = httpClient
    }
    
    /// Fetch JWKS from a URL
    public func fetchJWKS(from url: URL) async throws -> JWKSet {
        let cacheKey = url.absoluteString
        
        // Check cache first
        if let cached = keyCache[cacheKey] {
            if Date().timeIntervalSince(cached.fetchedAt) < cacheTimeout {
                logger.debug("Using cached JWKS for \(url)")
                return cached
            }
        }
        
        logger.info("Fetching JWKS from \(url)")
        
        let request = HTTPClientRequest(url: url.absoluteString)
        let response = try await httpClient.execute(request, timeout: .seconds(30))
        
        guard response.status == .ok else {
            throw SSFError.httpError(statusCode: Int(response.status.code), message: "Failed to fetch JWKS")
        }
        
        let body = try await response.body.collect(upTo: 1024 * 1024) // 1MB limit
        let jwks = try JSONDecoder().decode(JWKSet.self, from: Data(buffer: body))
        
        // Cache the result
        let cachedJWKS = JWKSet(keys: jwks.keys, fetchedAt: Date())
        keyCache[cacheKey] = cachedJWKS
        
        logger.debug("Successfully fetched and cached JWKS with \(jwks.keys.count) keys")
        return cachedJWKS
    }
    
    /// Get a public key for a specific key ID
    public func getPublicKey(jwks: JWKSet, keyId: String) throws -> P256.Signing.PublicKey {
        guard let jwk = jwks.keys.first(where: { $0.kid == keyId }) else {
            throw SSFError.signatureVerificationFailed
        }
        
        return try jwk.toPublicKey()
    }
    
    /// Clear the key cache
    public func clearCache() {
        keyCache.removeAll()
    }
}

/// JSON Web Key Set
public struct JWKSet: Codable, Sendable {
    public let keys: [JWK]
    public let fetchedAt: Date
    
    public init(keys: [JWK], fetchedAt: Date = Date()) {
        self.keys = keys
        self.fetchedAt = fetchedAt
    }
    
    enum CodingKeys: String, CodingKey {
        case keys
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.keys = try container.decode([JWK].self, forKey: .keys)
        self.fetchedAt = Date()
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keys, forKey: .keys)
    }
}

/// JSON Web Key
public struct JWK: Codable, Sendable {
    /// Key type (e.g., "EC", "RSA")
    public let kty: String
    
    /// Algorithm (e.g., "ES256")
    public let alg: String?
    
    /// Key usage (e.g., "sig")
    public let use: String?
    
    /// Key ID
    public let kid: String?
    
    /// Curve for EC keys
    public let crv: String?
    
    /// X coordinate for EC keys (base64url encoded)
    public let x: String?
    
    /// Y coordinate for EC keys (base64url encoded)
    public let y: String?
    
    /// RSA modulus (base64url encoded)
    public let n: String?
    
    /// RSA exponent (base64url encoded)
    public let e: String?
    
    public init(
        kty: String,
        alg: String? = nil,
        use: String? = nil,
        kid: String? = nil,
        crv: String? = nil,
        x: String? = nil,
        y: String? = nil,
        n: String? = nil,
        e: String? = nil
    ) {
        self.kty = kty
        self.alg = alg
        self.use = use
        self.kid = kid
        self.crv = crv
        self.x = x
        self.y = y
        self.n = n
        self.e = e
    }
    
    /// Convert JWK to a public key
    public func toPublicKey() throws -> P256.Signing.PublicKey {
        guard kty == "EC", crv == "P-256" else {
            throw SSFError.signatureVerificationFailed
        }
        
        guard let xString = x, let yString = y,
              let xData = Data(base64URLEncoded: xString),
              let yData = Data(base64URLEncoded: yString) else {
            throw SSFError.signatureVerificationFailed
        }
        
        // Create uncompressed point representation (0x04 + x + y)
        var keyData = Data([0x04])
        keyData.append(xData)
        keyData.append(yData)
        
        return try P256.Signing.PublicKey(x963Representation: keyData)
    }
}