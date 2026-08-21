import ControlPlanePostgres
import Crypto
import Foundation
import Vapor

enum SSFPushCredential {
    /// Generate an inbound push-delivery bearer token: ssf_[48 alphanumerics].
    static func generatePushToken() -> String {
        let randomBytes = SymmetricKey(size: .bits256)
        let keyData = randomBytes.withUnsafeBytes { Data($0) }
        let keyString = keyData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "=", with: "")
            .prefix(48)
        return "ssf_\(keyString)"
    }

    static func hashPushToken(_ token: String) -> String {
        let hashed = SHA256.hash(data: Data(token.utf8))
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }

    static func extractPushTokenPrefix(_ token: String) -> String {
        String(token.prefix(12))
    }

}

// MARK: - DTOs

struct CreateSSFStreamRequest: Content, ValidatedRequestBody {
    var name: String
    let description: String?
    let transmitterURL: String
    let authToken: String?
    let expectedIssuer: String?
    let expectedAudience: [String]?
    let deliveryMethod: SSFDeliveryMethod
    let eventsRequested: [String]?

    mutating func validate() throws {
        name = try Validate.name(name)
        try Validate.text(description)
        try Validate.text(expectedIssuer, "expectedIssuer")
    }
}

struct UpdateSSFStreamRequest: Content, ValidatedRequestBody {
    var name: String?
    let description: String?
    let authToken: String?
    let expectedIssuer: String?
    let expectedAudience: [String]?
    let eventsRequested: [String]?
    let enabled: Bool?

    mutating func validate() throws {
        name = try Validate.name(name)
        try Validate.text(description)
        try Validate.text(expectedIssuer, "expectedIssuer")
    }
}

struct SSFStreamResponse: Content {
    let id: UUID?
    let organizationId: UUID
    let name: String
    let description: String?
    let transmitterURL: String
    let expectedIssuer: String?
    let expectedAudience: [String]
    let deliveryMethod: String
    let eventsRequested: [String]
    let remoteStreamID: String?
    let pollEndpoint: String?
    let pushEndpoint: String?
    let pushTokenPrefix: String?
    let enabled: Bool
    let registered: Bool
    let verifiedAt: Date?
    let lastEventAt: Date?
    let lastError: String?
    let createdAt: Date?
    let updatedAt: Date?

    init(from stream: SSFStreamSnapshot, pushEndpoint: String?) {
        self.id = stream.id
        self.organizationId = stream.organizationID
        self.name = stream.name
        self.description = stream.description
        self.transmitterURL = stream.transmitterURL
        self.expectedIssuer = stream.expectedIssuer
        self.expectedAudience = stream.expectedAudience
        self.deliveryMethod = stream.deliveryMethod
        self.eventsRequested = stream.eventsRequested
        self.remoteStreamID = stream.remoteStreamID
        self.pollEndpoint = stream.pollEndpoint
        self.pushEndpoint = pushEndpoint
        self.pushTokenPrefix = stream.pushTokenPrefix
        self.enabled = stream.enabled
        self.registered = stream.isRegistered
        self.verifiedAt = stream.verifiedAt
        self.lastEventAt = stream.lastEventAt
        self.lastError = stream.lastError
        self.createdAt = stream.createdAt
        self.updatedAt = stream.updatedAt
    }
}

struct SSFStreamStatusResponse: Content {
    let remoteStreamID: String
    let status: String
    let reason: String?
}

struct SSFPollResultResponse: Content {
    let processed: Int
    let failed: Int
    let moreAvailable: Bool
}
