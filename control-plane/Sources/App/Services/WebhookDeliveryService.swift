import Crypto
import Fluent
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import SQLKit
import Vapor

/// Drains the `webhook_deliveries` outbox (issue #559).
///
/// A periodic loop on every replica picks up due pending rows and POSTs the frozen payload through
/// `GuardedHTTPClient` with an HMAC-SHA256 `X-Strato-Signature`, then
/// records the verdict: exponential backoff on failure, `dead` after the
/// attempt cap, and auto-disable of subscriptions that have not delivered
/// anything successfully for the auto-disable window. Delivery is
/// POST attempts are at-least-once after a row is claimed; consumers dedupe on
/// the event id. Rows shed by the explicit pending ceiling are the visible
/// `dropped` exception.
///
/// Safety: all service fields are immutable except `sweepTask`, whose complete
/// lifecycle is protected by `NIOLockedValueBox`. Fluent models are loaded and
/// consumed within one attempt task; child tasks receive only immutable IDs.
final class WebhookDeliveryService: Sendable {
    let app: Application
    let logger: Logger
    private let sweepTask: NIOLockedValueBox<Task<Void, Never>?> = .init(nil)
    private let measuredSubscriptionIDs: NIOLockedValueBox<Set<UUID>> = .init([])

    /// How often each replica polls an idle outbox.
    let sweepIntervalSeconds: Int

    /// Soft wall-clock budget for one drain pass. Work already claimed always
    /// records its verdict; the deadline is checked between claim batches.
    let passBudgetSeconds: Int

    /// Per-request timeout: a webhook consumer should ack fast and process
    /// async; a slow endpoint must not stall the whole pass.
    static let requestTimeoutSeconds: Int64 = 10

    /// Attempts before a delivery is `dead`. With the backoff schedule below
    /// the final attempt lands roughly two hours after the first.
    static let maxAttempts = 8

    /// Bounded fan-out keeps a few slow or
    /// timing-out endpoints from head-of-line-blocking deliveries to healthy
    /// endpoints behind them in the batch (PR #668 review).
    static let maxConcurrentDeliveries = 8

    /// Rows atomically claimed at once. This is deliberately separate from
    /// request concurrency: a bounded task group feeds at most eight POSTs at
    /// a time, while a pass keeps claiming batches until it catches up or uses
    /// its wall-clock budget.
    static let claimBatchSize = 16

    /// How long a claimed row stays invisible to other drainers. Sized to
    /// cover a worst-case attempt (DNS resolution plus the request timeout)
    /// with generous slack; a drainer that crashes mid-attempt simply lets
    /// the lease lapse and the row is retried.
    static let claimLeaseSeconds = 120

    /// Terminal deliveries are kept this long as browsable history.
    static let historyRetentionDays = 7

    /// Continuous-failure window after which a subscription is auto-disabled.
    let autoDisableDays: Int

    init(app: Application, passBudgetSecondsOverride: Int? = nil) {
        self.app = app
        self.logger = app.logger
        self.sweepIntervalSeconds = app.controlPlaneConfiguration.int(.webhookDeliveryIntervalSeconds)
        self.passBudgetSeconds =
            passBudgetSecondsOverride
            ?? app.controlPlaneConfiguration.int(.webhookDeliveryPassBudgetSeconds)
        self.autoDisableDays = app.controlPlaneConfiguration.int(.webhookAutoDisableDays)
    }

