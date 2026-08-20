import ControlPlanePostgres
import Foundation
import Vapor

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

    init(from delivery: WebhookDeliverySnapshot) {
        self.id = delivery.id
        self.subscriptionId = delivery.subscriptionID
        self.eventId = delivery.eventID
        self.eventType = delivery.eventType
        self.status = delivery.status.rawValue
        self.attempts = delivery.attempts
        self.nextAttemptAt = delivery.status == .pending ? delivery.nextAttemptAt : nil
        self.lastAttemptAt = delivery.lastAttemptAt
        self.responseStatus = delivery.responseStatus
        self.lastError = delivery.lastError
        self.deliveredAt = delivery.deliveredAt
        self.createdAt = delivery.createdAt
        self.payload = delivery.payload
    }
}
