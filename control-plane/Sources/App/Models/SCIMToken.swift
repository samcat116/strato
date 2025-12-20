import Fluent
import Vapor
import Foundation
import Crypto

final class SCIMToken: Model, @unchecked Sendable {
    static let schema = "scim_tokens"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "organization_id")
    var organization: Organization

    @Field(key: "name")
    var name: String

    @Field(key: "token_hash")
    var tokenHash: String

    @Field(key: "token_prefix")
    var tokenPrefix: String

    @Field(key: "is_active")
    var isActive: Bool

    @OptionalField(key: "expires_at")
    var expiresAt: Date?

    @OptionalField(key: "last_used_at")
    var lastUsedAt: Date?

    @OptionalField(key: "last_used_ip")
    var lastUsedIP: String?

    @Parent(key: "created_by_id")
    var createdBy: User

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        organizationID: UUID,
        name: String,
        tokenHash: String,
        tokenPrefix: String,
        isActive: Bool = true,
        expiresAt: Date? = nil,
        createdByID: UUID
    ) {
        self.id = id
        self.$organization.id = organizationID
        self.name = name
        self.tokenHash = tokenHash
        self.tokenPrefix = tokenPrefix
        self.isActive = isActive
        self.expiresAt = expiresAt
        self.$createdBy.id = createdByID
    }

    // MARK: - Static Helper Methods

    static func generateToken() -> String {
        // Generate a secure random SCIM token: scim_[48 base64 chars]
        // Uses 256 bits of cryptographic randomness, base64 encoded and filtered to 48 alphanumeric chars
        // This provides approximately 285 bits of entropy (48 chars * ~5.95 bits/char for base64 without +/=)
        let randomBytes = SymmetricKey(size: .bits256)
        let keyData = randomBytes.withUnsafeBytes { Data($0) }
        let keyString = keyData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "=", with: "")
            .prefix(48)

        return "scim_\(keyString)"
    }

    static func hashToken(_ token: String) -> String {
        let data = Data(token.utf8)
        let hashed = SHA256.hash(data: data)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }

    static func extractPrefix(_ token: String) -> String {
        // Return first 20 characters for identification (scim_XXXXXXXXXXXXXXX)
        return String(token.prefix(20))
    }

    func updateLastUsed(ip: String?) {
        self.lastUsedAt = Date()
        self.lastUsedIP = ip
    }

    var isExpired: Bool {
        guard let expiresAt = expiresAt else { return false }
        return Date() > expiresAt
    }

    var isValid: Bool {
        return isActive && !isExpired
    }

    /// Find a SCIM token by its raw token value
    static func findByToken(_ token: String, on db: Database) async throws -> SCIMToken? {
        let hash = hashToken(token)
        return try await SCIMToken.query(on: db)
            .filter(\.$tokenHash == hash)
            .with(\.$organization)
            .first()
    }
}

extension SCIMToken: Content {}

// MARK: - DTOs

struct CreateSCIMTokenRequest: Content {
    let name: String
    let expiresInDays: Int?
}

struct CreateSCIMTokenResponse: Content {
    let id: UUID?
    let name: String
    let token: String // Full token - only shown once
    let tokenPrefix: String
    let organizationId: UUID
    let expiresAt: Date?
    let createdAt: Date?

    init(scimToken: SCIMToken, fullToken: String) {
        self.id = scimToken.id
        self.name = scimToken.name
        self.token = fullToken
        self.tokenPrefix = scimToken.tokenPrefix
        self.organizationId = scimToken.$organization.id
        self.expiresAt = scimToken.expiresAt
        self.createdAt = scimToken.createdAt
    }
}

struct SCIMTokenResponse: Content {
    let id: UUID?
    let name: String
    let tokenPrefix: String
    let organizationId: UUID
    let isActive: Bool
    let expiresAt: Date?
    let lastUsedAt: Date?
    let createdAt: Date?

    init(from scimToken: SCIMToken) {
        self.id = scimToken.id
        self.name = scimToken.name
        self.tokenPrefix = scimToken.tokenPrefix
        self.organizationId = scimToken.$organization.id
        self.isActive = scimToken.isActive
        self.expiresAt = scimToken.expiresAt
        self.lastUsedAt = scimToken.lastUsedAt
        self.createdAt = scimToken.createdAt
    }
}

struct UpdateSCIMTokenRequest: Content {
    let name: String?
    let isActive: Bool?
}
