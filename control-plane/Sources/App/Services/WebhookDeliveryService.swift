import AsyncHTTPClient
import Crypto
import Fluent
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import SQLKit
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

    /// Concurrent POSTs per pass. Bounded fan-out keeps a few slow or
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

        guard let db = app.liveDB else { return }
        do {
            let due = try await claimDueDeliveries(on: db)

            // Bounded fan-out: up to maxConcurrentDeliveries in flight, each
            // finished attempt admitting the next claimed row.
            await withTaskGroup(of: Void.self) { group in
                var remaining = due.makeIterator()
                var inFlight = 0
                while inFlight < Self.maxConcurrentDeliveries, let delivery = remaining.next() {
                    group.addTask { await self.attempt(delivery, on: db) }
                    inFlight += 1
                }
                while await group.next() != nil {
                    if let delivery = remaining.next() {
                        group.addTask { await self.attempt(delivery, on: db) }
                    }
                }
            }

            try await pruneHistory(on: db)
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
    private func claimDueDeliveries(on db: Database) async throws -> [WebhookDelivery] {
        guard let sql = db as? SQLDatabase else { return [] }
        struct ClaimedRow: Decodable {
            let id: UUID
        }
        let claimed = try await sql.raw(
            """
            UPDATE webhook_deliveries
            SET next_attempt_at = now() + (\(bind: Self.claimLeaseSeconds) * interval '1 second'),
                updated_at = now()
            WHERE id IN (
                SELECT id FROM webhook_deliveries
                WHERE status = \(bind: WebhookDeliveryStatus.pending.rawValue)
                  AND next_attempt_at <= now()
                ORDER BY next_attempt_at
                LIMIT \(bind: Self.batchSize)
                FOR UPDATE SKIP LOCKED
            )
            RETURNING id
            """
        ).all(decoding: ClaimedRow.self)
        guard !claimed.isEmpty else { return [] }

        return try await WebhookDelivery.query(on: db)
            .filter(\.$id ~~ claimed.map(\.id))
            .sort(\.$nextAttemptAt)
            .with(\.$subscription)
            .all()
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
        let approvedAddresses = try await SSRFGuard.validate(
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

        // Pin the connection to an address the guard approved (its documented
        // rebind gap): the shared client would re-resolve the name at connect
        // time, and a low-TTL record could point it at an internal address
        // between validation and connect. `approvedAddresses` is empty when
        // private hosts are allowed (testing/dev) — then the shared client is
        // fine. TLS certificate validation still runs against the hostname;
        // only resolution is overridden.
        guard let host = url.host, let pinnedAddress = approvedAddresses.first else {
            let response = try await app.http.client.shared.execute(
                request, timeout: .seconds(Self.requestTimeoutSeconds))
            return Int(response.status.code)
        }

        var configuration = HTTPClient.Configuration()
        // The shared client disallows redirects globally (configure.swift); a
        // transient client must not silently reintroduce redirect-following,
        // which would defeat the SSRF validation of the final destination.
        configuration.redirectConfiguration = .disallow
        configuration.dnsOverride = [host: pinnedAddress]
        let client = HTTPClient(
            eventLoopGroupProvider: .shared(app.eventLoopGroup),
            configuration: configuration)
        do {
            let response = try await client.execute(
                request, timeout: .seconds(Self.requestTimeoutSeconds))
            try await client.shutdown()
            return Int(response.status.code)
        } catch {
            try? await client.shutdown()
            throw error
        }
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
