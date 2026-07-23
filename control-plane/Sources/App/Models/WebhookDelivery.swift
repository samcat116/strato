import Fluent
import Foundation
import Vapor

enum WebhookDeliveryStatus: String, Codable, Sendable {
    /// Waiting for the delivery sweep (first attempt or a retry).
    case pending
    /// The endpoint answered 2xx.
    case succeeded
    /// Every attempt failed; only a manual redeliver revives it.
    case dead
}

/// One pending or attempted webhook POST: the transactional-outbox row of
/// issue #559. Enqueued in the same transaction as the state change that
/// produced the event (one row per matching subscription), drained by the
/// delivery sweep, retried with exponential backoff, and kept afterwards as
/// the per-subscription delivery history.
final class WebhookDelivery: Model, @unchecked Sendable {
    static let schema = "webhook_deliveries"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "subscription_id")
    var subscription: WebhookSubscription

    /// Shared across the fan-out of one event to many subscriptions;
    /// consumers dedupe on it (delivery is at-least-once).
    @Field(key: "event_id")
    var eventID: UUID

    @Field(key: "event_type")
    var eventType: String

    /// The exact JSON body to POST, frozen at enqueue time.
    @Field(key: "payload")
    var payload: String

    @Field(key: "status")
    var status: String

    @Field(key: "attempts")
    var attempts: Int

    @Field(key: "next_attempt_at")
    var nextAttemptAt: Date

    @OptionalField(key: "last_attempt_at")
    var lastAttemptAt: Date?

    /// HTTP status of the last attempt, when the endpoint answered at all.
    @OptionalField(key: "response_status")
    var responseStatus: Int?

    @OptionalField(key: "last_error")
    var lastError: String?

    @OptionalField(key: "delivered_at")
    var deliveredAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        subscriptionID: UUID,
        eventID: UUID,
        eventType: WebhookEventType,
        payload: String,
        nextAttemptAt: Date = Date()
    ) {
        self.id = id
        self.$subscription.id = subscriptionID
        self.eventID = eventID
        self.eventType = eventType.rawValue
        self.payload = payload
        self.status = WebhookDeliveryStatus.pending.rawValue
        self.attempts = 0
        self.nextAttemptAt = nextAttemptAt
    }
}

extension WebhookDelivery {
    var statusValue: WebhookDeliveryStatus? {
        WebhookDeliveryStatus(rawValue: status)
    }
}

// MARK: - DTOs

struct WebhookDeliveryResponse: Content {
    let id: UUID?
    let subscriptionId: UUID
    let eventId: UUID
    let eventType: String
    let status: String
    let attempts: Int
    let nextAttemptAt: Date?
    let lastAttemptAt: Date?
    let responseStatus: Int?
    let lastError: String?
    let deliveredAt: Date?
    let createdAt: Date?
    let payload: String

    init(from delivery: WebhookDelivery) {
        self.id = delivery.id
        self.subscriptionId = delivery.$subscription.id
        self.eventId = delivery.eventID
        self.eventType = delivery.eventType
        self.status = delivery.status
        self.attempts = delivery.attempts
        // A terminal delivery has no next attempt; hide the stale timestamp.
        self.nextAttemptAt = delivery.statusValue == .pending ? delivery.nextAttemptAt : nil
        self.lastAttemptAt = delivery.lastAttemptAt
        self.responseStatus = delivery.responseStatus
        self.lastError = delivery.lastError
        self.deliveredAt = delivery.deliveredAt
        self.createdAt = delivery.createdAt
        self.payload = delivery.payload
    }
}