    private var sweepEnabled: Bool {
        app.controlPlaneConfiguration.bool(.webhookDeliveryEnabled)
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
                guard let self else { return }
                let interval = self.sweepIntervalSeconds
                while !Task.isCancelled {
                    if self.sweepEnabled {
                        let disposition = await self.sweepOnce()
                        if disposition == .budgetExhausted {
                            await Task.yield()
                            continue
                        }
                    } else if let db = self.app.liveDB {
                        // Delivery can be disabled deliberately during an incident.
                        // Keep reporting the durable backlog so that state is visible
                        // instead of turning off the operator's only queue signal too.
                        await self.recordQueueTelemetry(on: db)
                    }
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
    /// directly without the timer. Every replica participates; correctness
    /// comes from the atomic row claim in `claimDueDeliveries`.
    enum SweepDisposition: Sendable {
        case drained
        case budgetExhausted
        case failed
    }

    @discardableResult
    func sweepOnce() async -> SweepDisposition {
        guard let db = app.liveDB else { return .drained }
        let deadline = ContinuousClock.now.advanced(by: .seconds(passBudgetSeconds))
        do {
            var totals = SweepCounts()
            var budgetExhausted = false
            while !Task.isCancelled {
                let due = try await claimDueDeliveries(on: db)
                guard !due.isEmpty else { break }

                let batch = await attemptBatch(due, on: db)
                totals.add(batch)
                recordAttemptTelemetry(batch)
                if ContinuousClock.now >= deadline {
                    budgetExhausted = true
                    break
                }
            }

            try await pruneHistory(on: db)
            await recordQueueTelemetry(on: db)
            if totals.claimed > 0 || budgetExhausted {
                logger.info(
                    "Webhook delivery pass completed",
                    metadata: [
                        "claimed": .stringConvertible(totals.claimed),
                        "attempted": .stringConvertible(totals.attempted),
                        "succeeded": .stringConvertible(totals.succeeded),
                        "failed": .stringConvertible(totals.failed),
                        "dead": .stringConvertible(totals.dead),
                        "budgetExhausted": .stringConvertible(budgetExhausted),
                    ])
            }
            return budgetExhausted ? .budgetExhausted : .drained
        } catch {
            logger.error("Webhook delivery sweep failed: \(error)")
            await recordQueueTelemetry(on: db)
            return .failed
        }
    }

    /// Emit after each completed batch, rather than at the end of the pass, so
    /// a later claim/prune failure cannot erase metrics for verdicts already
    /// persisted by earlier batches.
    private func recordAttemptTelemetry(_ counts: SweepCounts) {
        Telemetry.webhookDeliveryAttempted(count: counts.attempted)
        Telemetry.webhookDeliveryFinished(result: .succeeded, count: counts.succeeded)
        Telemetry.webhookDeliveryFinished(result: .failed, count: counts.failed)
        Telemetry.webhookDeliveryFinished(result: .dead, count: counts.dead)
    }

    /// Atomically claim a fair batch by setting an explicit lease (PR #668
    /// review). First select at most one due head per subscription and fairly
    /// choose no more than one batch of subscriptions. Only those subscriptions
    /// participate in the locking lookup, so a statement locks at most two
    /// batches of rows rather than one batch for every backlogged subscription.
    /// Rows within that bounded set are interleaved by organization and then by
    /// subscription before the final batch limit.
    ///
    /// The single UPDATE and `FOR UPDATE SKIP LOCKED` make overlapping replicas
    /// claim disjoint rows. Eligibility is repeated against the locked base row
    /// so PostgreSQL's READ COMMITTED recheck cannot claim a row from a stale
    /// candidate snapshot after another replica renews its lease.
    struct ClaimedDelivery: Decodable, Sendable {
        let id: UUID
        let organizationPosition: Int
        let subscriptionPosition: Int
        let nextAttemptAt: Date
        let createdAt: Date?
    }

    func claimDueDeliveries(on db: Database) async throws -> [ClaimedDelivery] {
        guard let sql = db as? SQLDatabase else { return [] }
        return try await sql.raw(
            """
            WITH due_subscriptions AS MATERIALIZED (
                SELECT subscription.id AS subscription_id,
                       subscription.organization_id,
                       head.next_attempt_at,
                       head.created_at,
                       head.id AS delivery_id
                FROM webhook_subscriptions AS subscription
                JOIN LATERAL (
                    SELECT delivery.id,
                           delivery.next_attempt_at,
                           delivery.created_at
                    FROM webhook_deliveries AS delivery
                    WHERE delivery.subscription_id = subscription.id
                      -- Keep this literal aligned with the partial claim index.
                      -- PostgreSQL cannot prove a parameterized predicate implies
                      -- `status = 'pending'` when it selects a generic plan.
                      AND delivery.status = 'pending'
                      AND delivery.next_attempt_at <= now()
                      AND (delivery.claimed_until IS NULL OR delivery.claimed_until <= now())
                    ORDER BY delivery.next_attempt_at, delivery.created_at, delivery.id
                    LIMIT 1
                ) AS head ON TRUE
            ), ranked_subscriptions AS MATERIALIZED (
                SELECT due_subscriptions.*,
                       row_number() OVER (
                           PARTITION BY organization_id
                           ORDER BY next_attempt_at,
                                    created_at,
                                    delivery_id,
                                    subscription_id
                       ) AS organization_subscription_position
                FROM due_subscriptions
            ), selected_subscriptions AS MATERIALIZED (
                SELECT *
                FROM ranked_subscriptions
                ORDER BY organization_subscription_position,
                         next_attempt_at,
                         created_at,
                         delivery_id,
                         subscription_id
                LIMIT \(bind: Self.claimBatchSize)
            ), selected_count AS MATERIALIZED (
                SELECT count(*)::bigint AS value
                FROM selected_subscriptions
            ), candidates AS MATERIALIZED (
                SELECT selected.subscription_id,
                       selected.organization_id,
                       candidate.id,
                       candidate.next_attempt_at,
                       candidate.created_at,
                       candidate.subscription_position
                FROM selected_subscriptions AS selected
                CROSS JOIN selected_count
                JOIN LATERAL (
                    SELECT bounded.id,
                           bounded.next_attempt_at,
                           bounded.created_at,
                           row_number() OVER (
                               ORDER BY bounded.next_attempt_at, bounded.created_at, bounded.id
                           ) AS subscription_position
                    FROM (
                        SELECT delivery.id,
                               delivery.next_attempt_at,
                               delivery.created_at
                        FROM webhook_deliveries AS delivery
                        WHERE delivery.subscription_id = selected.subscription_id
                          AND delivery.status = 'pending'
                          AND delivery.next_attempt_at <= now()
                          AND (delivery.claimed_until IS NULL OR delivery.claimed_until <= now())
                        ORDER BY delivery.next_attempt_at, delivery.created_at, delivery.id
                        LIMIT greatest(
                            1,
                            (\(bind: Self.claimBatchSize) + selected_count.value - 1)
                                / selected_count.value
                        )
                        FOR UPDATE OF delivery SKIP LOCKED
                    ) AS bounded
                ) AS candidate ON TRUE
            ), organization_ranked AS MATERIALIZED (
                SELECT candidates.*,
                       row_number() OVER (
                           PARTITION BY organization_id
                           ORDER BY subscription_position,
                                    next_attempt_at,
                                    created_at,
                                    id
                       ) AS organization_position
                FROM candidates
            ), due AS MATERIALIZED (
                SELECT id,
                       organization_position,
                       subscription_position,
                       next_attempt_at,
                       created_at
                FROM organization_ranked
                ORDER BY organization_position,
                         subscription_position,
                         next_attempt_at,
                         created_at,
                         id
                LIMIT \(bind: Self.claimBatchSize)
            )
            UPDATE webhook_deliveries AS delivery
            SET claimed_until = now() + (\(bind: Self.claimLeaseSeconds) * interval '1 second'),
                next_attempt_at = now() + (\(bind: Self.claimLeaseSeconds) * interval '1 second'),
                updated_at = now()
            FROM due
            WHERE delivery.id = due.id
              AND delivery.status = 'pending'
              AND delivery.next_attempt_at <= now()
              AND (delivery.claimed_until IS NULL OR delivery.claimed_until <= now())
            RETURNING delivery.id,
                      due.organization_position AS "organizationPosition",
                      due.subscription_position AS "subscriptionPosition",
                      due.next_attempt_at AS "nextAttemptAt",
                      due.created_at AS "createdAt"
            """
        ).all(decoding: ClaimedDelivery.self).sorted {
            if $0.organizationPosition != $1.organizationPosition {
                return $0.organizationPosition < $1.organizationPosition
            }
            if $0.subscriptionPosition != $1.subscriptionPosition {
                return $0.subscriptionPosition < $1.subscriptionPosition
            }
            if $0.nextAttemptAt != $1.nextAttemptAt {
                return $0.nextAttemptAt < $1.nextAttemptAt
            }
            if $0.createdAt != $1.createdAt {
                return ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private enum AttemptOutcome: Sendable {
        case succeeded
        case failed
        case dead
        case unresolved
    }

    private struct AttemptResult: Sendable {
        let attempted: Bool
        let outcome: AttemptOutcome
    }

    private struct SweepCounts: Sendable {
        var claimed = 0
        var attempted = 0
        var succeeded = 0
        var failed = 0
        var dead = 0

        mutating func add(_ result: AttemptResult) {
            claimed += 1
            if result.attempted { attempted += 1 }
            switch result.outcome {
            case .succeeded: succeeded += 1
            case .failed: failed += 1
            case .dead: dead += 1
            case .unresolved: break
            }
        }

        mutating func add(_ other: Self) {
            claimed += other.claimed
            attempted += other.attempted
            succeeded += other.succeeded
            failed += other.failed
            dead += other.dead
        }
    }

    /// Feed one claimed batch through a sliding task window so claim size can
    /// grow independently without ever exceeding the endpoint fan-out bound.
    private func attemptBatch(_ deliveries: [ClaimedDelivery], on db: Database) async -> SweepCounts {
        await withTaskGroup(of: AttemptResult.self, returning: SweepCounts.self) { group in
            var iterator = deliveries.makeIterator()
            for _ in 0..<min(Self.maxConcurrentDeliveries, deliveries.count) {
                guard let delivery = iterator.next() else { break }
                group.addTask {
                    await self.attempt(deliveryID: delivery.id, on: db)
                }
            }

            var counts = SweepCounts()
            while let result = await group.next() {
                counts.add(result)
                if let delivery = iterator.next() {
                    group.addTask {
                        await self.attempt(deliveryID: delivery.id, on: db)
                    }
                }
            }
            return counts
        }
    }

    /// One delivery attempt, recording the verdict on the row (and the
    /// failure streak on the subscription).
    private func attempt(deliveryID: UUID, on db: Database) async -> AttemptResult {
        let delivery: WebhookDelivery
        do {
            guard
                let loaded = try await WebhookDelivery.query(on: db)
                    .filter(\.$id == deliveryID)
                    .with(\.$subscription)
                    .first()
            else { return AttemptResult(attempted: false, outcome: .unresolved) }
            delivery = loaded
        } catch {
            logger.error(
                "Could not reload claimed webhook delivery",
                metadata: [
                    "deliveryId": .string(deliveryID.uuidString),
                    "error": .string("\(error)"),
                ])
            return AttemptResult(attempted: false, outcome: .unresolved)
        }
        let subscription = delivery.subscription

        // The subscription was deactivated (by a user or the auto-disable)
        // after this row was enqueued: park the delivery instead of posting
        // to an endpoint its owner turned off.
        guard subscription.isActive else {
            delivery.status = WebhookDeliveryStatus.dead.rawValue
            delivery.lastError = "Subscription is disabled"
            delivery.claimedUntil = nil
            do {
                try await delivery.save(on: db)
                return AttemptResult(attempted: false, outcome: .dead)
            } catch {
                logger.error(
                    "Could not park webhook delivery for a disabled subscription",
                    metadata: [
                        "deliveryId": .string(deliveryID.uuidString),
                        "error": .string("\(error)"),
                    ])
                return AttemptResult(attempted: false, outcome: .unresolved)
            }
        }

        let now = Date()
        let signingSecret: String
        do {
            signingSecret = try app.secretsEncryption.decrypt(subscription.signingSecret)
        } catch let error as SecretsEncryptionError where error.isMissingKeyConfiguration {
            // The control plane, not the customer's endpoint, is blocked. Keep
            // the delivery pending without consuming an attempt or touching the
            // subscription failure streak; the next sweep resumes by itself
            // after the operator restores the key.
            delivery.responseStatus = nil
            delivery.lastError = error.reason
            delivery.claimedUntil = nil
            delivery.nextAttemptAt = now.addingTimeInterval(
                Self.backoffSeconds(afterAttempts: 1))
            try? await delivery.save(on: db)
            logger.error(
                "Webhook delivery blocked by secrets-encryption configuration",
                metadata: [
                    "deliveryId": .string(deliveryID.uuidString),
                    "subscriptionId": .string(delivery.$subscription.id.uuidString),
                    "error": .string(error.reason),
                ])
            return AttemptResult(attempted: false, outcome: .unresolved)
        } catch {
            // Malformed ciphertext is durable row corruption, not a missing-key
            // configuration fault. Keep ordinary failure visibility/accounting.
            delivery.attempts += 1
            delivery.lastAttemptAt = now
            delivery.responseStatus = nil
            return await recordFailureResult(
                delivery, subscriptionID: delivery.$subscription.id,
                error: String("\(error)".prefix(500)), at: now, on: db)
        }

        delivery.attempts += 1
        delivery.lastAttemptAt = now

        let statusCode: Int
        do {
            statusCode = try await post(
                delivery, subscription: subscription, signingSecret: signingSecret)
        } catch {
            delivery.responseStatus = nil
            // A guard refusal is a property of the *subscription*, not of this
            // attempt: retrying eight times and auto-disabling days later
            // wouldn't tell the owner why. Rows predating the create-time
            // credential check are the case that matters — say so once per
            // attempt, naming the subscription.
            if let blocked = error as? SSRFGuard.BlockedHostError {
                logger.warning(
                    "Webhook target refused by the outbound guard",
                    metadata: [
                        "subscriptionId": .string(delivery.$subscription.id.uuidString),
                        "reason": .string(blocked.reason),
                    ])
            }
            return await recordFailureResult(
                delivery, subscriptionID: delivery.$subscription.id,
                error: String("\(error)".prefix(500)), at: now, on: db)
        }

        delivery.responseStatus = statusCode
        guard (200..<300).contains(statusCode) else {
            return await recordFailureResult(
                delivery, subscriptionID: delivery.$subscription.id,
                error: "Endpoint answered HTTP \(statusCode)", at: now, on: db)
        }

        delivery.status = WebhookDeliveryStatus.succeeded.rawValue
        delivery.deliveredAt = now
        delivery.lastError = nil
        delivery.claimedUntil = nil
        do {
            try await delivery.save(on: db)
            await recordSuccess(subscriptionID: delivery.$subscription.id, on: db)
            return AttemptResult(attempted: true, outcome: .succeeded)
        } catch {
            logger.error(
                "Could not record successful webhook delivery",
                metadata: [
                    "deliveryId": .string(deliveryID.uuidString),
                    "error": .string("\(error)"),
                ])
            return AttemptResult(attempted: true, outcome: .unresolved)
        }
    }

    private func recordFailureResult(
        _ delivery: WebhookDelivery,
        subscriptionID: UUID,
        error: String,
        at now: Date,
        on db: Database
    ) async -> AttemptResult {
        do {
            return try await recordFailure(
                delivery, subscriptionID: subscriptionID, error: error, at: now, on: db)
        } catch {
            logger.error(
                "Could not record failed webhook delivery",
                metadata: [
                    "deliveryId": .string(delivery.id?.uuidString ?? ""),
                    "error": .string("\(error)"),
                ])
            return AttemptResult(attempted: true, outcome: .unresolved)
        }
    }

    /// POST the frozen payload, returning the endpoint's HTTP status.
    private func post(
        _ delivery: WebhookDelivery,
        subscription: WebhookSubscription,
        signingSecret: String
    ) async throws -> Int {
        let timestamp = Int(Date().timeIntervalSince1970)
        let signature = Self.signature(
            payload: delivery.payload, timestamp: timestamp, secret: signingSecret)

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "User-Agent", value: "Strato-Webhooks/1.0")
        headers.add(name: "X-Strato-Signature", value: "t=\(timestamp),v1=\(signature)")
        headers.add(name: "X-Strato-Event-Id", value: delivery.eventID.uuidString)
        headers.add(name: "X-Strato-Event-Type", value: delivery.eventType)
        headers.add(name: "X-Strato-Delivery-Id", value: delivery.id?.uuidString ?? "")

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

    private func recordSuccess(subscriptionID: UUID, on db: Database) async {
        guard let sql = db as? SQLDatabase else { return }
        let automaticReason =
            "Automatically disabled after \(autoDisableDays) day(s) of failed deliveries"
        try? await sql.raw(
            """
            UPDATE webhook_subscriptions
            SET failing_since = NULL,
                is_active = CASE
                    WHEN NOT is_active AND disabled_reason = \(bind: automaticReason)
                    THEN TRUE ELSE is_active
                END,
                disabled_reason = CASE
                    WHEN NOT is_active AND disabled_reason = \(bind: automaticReason)
                    THEN NULL ELSE disabled_reason
                END,
                updated_at = now()
            WHERE id = \(bind: subscriptionID)
              AND (failing_since IS NOT NULL OR disabled_reason = \(bind: automaticReason))
            """
        ).run()
    }

    private func recordFailure(
        _ delivery: WebhookDelivery,
        subscriptionID: UUID,
        error: String,
        at now: Date,
        on db: Database
    ) async throws -> AttemptResult {
        delivery.lastError = error
        let outcome: AttemptOutcome
        if delivery.attempts >= Self.maxAttempts {
            delivery.status = WebhookDeliveryStatus.dead.rawValue
            delivery.claimedUntil = nil
            outcome = .dead
            logger.warning(
                "Webhook delivery exhausted its attempts",
                metadata: [
                    "deliveryId": .string(delivery.id?.uuidString ?? ""),
                    "subscriptionId": .string(delivery.$subscription.id.uuidString),
                    "eventType": .string(delivery.eventType),
                    "error": .string(error),
                ])
        } else {
            outcome = .failed
            // A released retry has no active attempt lease. During a rolling
            // upgrade, shedding protects a future schedule for one full lease
            // horizon because a legacy claim advances only that column.
            delivery.claimedUntil = nil
            delivery.nextAttemptAt = now.addingTimeInterval(
                Self.backoffSeconds(afterAttempts: delivery.attempts))
        }
        try await delivery.save(on: db)

        guard let sql = db as? SQLDatabase else {
            return AttemptResult(attempted: true, outcome: outcome)
        }
        let cutoff = now.addingTimeInterval(-Double(autoDisableDays) * 86_400)
        let disabledReason =
            "Automatically disabled after \(autoDisableDays) day(s) of failed deliveries"
        struct SubscriptionFailureState: Decodable {
            let isActive: Bool
            let failingSince: Date?
        }
        do {
            let state = try await sql.raw(
                """
                UPDATE webhook_subscriptions
                SET failing_since = COALESCE(failing_since, \(bind: now)),
                    is_active = CASE
                        WHEN is_active AND failing_since IS NOT NULL AND failing_since < \(bind: cutoff)
                        THEN FALSE ELSE is_active
                    END,
                    disabled_reason = CASE
                        WHEN is_active AND failing_since IS NOT NULL AND failing_since < \(bind: cutoff)
                        THEN \(bind: disabledReason) ELSE disabled_reason
                    END,
                    updated_at = now()
                WHERE id = \(bind: subscriptionID)
                RETURNING is_active AS "isActive", failing_since AS "failingSince"
                """
            ).first(decoding: SubscriptionFailureState.self)
            if let state, !state.isActive, let failingSince = state.failingSince {
                logger.warning(
                    "Webhook subscription auto-disabled after continuous delivery failure",
                    metadata: [
                        "subscriptionId": .string(subscriptionID.uuidString),
                        "failingSince": .string(failingSince.description),
                    ])
            }
        } catch {
            // The delivery verdict above is already durable and must still be
            // counted. A transient streak-update failure affects only the
            // subscription's auto-disable bookkeeping.
            logger.error(
                "Could not update webhook subscription failure streak",
                metadata: [
                    "subscriptionId": .string(subscriptionID.uuidString),
                    "error": .string("\(error)"),
                ])
        }
        return AttemptResult(attempted: true, outcome: outcome)
    }

    /// Delete terminal deliveries after their terminal transition has remained
    /// browsable for the retention window. `updated_at` matters for an old
    /// backlog that is newly marked dropped: its history must not disappear in
    /// the same pass merely because the original event is old.
    private func pruneHistory(on db: Database) async throws {
        guard let sql = db as? SQLDatabase else { return }
        let cutoff = Date().addingTimeInterval(-Double(Self.historyRetentionDays) * 86_400)
        // Keep the terminal predicate literal so PostgreSQL can use the
        // matching partial retention index even after choosing a generic plan.
        try await sql.raw(
            """
            DELETE FROM webhook_deliveries
            WHERE status <> 'pending'
              AND updated_at < \(bind: cutoff)
            """
        ).run()
    }

    private struct QueueTelemetryRow: Decodable {
        let subscriptionID: UUID
        let pendingCount: Int
        let oldestPendingAt: Date?
        let droppedCount: Int
    }

    /// Queue telemetry is diagnostic only: an exporter or measurement-query
    /// failure must never stop the durable drain.
    private func recordQueueTelemetry(on db: Database) async {
        guard let sql = db as? SQLDatabase else { return }
        do {
            let rows = try await sql.raw(
                """
                SELECT subscription.id AS "subscriptionID",
                       count(delivery.id) FILTER (
                           WHERE delivery.status = \(bind: WebhookDeliveryStatus.pending.rawValue)
                       )::bigint AS "pendingCount",
                       min(delivery.created_at) FILTER (
                           WHERE delivery.status = \(bind: WebhookDeliveryStatus.pending.rawValue)
                       ) AS "oldestPendingAt",
                       count(delivery.id) FILTER (
                           WHERE delivery.status = \(bind: WebhookDeliveryStatus.dropped.rawValue)
                       )::bigint AS "droppedCount"
                FROM webhook_subscriptions AS subscription
                LEFT JOIN webhook_deliveries AS delivery
                  ON delivery.subscription_id = subscription.id
                 AND delivery.status IN (
                     \(bind: WebhookDeliveryStatus.pending.rawValue),
                     \(bind: WebhookDeliveryStatus.dropped.rawValue)
                 )
                GROUP BY subscription.id
                """
            ).all(decoding: QueueTelemetryRow.self)
            let pendingBySubscription = Dictionary(
                uniqueKeysWithValues: rows.map { ($0.subscriptionID, $0.pendingCount) })
            let oldestPendingAt = rows.compactMap(\.oldestPendingAt).min()
            let currentSubscriptionIDs = Set(rows.map(\.subscriptionID))
            let removedSubscriptionIDs = measuredSubscriptionIDs.withLockedValue { previous in
                defer { previous = currentSubscriptionIDs }
                return previous.subtracting(currentSubscriptionIDs)
            }
            for subscriptionID in removedSubscriptionIDs {
                Telemetry.removeWebhookDeliverySubscriptionQueueMetric(
                    subscriptionID: subscriptionID)
            }
            Telemetry.recordWebhookDeliveryQueue(
                pendingCount: rows.reduce(0) { $0 + $1.pendingCount },
                oldestPendingAgeSeconds: oldestPendingAt.map {
                    max(Date().timeIntervalSince($0), 0)
                },
                droppedCount: rows.reduce(0) { $0 + $1.droppedCount },
                subscriptionIDs: Array(currentSubscriptionIDs),
                pendingBySubscription: pendingBySubscription)
        } catch {
            logger.warning(
                "Could not measure webhook delivery queue",
                metadata: ["error": .string("\(error)")])
        }
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
