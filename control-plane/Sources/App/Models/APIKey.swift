import Fluent
import Vapor
import Foundation
import Crypto

/// Safety: this mutable Fluent model stays inside one logical operation; child tasks
/// receive IDs or immutable snapshots and reload their own instance.
final class APIKey: Model, @unchecked Sendable {
    static let schema = "api_keys"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "name")
    var name: String

    @Field(key: "key_hash")
    var keyHash: String

    @Field(key: "key_prefix")
    var keyPrefix: String  // First 8 characters for identification

    @Field(key: "restriction_actions")
    var restrictionActions: [String]

    @OptionalField(key: "restriction_node_type")
    var restrictionNodeType: String?

    @OptionalField(key: "restriction_node_id")
    var restrictionNodeID: UUID?

    @Field(key: "is_active")
    var isActive: Bool

    @OptionalField(key: "expires_at")
    var expiresAt: Date?

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
        name: String,
        keyHash: String,
        keyPrefix: String,
        restriction: CredentialRestriction = .unrestricted,
        isActive: Bool = true,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.$user.id = userID
        self.name = name
        self.keyHash = keyHash
        self.keyPrefix = keyPrefix
        self.restrictionActions = restriction.actions
        self.restrictionNodeType = restriction.node?.type.rawValue
        self.restrictionNodeID = restriction.node?.id
        self.isActive = isActive
        self.expiresAt = expiresAt
    }

    // MARK: - Static Helper Methods

    static func generateAPIKey() -> String {
        // Generate a secure random API key: sk_[16 random chars]_[32 random chars]
        let randomBytes = SymmetricKey(size: .bits256)
        let keyData = randomBytes.withUnsafeBytes { Data($0) }
        let keyString = keyData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "=", with: "")
            .prefix(32)

        let prefix = String.randomAlphanumeric(length: 16)
        return "sk_\(prefix)_\(keyString)"
    }

    static func hashAPIKey(_ key: String) -> String {
        let data = Data(key.utf8)
        let hashed = SHA256.hash(data: data)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }

    var isExpired: Bool {
        guard let expiresAt = expiresAt else { return false }
        return Date() > expiresAt
    }

    var isValid: Bool {
        return isActive && !isExpired
    }

}

extension APIKey: Content {}

extension APIKey: CredentialRestrictionStoring {}

// MARK: - String Extension for Random Generation

extension String {
    static func randomAlphanumeric(length: Int) -> String {
        let characters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<length).map { _ in characters.randomElement()! })
    }
}

// MARK: - DTOs

struct CreateAPIKeyRequest: Content {
    let name: String
    /// What the key may do, in the IAM action and node vocabulary. Absent means
    /// "everything its owner can".
    let restriction: CredentialRestrictionPayload?
    let expiresInDays: Int?  // Optional expiration in days

    private enum CodingKeys: String, CodingKey {
        case name
        case restriction
        case expiresInDays
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case scopes
    }

    init(from decoder: any Decoder) throws {
        if try decoder.container(keyedBy: LegacyCodingKeys.self).contains(.scopes) {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "API key scopes are no longer supported"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        restriction = try values.decodeIfPresent(CredentialRestrictionPayload.self, forKey: .restriction)
        expiresInDays = try values.decodeIfPresent(Int.self, forKey: .expiresInDays)
    }
}

struct CreateAPIKeyResponse: Content {
    let id: UUID?
    let name: String
    let key: String  // Full key - only shown once
    let keyPrefix: String
    let restriction: CredentialRestrictionPayload
    let expiresAt: Date?
    let createdAt: Date?

    init(apiKey: APIKey, fullKey: String) {
        self.id = apiKey.id
        self.name = apiKey.name
        self.key = fullKey
        self.keyPrefix = apiKey.keyPrefix
        self.restriction = CredentialRestrictionPayload(apiKey.restriction)
        self.expiresAt = apiKey.expiresAt
        self.createdAt = apiKey.createdAt
    }
}

struct APIKeyResponse: Content {
    let id: UUID?
    let name: String
    let keyPrefix: String
    let restriction: CredentialRestrictionPayload
    let isActive: Bool
    let expiresAt: Date?
    let lastUsedAt: Date?
    let createdAt: Date?

    init(from apiKey: APIKey) {
        self.id = apiKey.id
        self.name = apiKey.name
        self.keyPrefix = apiKey.keyPrefix
        self.restriction = CredentialRestrictionPayload(apiKey.restriction)
        self.isActive = apiKey.isActive
        self.expiresAt = apiKey.expiresAt
        self.lastUsedAt = apiKey.lastUsedAt
        self.createdAt = apiKey.createdAt
    }
}

struct UpdateAPIKeyRequest: Content {
    let name: String?
    let restriction: CredentialRestrictionPayload?
    let isActive: Bool?

    private enum CodingKeys: String, CodingKey {
        case name
        case restriction
        case isActive
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case scopes
    }

    init(from decoder: any Decoder) throws {
        if try decoder.container(keyedBy: LegacyCodingKeys.self).contains(.scopes) {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "API key scopes are no longer supported"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        restriction = try values.decodeIfPresent(CredentialRestrictionPayload.self, forKey: .restriction)
        isActive = try values.decodeIfPresent(Bool.self, forKey: .isActive)
    }
}
