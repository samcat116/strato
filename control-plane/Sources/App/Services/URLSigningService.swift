import Foundation
import Vapor
import Crypto
import Fluent
import NIOConcurrencyHelpers

/// Service for signing and verifying URLs for agent image downloads
struct URLSigningService {
    /// Default URL expiration time (1 hour)
    static let defaultExpiration: TimeInterval = 3600

    /// Minimum key length for security
    static let minimumKeyLength = 32

    /// Signs an image download URL with HMAC-SHA256
    /// - Parameters:
    ///   - imageId: The image UUID
    ///   - projectId: The project UUID
    ///   - agentName: Name of the agent requesting the download
    ///   - baseURL: Base URL of the control plane (e.g., "http://localhost:8080")
    ///   - expiresIn: Time until URL expires (default: 1 hour)
    ///   - signingKey: Secret key for HMAC signing
    /// - Returns: Signed URL with query parameters
    static func signImageDownloadURL(
        imageId: UUID,
        projectId: UUID,
        agentName: String,
        baseURL: String,
        expiresIn: TimeInterval = defaultExpiration,
        signingKey: String
    ) -> String {
        let expires = Int(Date().timeIntervalSince1970 + expiresIn)
        let path = "/api/projects/\(projectId)/images/\(imageId)/download"

        // Generate signature
        let signature = generateSignature(
            path: path,
            imageId: imageId,
            projectId: projectId,
            agentName: agentName,
            expires: expires,
            signingKey: signingKey
        )

        // URL-encode the agent name
        let encodedAgentName = agentName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? agentName

        return "\(baseURL)\(path)?agent=\(encodedAgentName)&expires=\(expires)&sig=\(signature)"
    }

    /// Verifies a signed URL's signature
    /// - Parameters:
    ///   - path: The URL path (e.g., "/api/projects/{id}/images/{id}/download")
    ///   - imageId: The image UUID from the path
    ///   - projectId: The project UUID from the path
    ///   - agentName: Agent name from query parameter
    ///   - expires: Expiration timestamp from query parameter
    ///   - signature: Signature from query parameter
    ///   - signingKey: Secret key for HMAC verification
    /// - Returns: True if signature is valid and not expired
    static func verifySignature(
        path: String,
        imageId: UUID,
        projectId: UUID,
        agentName: String,
        expires: Int,
        signature: String,
        signingKey: String
    ) -> Bool {
        // Check expiration first
        guard expires > Int(Date().timeIntervalSince1970) else {
            return false
        }

        // Recompute expected signature
        let expectedSignature = generateSignature(
            path: path,
            imageId: imageId,
            projectId: projectId,
            agentName: agentName,
            expires: expires,
            signingKey: signingKey
        )

        // Constant-time comparison to prevent timing attacks
        return constantTimeCompare(signature.lowercased(), expectedSignature.lowercased())
    }

    /// Generates HMAC-SHA256 signature for the given parameters
    private static func generateSignature(
        path: String,
        imageId: UUID,
        projectId: UUID,
        agentName: String,
        expires: Int,
        signingKey: String
    ) -> String {
        // Data to sign: path:imageId:projectId:agentName:expires
        let dataToSign = "\(path):\(imageId):\(projectId):\(agentName):\(expires)"

        // Generate HMAC-SHA256
        let key = SymmetricKey(data: Data(signingKey.utf8))
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(dataToSign.utf8),
            using: key
        )

        // Convert to hex string
        return signature.map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time string comparison to prevent timing attacks
    private static func constantTimeCompare(_ a: String, _ b: String) -> Bool {
        guard a.count == b.count else { return false }

        var result: UInt8 = 0
        for (charA, charB) in zip(a.utf8, b.utf8) {
            result |= charA ^ charB
        }
        return result == 0
    }

    /// Gets the signing key, checking sources in order:
    /// 1. Environment variable (IMAGE_DOWNLOAD_SIGNING_KEY)
    /// 2. In-memory cache
    /// 3. Database (generates and stores if not found)
    /// - Parameter app: The Vapor application
    /// - Returns: The signing key
    /// - Throws: If unable to retrieve or generate the key
    static func getSigningKey(from app: Application) throws -> String {
        // 1. Check environment variable first (takes precedence)
        if let envKey = Environment.get("IMAGE_DOWNLOAD_SIGNING_KEY"), !envKey.isEmpty {
            guard envKey.count >= minimumKeyLength else {
                throw Abort(.internalServerError, reason: "IMAGE_DOWNLOAD_SIGNING_KEY must be at least \(minimumKeyLength) characters")
            }
            return envKey
        }

        // 2. Check in-memory cache
        if let cachedKey = app.signingKeyCache.key {
            return cachedKey
        }

        // 3. Need to load from database - this requires async, so we throw an error
        // The async version should be called instead
        throw Abort(.internalServerError, reason: "Signing key not initialized. Call getSigningKeyAsync during startup.")
    }

    /// Asynchronously gets or generates the signing key
    /// Call this during application startup to initialize the key
    /// - Parameter app: The Vapor application
    /// - Returns: The signing key
    static func getSigningKeyAsync(from app: Application) async throws -> String {
        // 1. Check environment variable first (takes precedence)
        if let envKey = Environment.get("IMAGE_DOWNLOAD_SIGNING_KEY"), !envKey.isEmpty {
            guard envKey.count >= minimumKeyLength else {
                throw Abort(.internalServerError, reason: "IMAGE_DOWNLOAD_SIGNING_KEY must be at least \(minimumKeyLength) characters")
            }
            app.signingKeyCache.key = envKey
            return envKey
        }

        // 2. Check in-memory cache
        if let cachedKey = app.signingKeyCache.key {
            return cachedKey
        }

        // 3. Check database
        if let setting = try await AppSetting.query(on: app.db)
            .filter(\.$key == AppSetting.imageDownloadSigningKey)
            .first() {
            app.signingKeyCache.key = setting.value
            app.logger.info("Loaded image download signing key from database")
            return setting.value
        }

        // 4. Generate new key and store in database
        let newKey = generateRandomKey()
        let setting = AppSetting(key: AppSetting.imageDownloadSigningKey, value: newKey)
        try await setting.save(on: app.db)

        app.signingKeyCache.key = newKey
        app.logger.info("Generated and stored new image download signing key")
        return newKey
    }

    /// Generates a cryptographically secure random key
    /// - Returns: 64-character hex string (256 bits)
    private static func generateRandomKey() -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in 0..<bytes.count {
            bytes[i] = UInt8.random(in: 0...255, using: &generator)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Extracts expiration date from a signed URL's expires parameter
    static func expirationDate(from expires: Int) -> Date {
        return Date(timeIntervalSince1970: TimeInterval(expires))
    }
}

// MARK: - Application Extension for Signing Key Cache

extension Application {
    /// In-memory cache for the signing key
    var signingKeyCache: SigningKeyCache {
        get {
            if let existing = storage[SigningKeyCacheKey.self] {
                return existing
            }
            let new = SigningKeyCache()
            storage[SigningKeyCacheKey.self] = new
            return new
        }
        set {
            storage[SigningKeyCacheKey.self] = newValue
        }
    }

    private struct SigningKeyCacheKey: StorageKey {
        typealias Value = SigningKeyCache
    }
}

/// Thread-safe cache for the signing key
final class SigningKeyCache: @unchecked Sendable {
    private let lock = NIOLock()
    private var _key: String?

    var key: String? {
        get { lock.withLock { _key } }
        set { lock.withLock { _key = newValue } }
    }
}
