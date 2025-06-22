import Fluent
import Vapor
import Foundation
import Crypto

final class APIKey: Model {
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
    var keyPrefix: String // First 8 characters for identification
    
    @Field(key: "scopes")
    var scopes: [String] // Permissions/scopes for this key
    
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
        scopes: [String] = ["read", "write"],
        isActive: Bool = true,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.$user.id = userID
        self.name = name
        self.keyHash = keyHash
        self.keyPrefix = keyPrefix
        self.scopes = scopes
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
    
    func updateLastUsed(ip: String?) async throws {
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
}

extension APIKey: Content {}

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
    let scopes: [String]?
    let expiresInDays: Int? // Optional expiration in days
}

struct CreateAPIKeyResponse: Content {
    let id: UUID?
    let name: String
    let key: String // Full key - only shown once
    let keyPrefix: String
    let scopes: [String]
    let expiresAt: Date?
    let createdAt: Date?
    
    init(apiKey: APIKey, fullKey: String) {
        self.id = apiKey.id
        self.name = apiKey.name
        self.key = fullKey
        self.keyPrefix = apiKey.keyPrefix
        self.scopes = apiKey.scopes
        self.expiresAt = apiKey.expiresAt
        self.createdAt = apiKey.createdAt
    }
}

struct APIKeyResponse: Content {
    let id: UUID?
    let name: String
    let keyPrefix: String
    let scopes: [String]
    let isActive: Bool
    let expiresAt: Date?
    let lastUsedAt: Date?
    let createdAt: Date?
    
    init(from apiKey: APIKey) {
        self.id = apiKey.id
        self.name = apiKey.name
        self.keyPrefix = apiKey.keyPrefix
        self.scopes = apiKey.scopes
        self.isActive = apiKey.isActive
        self.expiresAt = apiKey.expiresAt
        self.lastUsedAt = apiKey.lastUsedAt
        self.createdAt = apiKey.createdAt
    }
}

struct UpdateAPIKeyRequest: Content {
    let name: String?
    let scopes: [String]?
    let isActive: Bool?
}