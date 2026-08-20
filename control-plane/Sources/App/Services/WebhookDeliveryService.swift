import Crypto
import ControlPlanePostgres
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import Vapor

/// Drains the `webhook_deliveries` outbox (issue #559).
///
/// A periodic loop — cluster-singleton per pass via the
/// `lock:sweep:webhook_delivery` Valkey lock, same as the other sweeps —
/// picks up due pending rows and POSTs the frozen payload through
/// `GuardedHTTPClient` with an HMAC-SHA256 `X-Strato-Signature`, then
/// records the verdict: exponential backoff on failure, `dead` after the
/// attempt cap, and auto-disable of subscriptions that have not delivered
/// anything successfully for the auto-disable window. Delivery is
/// at-least-once by construction; consumers dedupe on the event id.
///
/// Safety: all service fields are immutable except `sweepTask`, whose complete
/// lifecycle is protected by `NIOLockedValueBox`. Child tasks receive only
/// immutable IDs and snapshots.
final class WebhookDeliveryService: Sendable {
    let app: Application
    let logger: Logger
    private let sweepTask: NIOLockedValueBox<Task<Void, Never>?> = .init(nil)
    private let subscriptions: WebhookSubscriptionsPersistence
    private let deliveries: WebhookDeliveriesPersistence

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

    /// Rows claimed and concurrently POSTed per pass. A pass claims no more
    /// work than it can start immediately, so every row remains inside its
    /// claim lease even when one subscription owns the whole batch. Anything
    /// beyond this capacity rolls to the next pass.
    ///
    /// Bounded fan-out keeps a few slow or
    /// timing-out endpoints from head-of-line-blocking deliveries to healthy
    /// endpoints behind them in the batch (PR #668 review).
    static let maxConcurrentDeliveries = 8

    /// How long a claimed row stays invisible to other drainers. Sized to
    /// cover a worst-case attempt (DNS resolution plus the request timeout)
    /// with generous slack; a drainer that crashes mid-attempt simply lets
    /// the lease lapse and the row is retried.
    static let claimLeaseSeconds = 120

    /// Terminal deliveries are kept this long as browsable history.
    static let historyRetentionDays = 7

    /// Continuous-failure window after which a subscription is auto-disabled.
    let autoDisableDays: Int

    init(app: Application) {
        self.app = app
        self.logger = app.logger
        self.subscriptions = app.webhookSubscriptionsPersistence
        self.deliveries = app.webhookDeliveriesPersistence
        self.sweepIntervalSeconds = app.controlPlaneConfiguration.int(.webhookDeliveryIntervalSeconds)!
        self.autoDisableDays = app.controlPlaneConfiguration.int(.webhookAutoDisableDays)!
    }

    private var sweepEnabled: Bool {
        app.controlPlaneConfiguration.bool(.webhookDeliveryEnabled)!
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
    ///
    /// Correctness under concurrent passes comes from the atomic row claim in
    /// `claimDueDeliveries`, not the sweep lock: a pass slower than the lock
    /// TTL can overlap the next tick (here or on another replica), but each
    /// row is only ever claimed by one of them. The lock is an optimization —
    /// it keeps the other replicas from even running the claim query on
    /// every tick.
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

        do {
            let due = try await deliveries.claimDue(
                limit: Self.maxConcurrentDeliveries,
                leaseSeconds: Self.claimLeaseSeconds)

            // `claimDueDeliveries` returns at most the number of attempts this
            // pass can start immediately. Only immutable IDs cross into child
            // tasks; each attempt reloads immutable database snapshots. Subscription
            // streak updates are atomic SQL operations, so sibling attempts
            // need not queue behind one another in process memory.
            await withTaskGroup(of: Void.self) { group in
                for delivery in due {
                    group.addTask {
                        await self.attempt(deliveryID: delivery)
                    }
                }
            }

            try await pruneHistory()
        } catch {
            logger.error("Webhook delivery sweep failed: \(error)")
        }
    }

