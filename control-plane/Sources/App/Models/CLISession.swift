import ControlPlanePostgres
import Crypto
import Foundation
import Vapor

/// Secret formatting and lifetimes for CLI sessions. Durable state lives in
/// `OAuthDeviceSessionsPersistence`.
enum CLISession {
    static let accessTokenLifetime: TimeInterval = 3600
    static let refreshTokenLifetime: TimeInterval = 30 * 86400
    static let lastUsedDebounceWindow: TimeInterval = 15 * 60

    static func generateAccessToken() -> String { generateToken(prefix: "st") }
    static func generateRefreshToken() -> String { generateToken(prefix: "rt") }

    private static func generateToken(prefix: String) -> String {
        let randomBytes = SymmetricKey(size: .bits256)
        let keyData = randomBytes.withUnsafeBytes { Data($0) }
        let keyString = keyData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "=", with: "")
            .prefix(32)
        return "\(prefix)_\(String.randomAlphanumeric(length: 16))_\(keyString)"
    }

    static func hashToken(_ token: String) -> String {
        let data = Data(token.utf8)
        let hashed = SHA256.hash(data: data)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }

    static func lastUsedIsStale(_ lastUsedAt: Date?, now: Date = Date()) -> Bool {
        guard let lastUsedAt else { return true }
        return now.timeIntervalSince(lastUsedAt) >= lastUsedDebounceWindow
    }
}

/// RFC 8628 section 3.2 device authorization response.
struct DeviceAuthorizationResponse: Content {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let verificationUriComplete: String
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationUri = "verification_uri"
        case verificationUriComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
    }
}

struct TokenResponse: Content {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}

struct OAuthErrorResponse: Content {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

struct PendingDeviceAuthorizationResponse: Content {
    let userCode: String
    let clientName: String
    let restriction: CredentialRestrictionPayload
    let requestIP: String?
    let createdAt: Date?
    let expiresAt: Date
}

struct CLISessionResponse: Content {
    let id: UUID?
    let clientName: String
    let restriction: CredentialRestrictionPayload
    let accessTokenPrefix: String
    let createdAt: Date?
    let lastUsedAt: Date?
    let lastUsedIP: String?
    let refreshTokenExpiresAt: Date

    init(from session: CLISessionSnapshot) {
        self.id = session.id
        self.clientName = session.clientName
        self.restriction = CredentialRestrictionPayload(
            CredentialRestriction(session.restriction)
        )
        self.accessTokenPrefix = session.accessTokenPrefix
        self.createdAt = session.createdAt
        self.lastUsedAt = session.lastUsedAt
        self.lastUsedIP = session.lastUsedIP
        self.refreshTokenExpiresAt = session.refreshTokenExpiresAt
    }
}
