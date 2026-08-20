import Foundation
import Testing

@testable import ControlPlanePostgres

@Suite("Native webhook persistence", .serialized)
struct WebhookPersistenceTests {
    @Test("claim, retry, redelivery, and success preserve the outbox state machine")
    func deliveryLifecycle() async throws {
        try await withWebhookDatabase { _, subscriptions, deliveries in
            let subscription = try await makeSubscription(subscriptions)
            let delivery = try await deliveries.create(
                WebhookDeliveryWrite(
                    subscriptionID: subscription.id,
                    eventID: UUID(),
                    eventType: "webhook.test",
                    payload: "{}",
                    nextAttemptAt: Date().addingTimeInterval(-1)))

            #expect(try await deliveries.claimDue(limit: 1, leaseSeconds: 120) == [delivery.id])
            #expect(try await deliveries.claimDue(limit: 1, leaseSeconds: 120).isEmpty)

            let failed = try #require(
                try await deliveries.recordFailure(
                    id: delivery.id,
                    responseStatus: 500,
                    error: "Endpoint answered HTTP 500",
                    at: Date(),
                    maximumAttempts: 1,
                    nextAttemptAt: Date().addingTimeInterval(30)))
            #expect(failed.status == .dead)
            #expect(failed.attempts == 1)
            #expect(failed.responseStatus == 500)

            let redelivered = try #require(
                try await deliveries.redeliver(
                    id: delivery.id, subscriptionID: subscription.id))
            #expect(redelivered.status == .pending)
            #expect(redelivered.attempts == 0)
            #expect(redelivered.lastError == nil)
            #expect(
                try await deliveries.redeliver(
                    id: delivery.id, subscriptionID: subscription.id) == nil)

            let succeeded = try #require(
                try await deliveries.recordSuccess(
                    id: delivery.id, responseStatus: 204, at: Date()))
            #expect(succeeded.status == .succeeded)
            #expect(succeeded.attempts == 1)
            #expect(succeeded.responseStatus == 204)
            #expect(succeeded.deliveredAt != nil)
        }
    }

    @Test("continuous failure disables a subscription and success recovers it")
    func subscriptionFailureStreak() async throws {
        try await withWebhookDatabase { _, subscriptions, _ in
            var subscription = try await makeSubscription(subscriptions)
            let reason = "Automatically disabled after 3 day(s) of failed deliveries"
            let oldFailure = Date().addingTimeInterval(-4 * 86_400)
            subscription = try #require(
                try await subscriptions.replace(
                    WebhookSubscriptionWrite(
                        id: subscription.id,
                        organizationID: subscription.organizationID,
                        projectID: nil,
                        name: subscription.name,
                        url: subscription.url,
                        eventTypesJSON: subscription.eventTypesJSON,
                        encryptedSigningSecret: subscription.encryptedSigningSecret,
                        isActive: true,
                        disabledReason: nil,
                        failingSince: oldFailure,
                        createdByID: subscription.createdByID)))

            let disabled = try #require(
                try await subscriptions.recordDeliveryFailure(
                    id: subscription.id,
                    at: Date(),
                    disableBefore: Date().addingTimeInterval(-3 * 86_400),
                    disabledReason: reason))
            #expect(!disabled.isActive)
            #expect(disabled.disabledReason == reason)
            #expect(disabled.failingSince == oldFailure)

            let recovered = try #require(
                try await subscriptions.recordDeliverySuccess(
                    id: subscription.id, automaticDisabledReason: reason))
            #expect(recovered.isActive)
            #expect(recovered.disabledReason == nil)
            #expect(recovered.failingSince == nil)
        }
    }

    private func makeSubscription(
        _ subscriptions: WebhookSubscriptionsPersistence
    ) async throws -> WebhookSubscriptionSnapshot {
        try await subscriptions.create(
            WebhookSubscriptionWrite(
                id: UUID(),
                organizationID: UUID(),
                projectID: nil,
                name: "test hook",
                url: "https://example.com/hook",
                eventTypesJSON: "[]",
                encryptedSigningSecret: "encrypted",
                isActive: true,
                disabledReason: nil,
                failingSince: nil,
                createdByID: UUID()))
    }

    private func withWebhookDatabase(
        _ test: (
            PostgresDatabase,
            WebhookSubscriptionsPersistence,
            WebhookDeliveriesPersistence
        ) async throws -> Void
    ) async throws {
        try await withBareNativePostgresDatabase { database in
            try await database.withSession(operation: "test.webhooks.schema") { session in
                _ = try await session.command(
                    """
                    CREATE TABLE webhook_subscriptions (
                        id UUID PRIMARY KEY,
                        organization_id UUID NOT NULL,
                        project_id UUID,
                        name TEXT NOT NULL,
                        url TEXT NOT NULL,
                        event_types TEXT NOT NULL DEFAULT '[]',
                        signing_secret TEXT NOT NULL,
                        is_active BOOLEAN NOT NULL DEFAULT TRUE,
                        disabled_reason TEXT,
                        failing_since TIMESTAMPTZ,
                        created_by_id UUID NOT NULL,
                        created_at TIMESTAMPTZ,
                        updated_at TIMESTAMPTZ
                    )
                    """,
                    operation: "test.webhooks.schema.subscriptions")
                _ = try await session.command(
                    """
                    CREATE TABLE webhook_deliveries (
                        id UUID PRIMARY KEY,
                        subscription_id UUID NOT NULL REFERENCES webhook_subscriptions(id)
                            ON DELETE CASCADE,
                        event_id UUID NOT NULL,
                        event_type TEXT NOT NULL,
                        payload TEXT NOT NULL,
                        status TEXT NOT NULL DEFAULT 'pending',
                        attempts BIGINT NOT NULL DEFAULT 0,
                        next_attempt_at TIMESTAMPTZ NOT NULL,
                        last_attempt_at TIMESTAMPTZ,
                        response_status BIGINT,
                        last_error TEXT,
                        delivered_at TIMESTAMPTZ,
                        created_at TIMESTAMPTZ,
                        updated_at TIMESTAMPTZ
                    )
                    """,
                    operation: "test.webhooks.schema.deliveries")
            }
            let persistence = ControlPlanePersistence(database: database)
            try await test(
                database, persistence.webhookSubscriptions, persistence.webhookDeliveries)
        }
    }
}
