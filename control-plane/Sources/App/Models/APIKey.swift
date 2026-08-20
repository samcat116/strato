import ControlPlanePostgres
import Crypto
import Foundation
import Vapor

/// Pure bearer-secret helpers kept outside the mutable compatibility model.
/// Native persistence receives only the digest and display prefix.
enum APIKeyCredential {
    static let lastUsedDebounceWindow: TimeInterval = 15 * 60

    static func generate() -> String {
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

    static func hash(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func lastUsedIsStale(_ lastUsedAt: Date?, now: Date = Date()) -> Bool {
        guard let lastUsedAt else { return true }
        return now.timeIntervalSince(lastUsedAt) >= lastUsedDebounceWindow
    }
}

// MARK: - String Extension for Random Generation

extension String {
    static func randomAlphanumeric(length: Int) -> String {
        let characters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<length).map { _ in characters.randomElement()! })
    }
}

// MARK: - DTOs

struct CreateAPIKeyRequest: Content, ValidatedRequestBody {
    var name: String
    /// What the key may do, in the IAM action and node vocabulary. Absent means
    /// "everything its owner can".
    let restriction: CredentialRestrictionPayload?
    let expiresInDays: Int?  // Optional expiration in days

    private enum CodingKeys: String, CodingKey {
        case name
        case restriction
        case expiresInDays
    }

    init(from decoder: any Decoder) throws {
        try decoder.rejectLegacyField(
            "scopes",
            throwing: DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "API key scopes are no longer supported")))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        restriction = try values.decodeIfPresent(CredentialRestrictionPayload.self, forKey: .restriction)
        expiresInDays = try values.decodeIfPresent(Int.self, forKey: .expiresInDays)
    }

    mutating func validate() throws {
        name = try Validate.name(name)
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

    init(apiKey: APIKeySnapshot, fullKey: String) {
        self.id = apiKey.id
        self.name = apiKey.name
        self.key = fullKey
        self.keyPrefix = apiKey.keyPrefix
        self.restriction = CredentialRestrictionPayload(
            CredentialRestriction(apiKey.restriction)
        )
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

    init(from apiKey: APIKeySnapshot) {
        self.id = apiKey.id
        self.name = apiKey.name
        self.keyPrefix = apiKey.keyPrefix
        self.restriction = CredentialRestrictionPayload(
            CredentialRestriction(apiKey.restriction)
        )
        self.isActive = apiKey.isActive
        self.expiresAt = apiKey.expiresAt
        self.lastUsedAt = apiKey.lastUsedAt
        self.createdAt = apiKey.createdAt
    }
}

struct UpdateAPIKeyRequest: Content, ValidatedRequestBody {
    var name: String?
    let restriction: CredentialRestrictionPayload?
    let isActive: Bool?

    private enum CodingKeys: String, CodingKey {
        case name
        case restriction
        case isActive
    }

    init(from decoder: any Decoder) throws {
        try decoder.rejectLegacyField(
            "scopes",
            throwing: DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "API key scopes are no longer supported")))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        restriction = try values.decodeIfPresent(CredentialRestrictionPayload.self, forKey: .restriction)
        isActive = try values.decodeIfPresent(Bool.self, forKey: .isActive)
    }

    mutating func validate() throws {
        name = try Validate.name(name)
    }
}
