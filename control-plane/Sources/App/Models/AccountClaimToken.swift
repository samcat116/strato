import Crypto
import Fluent
import Foundation
import Vapor

/// A one-time secret an admin hands to a manually-created (`.local`) user so
/// they can enroll their own passkey. Passkeys are device-bound and can't be
/// created on someone's behalf, so an admin-created account has no credential
/// until the invitee completes the claim ceremony (`/auth/claim/*`).
///
/// Only the SHA-256 hash of the token is stored (mirroring `SCIMToken`); the
/// raw value is returned once at creation time and never again. A token is
/// single-use: `claimedAt` is stamped when consumed, and it also expires.
final class AccountClaimToken: Model, @unchecked Sendable {
    static let schema = "account_claim_tokens"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "token_hash")
    var tokenHash: String

    @Field(key: "token_prefix")
    var tokenPrefix: String

    @OptionalField(key: "expires_at")
    var expiresAt: Date?

    @OptionalField(key: "claimed_at")
    var claimedAt: Date?

    @OptionalParent(key: "created_by_id")
    var createdBy: User?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userID: UUID,
        tokenHash: String,
        tokenPrefix: String,
        expiresAt: Date?,
        createdByID: UUID?
    ) {
        self.id = id
        self.$user.id = userID
        self.tokenHash = tokenHash
        self.tokenPrefix = tokenPrefix
        self.expiresAt = expiresAt
        self.claimedAt = nil
        self.$createdBy.id = createdByID
    }

    // MARK: - Token helpers (mirrors SCIMToken)

    static func generateToken() -> String {
        let randomBytes = SymmetricKey(size: .bits256)
        let keyData = randomBytes.withUnsafeBytes { Data($0) }
        let keyString = keyData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "=", with: "")
            .prefix(48)

        return "claim_\(keyString)"
    }

    static func hashToken(_ token: String) -> String {
        let data = Data(token.utf8)
        let hashed = SHA256.hash(data: data)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }

    static func extractPrefix(_ token: String) -> String {
        return String(token.prefix(20))
    }

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() > expiresAt
    }

    /// Usable only while unclaimed and unexpired.
    var isValid: Bool {
        return claimedAt == nil && !isExpired
    }

    /// Look up a token by its raw value, eager-loading the target user.
    static func findByToken(_ token: String, on db: Database) async throws -> AccountClaimToken? {
        let hash = hashToken(token)
        return try await AccountClaimToken.query(on: db)
            .filter(\.$tokenHash == hash)
            .with(\.$user)
            .first()
    }
}

extension AccountClaimToken: Content {}
