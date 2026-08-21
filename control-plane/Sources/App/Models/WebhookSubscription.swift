import Crypto
import ControlPlanePostgres
import Foundation
import Vapor

enum WebhookSigningSecret {
    /// Generate a signing secret: whsec_[48 alphanumerics] (same construction
    /// as SSF push tokens / SCIM tokens).
    static func generate() -> String {
        let randomBytes = SymmetricKey(size: .bits256)
        let keyData = randomBytes.withUnsafeBytes { Data($0) }
        let keyString = keyData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "=", with: "")
            .prefix(48)
        return "whsec_\(keyString)"
    }
}

extension WebhookSubscriptionSnapshot {
    var eventTypesArray: [WebhookEventType] {
        guard let data = eventTypesJSON.data(using: .utf8),
            let raw = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return raw.compactMap(WebhookEventType.init(rawValue:))
    }

    func subscribes(to type: WebhookEventType) -> Bool {
        let selected = eventTypesArray
        return selected.isEmpty || selected.contains(type)
    }
}

func webhookEventTypesJSON(_ eventTypes: [WebhookEventType]) throws -> String {
    let data = try JSONEncoder().encode(eventTypes.map(\.rawValue))
    guard let value = String(data: data, encoding: .utf8) else {
        throw Abort(.internalServerError, reason: "Could not encode webhook event types")
    }
    return value
}

// MARK: - DTOs

struct CreateWebhookSubscriptionRequest: Content, ValidatedRequestBody {
    var name: String
    let url: String
    let projectId: UUID?
    let eventTypes: [String]?

    mutating func validate() throws {
        name = try Validate.name(name)
    }
}

struct UpdateWebhookSubscriptionRequest: Content, ValidatedRequestBody {
    var name: String?
    let url: String?
    let eventTypes: [String]?
    let isActive: Bool?

    mutating func validate() throws {
        name = try Validate.name(name)
    }
}

struct WebhookSubscriptionResponse: Content {
    let id: UUID?
    let organizationId: UUID
    let projectId: UUID?
    let name: String
    let url: String
    let eventTypes: [String]
    let isActive: Bool
    let disabledReason: String?
    let failingSince: Date?
    let createdAt: Date?
    let updatedAt: Date?

    init(from subscription: WebhookSubscriptionSnapshot) {
        self.id = subscription.id
        self.organizationId = subscription.organizationID
        self.projectId = subscription.projectID
        self.name = subscription.name
        self.url = subscription.url
        self.eventTypes = subscription.eventTypesArray.map(\.rawValue)
        self.isActive = subscription.isActive
        self.disabledReason = subscription.disabledReason
        self.failingSince = subscription.failingSince
        self.createdAt = subscription.createdAt
        self.updatedAt = subscription.updatedAt
    }
}

/// Create and rotate-secret responses: the only two places the plaintext
/// signing secret ever appears.
struct WebhookSubscriptionWithSecretResponse: Content {
    let subscription: WebhookSubscriptionResponse
    let signingSecret: String
}
