import ControlPlanePostgres
import Crypto
import Foundation
import Vapor

/// Pure credential helpers kept at the HTTP boundary. Stored SCIM credentials
/// are immutable snapshots owned by `SCIMTokensPersistence`.
enum SCIMTokenCredential {
    static let lastUsedDebounceWindow: TimeInterval = 15 * 60

    static func generateToken() -> String {
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
        String(token.prefix(20))
    }
}

// MARK: - DTOs

struct CreateSCIMTokenRequest: Content, ValidatedRequestBody {
    var name: String
    let expiresInDays: Int?

    mutating func validate() throws {
        name = try Validate.name(name)
    }
}

struct CreateSCIMTokenResponse: Content {
    let id: UUID?
    let name: String
    let token: String
    let tokenPrefix: String
    let organizationId: UUID
    let expiresAt: Date?
    let createdAt: Date?

    init(scimToken: SCIMTokenSnapshot, fullToken: String) {
        self.id = scimToken.id
        self.name = scimToken.name
        self.token = fullToken
        self.tokenPrefix = scimToken.tokenPrefix
        self.organizationId = scimToken.organizationID
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

    init(from scimToken: SCIMTokenSnapshot) {
        self.id = scimToken.id
        self.name = scimToken.name
        self.tokenPrefix = scimToken.tokenPrefix
        self.organizationId = scimToken.organizationID
        self.isActive = scimToken.isActive
        self.expiresAt = scimToken.expiresAt
        self.lastUsedAt = scimToken.lastUsedAt
        self.createdAt = scimToken.createdAt
    }
}

struct UpdateSCIMTokenRequest: Content, ValidatedRequestBody {
    var name: String?
    let isActive: Bool?

    mutating func validate() throws {
        name = try Validate.name(name)
    }
}
