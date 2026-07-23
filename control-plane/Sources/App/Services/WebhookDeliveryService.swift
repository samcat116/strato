import AsyncHTTPClient
import Crypto
import Fluent
import Foundation
import NIOCore
import NIOConcurrencyHelpers
import Vapor

/// Drains the `webhook_deliveries` outbox (issue #559).
///
/// A periodic loop — cluster-singleton per pass via the
/// `lock:sweep:webhook_delivery` Valkey lock, same as the other sweeps —
/// picks up due pending rows, validates the target against `SSRFGuard`,
/// POSTs the frozen payload with an HMAC-SHA256 `X-Strato-Signature`, and
/// records the verdict: exponential backoff on failure, `dead` after the
/// attempt cap, and auto-disable of subscriptions that have not delivered
/// anything successfully for the auto-disable window. Delivery is
/// at-least-once by construction; consumers dedupe on the event id.
final class WebhookDeliveryService: @unchecked Sendable {
    let app: Application
    let logger: Logger
    private let sweepTask: NIOLockedValueBox<Task<Void, Never>?> = .init(nil)

    /// How often each replica polls the outbox. Worst-case added latency for
    /// a fresh event is one interval.
    let sweepIntervalSeconds: Int

    /// Lock TTL slightly under the interval so this replica's next tick can
    /// reacquire while other replicas' ticks inside the window are excluded.
    var sweepLockTTLSeconds: Int { max(sweepIntervalSeconds - 5, 5) }

    /// Per-request timeout: a webhook consumer should ack fast and process
    /// async; a slow endpoint must not stall the whole pass.
    static let requestTimeoutSeconds: Int64 = 10

    /// Attempts before a delivery is `dead`. With the backoff schedule below
    /// the final attempt lands roughly two hours after the first.
    static let maxAttempts = 8

    /// Due rows fetched per pass; anything beyond rolls to the next pass.
    static let batchSize = 50

    /// Terminal deliveries are kept this long as browsable history.
    static let historyRetentionDays = 7

    /// Continuous-failure window after which a subscription is auto-disabled.
    let autoDisableDays: Int

    init(app: Application) {
        self.app = app
        self.logger = app.logger
        self.sweepIntervalSeconds =
            Environment.get("WEBHOOK_DELIVERY_INTERVAL_SECONDS").flatMap(Int.init) ?? 15
        self.autoDisableDays =
            Environment.get("WEBHOOK_AUTO_DISABLE_DAYS").flatMap(Int.init) ?? 3
    }

    private var sweepEnabled: Bool {
        Environment.get("WEBHOOK_DELIVERY_ENABLED").flatMap(Bool.init)
            ?? (app.environment != .testing)
    }

    /// Backoff before attempt `attempt + 1`, doubling from 30s and capped at
    /// an hour: 30s, 1m, 2m, 4m, 8m, 16m, 32m, 1h.
    static func backoffSeconds(afterAttempts attempts: Int) -> TimeInterval {
        let exponent = max(attempts - 1, 0)
        let capped = min(exponent, 7)
        return min(30 * pow(2, Double(capped)), 3600)
    }

    // MARK: - Sweep lifecycle

    /// Arm the periodic delivery sweep. Called once from the boot lifecycle;
    /// disabled in the testing environment (tests drive `sweepOnce` directly).
    func startSweep() {
        sweepTask.withLockedValue { task in
            guard task == nil else { return }
            task = Task { [weak self] in
                guard let self, self.sweepEnabled else { return }
                let interval = self.sweepIntervalSeconds
                while !Task.isCancelled {
                    await self.sweepOnce()
                    do {
                        try await Task.sleep(for: .seconds(interval))
                    } catch {
                        break  // cancelled
                    }
                }
            }
        }
    }

    /// Cancel the sweep so outbound HTTP never outlives the application.
    func shutdown() {
        sweepTask.withLockedValue { task in
            task?.cancel()
            task = nil
        }
    }

