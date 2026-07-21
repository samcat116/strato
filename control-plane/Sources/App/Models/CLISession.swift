import Crypto
import Fluent
import Foundation
import Vapor

/// A CLI login session minted by the OAuth device grant: a short-lived access
/// token plus a rotating refresh token, both stored as SHA-256 hashes.
///
/// Unlike API keys these are not user-managed secrets — the CLI obtains and
/// rotates them automatically — so they live in their own table with their own
/// Settings surface, and the access token authenticates through
/// `OAuthTokenAuthenticator` (prefix `st_`) alongside the `sk_` key path.
final class CLISession: Model, @unchecked Sendable {
    static let schema = "cli_sessions"

    /// Access tokens live one hour; the CLI refreshes transparently.
    static let accessTokenLifetime: TimeInterval = 3600
    /// Refresh tokens slide forward 30 days on every rotation.
    static let refreshTokenLifetime: TimeInterval = 30 * 86400

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "client_name")
    var clientName: String

    @Field(key: "scopes")
    var scopes: [String]

    @Field(key: "access_token_hash")
    var accessTokenHash: String

    @Field(key: "access_token_prefix")
    var accessTokenPrefix: String

    @Field(key: "access_token_expires_at")
    var accessTokenExpiresAt: Date

    @Field(key: "refresh_token_hash")
    var refreshTokenHash: String

    /// The immediately-previous refresh token hash. A presented token matching
    /// this one is a replay of an already-rotated credential — the session is
    /// revoked on the spot (OAuth security BCP refresh-token reuse detection).
    @OptionalField(key: "previous_refresh_token_hash")
    var previousRefreshTokenHash: String?

    @Field(key: "refresh_token_expires_at")
    var refreshTokenExpiresAt: Date

    @OptionalField(key: "revoked_at")
    var revokedAt: Date?

    @OptionalField(key: "last_used_at")
    var lastUsedAt: Date?

    @OptionalField(key: "last_used_ip")
    var lastUsedIP: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userID: UUID,
        clientName: String,
        scopes: [String],
        accessTokenHash: String,
        accessTokenPrefix: String,
        accessTokenExpiresAt: Date,
        refreshTokenHash: String,
        refreshTokenExpiresAt: Date
    ) {
        self.id = id
        self.$user.id = userID
        self.clientName = clientName
        self.scopes = scopes
        self.accessTokenHash = accessTokenHash
        self.accessTokenPrefix = accessTokenPrefix
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshTokenHash = refreshTokenHash
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
    }

    // MARK: - Token generation

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

    // MARK: - Validity

    var isRevoked: Bool { revokedAt != nil }

    var isAccessTokenExpired: Bool { Date() > accessTokenExpiresAt }

    var isRefreshTokenExpired: Bool { Date() > refreshTokenExpiresAt }

    // MARK: - Scopes (same semantics as APIKey)

    var grantedScopes: Set<APIKeyScope> {
        Set(scopes.compactMap(APIKeyScope.init(rawValue:)))
    }

    func grants(_ required: APIKeyScope) -> Bool {
        grantedScopes.contains { $0 >= required }
    }

    /// Issue a fresh access/refresh pair for this session, returning the raw
    /// tokens (never persisted). The old refresh hash is kept one generation
    /// for replay detection.
    func rotate() -> (accessToken: String, refreshToken: String) {
        let accessToken = Self.generateAccessToken()
        let refreshToken = Self.generateRefreshToken()
        previousRefreshTokenHash = refreshTokenHash
        accessTokenHash = Self.hashToken(accessToken)
        accessTokenPrefix = String(accessToken.prefix(12)) + "..."
        accessTokenExpiresAt = Date().addingTimeInterval(Self.accessTokenLifetime)
        refreshTokenHash = Self.hashToken(refreshToken)
        refreshTokenExpiresAt = Date().addingTimeInterval(Self.refreshTokenLifetime)
        return (accessToken, refreshToken)
    }
}

extension CLISession: Content {}

// MARK: - DTOs

/// RFC 8628 §3.2 device authorization response. Snake-case field names are
/// part of the OAuth wire format, not our JSON conventions.
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

/// RFC 6749 §5.1 token response.
struct TokenResponse: Content {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int
    let refreshToken: String
    let scope: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
    }
}

/// RFC 6749 §5.2 / RFC 8628 §3.5 error response (HTTP 400).
struct OAuthErrorResponse: Content {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

/// Details of a pending device authorization shown on the `/activate`
/// approval page.
struct PendingDeviceAuthorizationResponse: Content {
    let userCode: String
    let clientName: String
    let scopes: [String]
    let requestIP: String?
    let createdAt: Date?
    let expiresAt: Date
}

/// A CLI session as listed in Settings.
struct CLISessionResponse: Content {
    let id: UUID?
    let clientName: String
    let scopes: [String]
    let accessTokenPrefix: String
    let createdAt: Date?
    let lastUsedAt: Date?
    let lastUsedIP: String?
    let refreshTokenExpiresAt: Date

    init(from session: CLISession) {
        self.id = session.id
        self.clientName = session.clientName
        self.scopes = session.scopes
        self.accessTokenPrefix = session.accessTokenPrefix
        self.createdAt = session.createdAt
        self.lastUsedAt = session.lastUsedAt
        self.lastUsedIP = session.lastUsedIP
        self.refreshTokenExpiresAt = session.refreshTokenExpiresAt
    }
}
