import ControlPlanePostgres
import Fluent
import Foundation
import SQLKit
import Vapor

/// Minimal immutable rows used by event producers that must append outbox
/// entries through the same Fluent transaction as their domain mutation.
struct LegacyWebhookSubscriptionMatch: Decodable, Sendable {
    let id: UUID
    let projectID: UUID?
    let eventTypesJSON: String

    func subscribes(to type: WebhookEventType) -> Bool {
        guard let data = eventTypesJSON.data(using: .utf8),
            let values = try? JSONDecoder().decode([String].self, from: data)
        else { return true }
        return values.isEmpty || values.contains(type.rawValue)
    }
}

enum LegacyWebhookStore {
    static func activeSubscriptions(
        organizationID: UUID,
        on db: any Database
    ) async throws -> [LegacyWebhookSubscriptionMatch] {
        try await requireSQL(db).raw(
            """
            SELECT id, project_id AS "projectID", event_types AS "eventTypesJSON"
            FROM webhook_subscriptions
            WHERE organization_id = \(bind: organizationID) AND is_active = TRUE
            ORDER BY id
            """
        ).all(decoding: LegacyWebhookSubscriptionMatch.self)
    }

    @discardableResult
    static func insertDelivery(
        id: UUID = UUID(),
        subscriptionID: UUID,
        eventID: UUID,
        eventType: WebhookEventType,
        payload: String,
        nextAttemptAt: Date = Date(),
        on db: any Database
    ) async throws -> UUID {
        struct Identifier: Decodable { let id: UUID }
        guard let row = try await requireSQL(db).raw(
            """
            INSERT INTO webhook_deliveries (
                id, subscription_id, event_id, event_type, payload, status,
                attempts, next_attempt_at, created_at, updated_at
            ) VALUES (
                \(bind: id), \(bind: subscriptionID), \(bind: eventID),
                \(bind: eventType.rawValue), \(bind: payload),
                \(bind: WebhookDeliveryStatus.pending.rawValue), 0,
                \(bind: nextAttemptAt), CURRENT_TIMESTAMP, NULL
            )
            RETURNING id
            """
        ).first(decoding: Identifier.self) else {
            throw Abort(.internalServerError, reason: "Could not enqueue webhook delivery")
        }
        return row.id
    }

    private static func requireSQL(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Webhook outbox requires PostgreSQL")
        }
        return sql
    }
}