    // MARK: - One pass

    /// One drain pass. Internal rather than private so tests can drive a pass
    /// directly without the timer. `acquiringLock: false` skips the
    /// cluster-singleton lock — tests running several passes back-to-back
    /// would otherwise be serialized by their own previous pass's lock TTL.
    func sweepOnce(acquiringLock: Bool = true) async {
        if acquiringLock {
            guard
                await app.coordination.acquireSweepLock(
                    "webhook_delivery", ttlSeconds: sweepLockTTLSeconds)
            else {
                logger.debug(
                    "Skipping webhook delivery sweep; lock held by another control-plane instance")
                return
            }
        }

        guard let db = app.liveDB else { return }
        do {
            let due = try await WebhookDelivery.query(on: db)
                .filter(\.$status == WebhookDeliveryStatus.pending.rawValue)
                .filter(\.$nextAttemptAt <= Date())
                .sort(\.$nextAttemptAt)
                .limit(Self.batchSize)
                .with(\.$subscription)
                .all()

            for delivery in due {
                await attempt(delivery, on: db)
            }

            try await pruneHistory(on: db)
        } catch {
            logger.error("Webhook delivery sweep failed: \(error)")
        }
    }

    /// One delivery attempt, recording the verdict on the row (and the
    /// failure streak on the subscription).
    private func attempt(_ delivery: WebhookDelivery, on db: Database) async {
        let subscription = delivery.subscription

        // The subscription was deactivated (by a user or the auto-disable)
        // after this row was enqueued: park the delivery instead of posting
        // to an endpoint its owner turned off.
        guard subscription.isActive else {
            delivery.status = WebhookDeliveryStatus.dead.rawValue
            delivery.lastError = "Subscription is disabled"
            try? await delivery.save(on: db)
            return
        }

        let now = Date()
        delivery.attempts += 1
        delivery.lastAttemptAt = now

        do {
            let statusCode = try await post(delivery, subscription: subscription)
            delivery.responseStatus = statusCode
            if (200..<300).contains(statusCode) {
                delivery.status = WebhookDeliveryStatus.succeeded.rawValue
                delivery.deliveredAt = now
                delivery.lastError = nil
                try? await delivery.save(on: db)
                await recordSuccess(subscription, on: db)
                return
            }
            try? await recordFailure(
                delivery, subscription: subscription,
                error: "Endpoint answered HTTP \(statusCode)", at: now, on: db)
        } catch {
            delivery.responseStatus = nil
            try? await recordFailure(
                delivery, subscription: subscription,
                error: String("\(error)".prefix(500)), at: now, on: db)
        }
    }

    /// POST the frozen payload, returning the endpoint's HTTP status.
    private func post(_ delivery: WebhookDelivery, subscription: WebhookSubscription) async throws -> Int {
        // Re-validate at delivery time: DNS may have changed since the URL
        // was registered, and create-time validation alone would let a
        // rebound name reach internal addresses forever after.
        guard let url = URL(string: subscription.url) else {
            throw SSRFGuard.BlockedHostError(reason: "Webhook URL is not a valid URL")
        }
        try await SSRFGuard.validate(
            url: url, environment: app.environment, on: app.threadPool)

        let secret = try app.secretsEncryption.decrypt(subscription.signingSecret)
        let timestamp = Int(Date().timeIntervalSince1970)
        let signature = Self.signature(
            payload: delivery.payload, timestamp: timestamp, secret: secret)

        var request = HTTPClientRequest(url: subscription.url)
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/json")
        request.headers.add(name: "User-Agent", value: "Strato-Webhooks/1.0")
        request.headers.add(name: "X-Strato-Signature", value: "t=\(timestamp),v1=\(signature)")
        request.headers.add(name: "X-Strato-Event-Id", value: delivery.eventID.uuidString)
        request.headers.add(name: "X-Strato-Event-Type", value: delivery.eventType)
        request.headers.add(
            name: "X-Strato-Delivery-Id", value: delivery.id?.uuidString ?? "")
        request.body = .bytes(ByteBuffer(string: delivery.payload))

        let response = try await app.http.client.shared.execute(
            request, timeout: .seconds(Self.requestTimeoutSeconds))
        return Int(response.status.code)
    }

