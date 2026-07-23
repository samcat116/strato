import Crypto
import Fluent
import Foundation
import Vapor

/// A user-managed webhook endpoint subscribed to typed platform events
/// (issue #559): org admins register a URL plus a set of event types, and the
/// delivery sweep POSTs signed payloads for every matching event enqueued in
/// the `webhook_deliveries` outbox.
final class WebhookSubscription: Model, @unchecked Sendable {
    static let schema = "webhook_subscriptions"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "organization_id")
    var organization: Organization

    /// Optional narrowing to one project: when set, only events carrying this
    /// project id are delivered. Nil means every event in the organization.
    @OptionalParent(key: "project_id")
    var project: Project?

    @Field(key: "name")
    var name: String

    /// Target endpoint. Validated against `SSRFGuard` at create/update time
    /// and again by the delivery sweep before every POST.
    @Field(key: "url")
    var url: String

    /// JSON array of subscribed `WebhookEventType` raw values; an empty array
    /// subscribes to every event type (present and future).
    @Field(key: "event_types")
    var eventTypes: String

    /// Per-subscription HMAC signing secret. Stored encrypted at rest by
    /// `SecretsEncryptionService` (like OIDCProvider.clientSecret); the
    /// plaintext is returned exactly once, from create and rotate-secret.
    @Field(key: "signing_secret")
    var signingSecret: String

    @Field(key: "is_active")
    var isActive: Bool

    /// Why the subscription is inactive when the platform (not the user)
    /// turned it off — today only continuous delivery failure. Cleared when a
    /// user re-activates the subscription.
    @OptionalField(key: "disabled_reason")
    var disabledReason: String?

    /// Start of the current unbroken delivery-failure streak; nil after any
    /// successful delivery. The sweep auto-disables the subscription once
    /// this is older than the auto-disable window.
    @OptionalField(key: "failing_since")
    var failingSince: Date?

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
        projectID: UUID? = nil,
        name: String,
        url: String,
        eventTypes: [WebhookEventType],
        signingSecret: String,
        isActive: Bool = true,
        createdByID: UUID
    ) {
        self.id = id
        self.$organization.id = organizationID
        self.$project.id = projectID
        self.name = name
        self.url = url
        self.eventTypesArray = eventTypes
        self.signingSecret = signingSecret
        self.isActive = isActive
        self.$createdBy.id = createdByID
    }
}

extension WebhookSubscription {
    var eventTypesArray: [WebhookEventType] {
        get {
            guard let data = eventTypes.data(using: .utf8),
                let raw = try? JSONDecoder().decode([String].self, from: data)
            else {
                return []
            }
            return raw.compactMap(WebhookEventType.init(rawValue:))
        }
        set {
            let raw = newValue.map(\.rawValue)
            guard let data = try? JSONEncoder().encode(raw),
                let string = String(data: data, encoding: .utf8)
            else {
                eventTypes = "[]"
                return
            }
            eventTypes = string
        }
    }

    /// Whether this subscription wants `type` — an empty selection means all.
    func subscribes(to type: WebhookEventType) -> Bool {
        let selected = eventTypesArray
        return selected.isEmpty || selected.contains(type)
    }

    /// Generate a signing secret: whsec_[48 alphanumerics] (same construction
    /// as SSF push tokens / SCIM tokens).
    static func generateSigningSecret() -> String {
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

// MARK: - DTOs

struct CreateWebhookSubscriptionRequest: Content {
    let name: String
    let url: String
    let projectId: UUID?
    let eventTypes: [String]?
}

struct UpdateWebhookSubscriptionRequest: Content {
    let name: String?
    let url: String?
    let eventTypes: [String]?
    let isActive: Bool?
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

    init(from subscription: WebhookSubscription) {
        self.id = subscription.id
        self.organizationId = subscription.$organization.id
        self.projectId = subscription.$project.id
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