    /// Atomically claim the due pending rows by pushing `next_attempt_at`
    /// forward one lease (PR #668 review). The single UPDATE makes overlapping
    /// drainers — a pass that outlived the sweep-lock TTL, or another
    /// replica's tick — claim disjoint sets instead of double-POSTing the
    /// same rows: whoever wins the row lock moves the row out of the other's
    /// WHERE clause. `FOR UPDATE SKIP LOCKED` keeps the losers from queueing
    /// on rows the winner is still claiming. The attempt's own verdict then
    /// overwrites the lease (backoff, dead, or succeeded).
    /// One delivery attempt, recording the verdict on the row (and the
    /// failure streak on the subscription).
    private func attempt(deliveryID: UUID) async {
        let delivery: WebhookDeliverySnapshot
        do {
            guard let loaded = try await deliveries.delivery(id: deliveryID) else { return }
            delivery = loaded
        } catch {
            logger.error(
                "Could not reload claimed webhook delivery",
                metadata: [
                    "deliveryId": .string(deliveryID.uuidString),
                    "error": .string("\(error)"),
                ])
            return
        }
        let subscription: WebhookSubscriptionSnapshot
        do {
            guard let loaded = try await subscriptions.subscription(id: delivery.subscriptionID)
            else { return }
            subscription = loaded
        } catch {
            logger.error(
                "Could not load claimed webhook subscription",
                metadata: [
                    "deliveryId": .string(deliveryID.uuidString),
                    "error": .string("\(error)"),
                ])
            return
        }

        // The subscription was deactivated (by a user or the auto-disable)
        // after this row was enqueued: park the delivery instead of posting
        // to an endpoint its owner turned off.
        guard subscription.isActive else {
            _ = try? await deliveries.parkDisabled(id: delivery.id)
            return
        }

        let now = Date()

        do {
            let statusCode = try await post(delivery, subscription: subscription)
            if (200..<300).contains(statusCode) {
                _ = try? await deliveries.recordSuccess(
                    id: delivery.id, responseStatus: statusCode, at: now)
                await recordSuccess(subscriptionID: delivery.subscriptionID)
                return
            }
            try? await recordFailure(
                delivery,
                responseStatus: statusCode,
                error: "Endpoint answered HTTP \(statusCode)",
                at: now)
        } catch {
            // A guard refusal is a property of the *subscription*, not of this
            // attempt: retrying eight times and auto-disabling days later
            // wouldn't tell the owner why. Rows predating the create-time
            // credential check are the case that matters — say so once per
            // attempt, naming the subscription.
            if let blocked = error as? SSRFGuard.BlockedHostError {
                logger.warning(
                    "Webhook target refused by the outbound guard",
                    metadata: [
                        "subscriptionId": .string(delivery.subscriptionID.uuidString),
                        "reason": .string(blocked.reason),
                    ])
            }
            try? await recordFailure(
                delivery,
                responseStatus: nil,
                error: String("\(error)".prefix(500)),
                at: now)
        }
    }

    /// POST the frozen payload, returning the endpoint's HTTP status.
    private func post(
        _ delivery: WebhookDeliverySnapshot,
        subscription: WebhookSubscriptionSnapshot
    ) async throws -> Int {
        let secret = try app.secretsEncryption.decrypt(subscription.encryptedSigningSecret)
        let timestamp = Int(Date().timeIntervalSince1970)
        let signature = Self.signature(
            payload: delivery.payload, timestamp: timestamp, secret: secret)

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "User-Agent", value: "Strato-Webhooks/1.0")
        headers.add(name: "X-Strato-Signature", value: "t=\(timestamp),v1=\(signature)")
        headers.add(name: "X-Strato-Event-Id", value: delivery.eventID.uuidString)
        headers.add(name: "X-Strato-Event-Type", value: delivery.eventType)
        headers.add(name: "X-Strato-Delivery-Id", value: delivery.id.uuidString)

        // The guarded client re-validates at delivery time (DNS may have changed
        // since the URL was registered, and create-time validation alone would
        // let a rebound name reach internal addresses forever after) and pins
        // the connection to the address it approved. TLS certificate validation
        // still runs against the hostname; only resolution is overridden.
        let request = ClientRequest(
            method: .POST,
            url: URI(string: subscription.url),
            headers: headers,
            body: ByteBuffer(string: delivery.payload),
            timeout: .seconds(Self.requestTimeoutSeconds))
        let response = try await app.guardedHTTPClient.send(request)
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

    private func recordSuccess(subscriptionID: UUID) async {
        let automaticReason =
            "Automatically disabled after \(autoDisableDays) day(s) of failed deliveries"
        _ = try? await subscriptions.recordDeliverySuccess(
            id: subscriptionID, automaticDisabledReason: automaticReason)
    }

    private func recordFailure(
        _ delivery: WebhookDeliverySnapshot,
        responseStatus: Int?,
        error: String,
        at now: Date
    ) async throws {
        let attemptCount = delivery.attempts + 1
        let nextAttemptAt = now.addingTimeInterval(
            Self.backoffSeconds(afterAttempts: attemptCount))
        let updated = try await deliveries.recordFailure(
            id: delivery.id,
            responseStatus: responseStatus,
            error: error,
            at: now,
            maximumAttempts: Self.maxAttempts,
            nextAttemptAt: nextAttemptAt)
        if updated?.status == .dead {
            logger.warning(
                "Webhook delivery exhausted its attempts",
                metadata: [
                    "deliveryId": .string(delivery.id.uuidString),
                    "subscriptionId": .string(delivery.subscriptionID.uuidString),
                    "eventType": .string(delivery.eventType),
                    "error": .string(error),
                ])
        }

        let cutoff = now.addingTimeInterval(-Double(autoDisableDays) * 86_400)
        let disabledReason =
            "Automatically disabled after \(autoDisableDays) day(s) of failed deliveries"
        let state = try await subscriptions.recordDeliveryFailure(
            id: delivery.subscriptionID,
            at: now,
            disableBefore: cutoff,
            disabledReason: disabledReason)
        if let state, !state.isActive, let failingSince = state.failingSince {
            logger.warning(
                "Webhook subscription auto-disabled after continuous delivery failure",
                metadata: [
                    "subscriptionId": .string(delivery.subscriptionID.uuidString),
                    "failingSince": .string(failingSince.description),
                ])
        }
    }

    /// Delete terminal deliveries past the history retention window so the
    /// outbox stays bounded by throughput, not by lifetime.
    private func pruneHistory() async throws {
        let cutoff = Date().addingTimeInterval(-Double(Self.historyRetentionDays) * 86_400)
        try await deliveries.pruneTerminal(createdBefore: cutoff)
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