    /// HMAC-SHA256 over `"<timestamp>.<payload>"`, hex-encoded — the `v1`
    /// component of `X-Strato-Signature`. Consumers recompute it with their
    /// subscription secret and must reject stale timestamps to stop replays.
    static func signature(payload: String, timestamp: Int, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let message = Data("\(timestamp).\(payload)".utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    private func recordSuccess(_ subscription: WebhookSubscription, on db: Database) async {
        guard subscription.failingSince != nil else { return }
        subscription.failingSince = nil
        try? await subscription.save(on: db)
    }

    private func recordFailure(
        _ delivery: WebhookDelivery,
        subscription: WebhookSubscription,
        error: String,
        at now: Date,
        on db: Database
    ) async throws {
        delivery.lastError = error
        if delivery.attempts >= Self.maxAttempts {
            delivery.status = WebhookDeliveryStatus.dead.rawValue
            logger.warning(
                "Webhook delivery exhausted its attempts",
                metadata: [
                    "deliveryId": .string(delivery.id?.uuidString ?? ""),
                    "subscriptionId": .string(delivery.$subscription.id.uuidString),
                    "eventType": .string(delivery.eventType),
                    "error": .string(error),
                ])
        } else {
            delivery.nextAttemptAt = now.addingTimeInterval(
                Self.backoffSeconds(afterAttempts: delivery.attempts))
        }
        try await delivery.save(on: db)

        if subscription.failingSince == nil {
            subscription.failingSince = now
            try await subscription.save(on: db)
        } else if let failingSince = subscription.failingSince,
            failingSince < now.addingTimeInterval(-Double(autoDisableDays) * 86_400)
        {
            subscription.isActive = false
            subscription.disabledReason =
                "Automatically disabled after \(autoDisableDays) day(s) of failed deliveries"
            try await subscription.save(on: db)
            logger.warning(
                "Webhook subscription auto-disabled after continuous delivery failure",
                metadata: [
                    "subscriptionId": .string(delivery.$subscription.id.uuidString),
                    "failingSince": .string(failingSince.description),
                ])
        }
    }

    /// Delete terminal deliveries past the history retention window so the
    /// outbox stays bounded by throughput, not by lifetime.
    private func pruneHistory(on db: Database) async throws {
        let cutoff = Date().addingTimeInterval(-Double(Self.historyRetentionDays) * 86_400)
        try await WebhookDelivery.query(on: db)
            .filter(\.$status != WebhookDeliveryStatus.pending.rawValue)
            .filter(\.$createdAt < cutoff)
            .delete()
    }
}

// MARK: - Application accessor / lifecycle

extension Application {
    private struct WebhookDeliveryServiceKey: StorageKey, LockKey {
        typealias Value = WebhookDeliveryService
    }

    var webhookDelivery: WebhookDeliveryService {
        lazyService(WebhookDeliveryServiceKey.self) { WebhookDeliveryService(app: self) }
    }

    /// The delivery service if something already created it. Shutdown must
    /// not instantiate the service just to shut it down.
    var webhookDeliveryServiceIfCreated: WebhookDeliveryService? {
        storage[WebhookDeliveryServiceKey.self]
    }
}

/// Arms the webhook delivery sweep at boot and cancels it at shutdown so the
/// periodic outbox drain never outlives the application.
struct WebhookDeliveryLifecycleHandler: LifecycleHandler {
    func didBootAsync(_ application: Application) async throws {
        application.webhookDelivery.startSweep()
    }

    func shutdownAsync(_ application: Application) async {
        application.webhookDeliveryServiceIfCreated?.shutdown()
    }
}
