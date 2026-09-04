import Foundation
import MetricsTestKit
import StratoShared
import Testing

@testable import App

@Suite("Telemetry support")
struct TelemetrySupportTests {

    // MARK: - Duration.asSeconds

    @Test("whole seconds convert exactly")
    func wholeSeconds() {
        #expect(Duration.seconds(5).asSeconds == 5.0)
        #expect(Duration.zero.asSeconds == 0.0)
    }

    @Test("sub-second durations carry fractional precision")
    func fractionalSeconds() {
        #expect(abs(Duration.milliseconds(250).asSeconds - 0.25) < 1e-9)
        #expect(abs(Duration.microseconds(1500).asSeconds - 0.0015) < 1e-9)
    }

    @Test("combined seconds and fraction sum together")
    func combined() {
        let duration = Duration.seconds(2) + Duration.milliseconds(500)
        #expect(abs(duration.asSeconds - 2.5) < 1e-9)
    }

    // MARK: - IPAMError.metricReason

    @Test("each IPAM error maps to a low-cardinality metric reason")
    func ipamMetricReasons() {
        #expect(IPAMService.IPAMError.poolExhausted(network: "n", subnet: "s").metricReason == "pool_exhausted")
        #expect(IPAMService.IPAMError.invalidSubnet("s").metricReason == "invalid_subnet")
        #expect(IPAMService.IPAMError.invalidGateway("g").metricReason == "invalid_gateway")
    }

    // MARK: - Desired-state poll dimensions

    @Test("desired-state requests map to two bounded poll modes")
    func desiredStatePollModes() {
        #expect(Telemetry.DesiredStatePollMode.from(ifNoneMatch: nil) == .unconditional)
        #expect(Telemetry.DesiredStatePollMode.from(ifNoneMatch: "\"etag\"") == .conditional)
        #expect(
            Set(Telemetry.DesiredStatePollMode.allCases.map(\.rawValue))
                == Set(["conditional", "unconditional"]))
    }

    @Test("desired-state poll outcomes are a bounded dimension")
    func desiredStatePollOutcomes() {
        #expect(
            Set(Telemetry.DesiredStatePollOutcome.allCases.map(\.rawValue))
                == Set(["served", "not_modified", "assembly_budget_exhausted", "park_refused"]))
    }

    // MARK: - Webhook delivery

    @Test("webhook delivery results are a bounded metric dimension")
    func webhookDeliveryResults() {
        #expect(
            Set(Telemetry.WebhookDeliveryResult.allCases.map(\.rawValue))
                == Set(["succeeded", "failed", "dead"]))
    }

    @Test("webhook queue snapshots record totals, per-subscription depth, and recovery zeroes")
    func webhookQueueSnapshot() throws {
        let metrics = TestMetrics()
        let backedUp = UUID(uuidString: "975C249E-7A7D-407D-9037-7264A8E0096F")!
        let empty = UUID(uuidString: "6E813091-35A4-4F58-84BD-42932BAC8A8B")!

        Telemetry.recordWebhookDeliveryQueue(
            pendingCount: 3,
            oldestPendingAgeSeconds: 42.5,
            droppedCount: 2,
            subscriptionIDs: [backedUp, empty],
            pendingBySubscription: [backedUp: 3],
            factory: metrics)

        let total = try metrics.expectGauge("strato_webhook_delivery_pending")
        let oldest = try metrics.expectGauge(
            "strato_webhook_delivery_oldest_pending_age_seconds")
        let dropped = try metrics.expectGauge("strato_webhook_delivery_dropped")
        let backedUpDepth = try metrics.expectGauge(
            "strato_webhook_delivery_subscription_pending",
            [("subscription_id", backedUp.uuidString)])
        let emptyDepth = try metrics.expectGauge(
            "strato_webhook_delivery_subscription_pending",
            [("subscription_id", empty.uuidString)])
        #expect(total.lastValue == 3)
        #expect(oldest.lastValue == 42.5)
        #expect(dropped.lastValue == 2)
        #expect(backedUpDepth.lastValue == 3)
        #expect(emptyDepth.lastValue == 0)

        Telemetry.recordWebhookDeliveryQueue(
            pendingCount: 0,
            oldestPendingAgeSeconds: nil,
            droppedCount: 0,
            subscriptionIDs: [backedUp, empty],
            pendingBySubscription: [:],
            factory: metrics)

        #expect(total.lastValue == 0)
        #expect(oldest.lastValue == 0)
        #expect(dropped.lastValue == 0)
        #expect(backedUpDepth.lastValue == 0)
        #expect(emptyDepth.lastValue == 0)

        Telemetry.removeWebhookDeliverySubscriptionQueueMetric(
            subscriptionID: backedUp, factory: metrics)
        #expect(throws: (any Error).self) {
            try metrics.expectGauge(
                "strato_webhook_delivery_subscription_pending",
                [("subscription_id", backedUp.uuidString)])
        }
    }

    @Test("webhook delivery counters accept aggregate pass counts")
    func webhookDeliveryCounters() throws {
        let metrics = TestMetrics()

        Telemetry.webhookDeliveryAttempted(count: 7, factory: metrics)
        Telemetry.webhookDeliveryFinished(result: .succeeded, count: 4, factory: metrics)
        Telemetry.webhookDeliveryFinished(result: .failed, count: 2, factory: metrics)
        Telemetry.webhookDeliveryFinished(result: .dead, factory: metrics)

        #expect(
            try metrics.expectCounter("strato_webhook_delivery_attempts_total").totalValue
                == 7)
        #expect(
            try metrics.expectCounter(
                "strato_webhook_delivery_results_total", [("result", "succeeded")]
            ).totalValue == 4)
        #expect(
            try metrics.expectCounter(
                "strato_webhook_delivery_results_total", [("result", "failed")]
            ).totalValue == 2)
        #expect(
            try metrics.expectCounter(
                "strato_webhook_delivery_results_total", [("result", "dead")]
            ).totalValue == 1)
    }

    // MARK: - Volume I/O limits

    @Test("volume I/O metrics aggregate bounded configured, applied, and observed values")
    func volumeIOMetrics() throws {
        let metrics = TestMetrics()
        Telemetry.recordVolumeIO(
            agentName: "compute-1",
            samples: [
                Telemetry.VolumeIOSample(
                    configured: VolumeIOLimits(iopsTotal: 1_000, bpsTotal: 10_000_000),
                    applied: VolumeIOLimits(iopsTotal: 1_000, bpsTotal: 10_000_000),
                    observedRate: VolumeIOObservedRate(
                        iops: 950, bytesPerSecond: 4_000_000)),
                Telemetry.VolumeIOSample(
                    configured: VolumeIOLimits(iopsTotal: 500),
                    applied: nil,
                    observedRate: nil),
            ],
            factory: metrics)

        let iops = [("agent", "compute-1"), ("dimension", "iops")]
        let bytes = [("agent", "compute-1"), ("dimension", "bytes_per_second")]
        #expect(
            try metrics.expectGauge("strato_volume_io_configured_limit_total", iops).lastValue
                == 1_500)
        #expect(
            try metrics.expectGauge("strato_volume_io_applied_limit_total", iops).lastValue
                == 1_000)
        #expect(
            try metrics.expectGauge("strato_volume_io_observed_rate_total", bytes).lastValue
                == 4_000_000)
        #expect(
            try metrics.expectGauge("strato_volume_io_configured_volumes", iops).lastValue == 2)
        #expect(
            try metrics.expectGauge("strato_volume_io_applied_volumes", iops).lastValue == 1)
        #expect(
            try metrics.expectGauge(
                "strato_volume_io_observed_at_ceiling_volumes", iops
            ).lastValue == 1)

        Telemetry.recordVolumeIO(agentName: "compute-1", samples: [], factory: metrics)
        #expect(
            try metrics.expectGauge("strato_volume_io_configured_limit_total", iops).lastValue == 0)
        #expect(
            try metrics.expectGauge("strato_volume_io_observed_rate_total", bytes).lastValue == 0)
    }

    // MARK: - Security-record delivery

    @Test("security-record loss dimensions are bounded")
    func securityRecordLossDimensions() {
        #expect(
            Set(Telemetry.SecurityRecordStream.allCases.map(\.rawValue))
                == ["audit", "iam_decision"])
        #expect(
            Set(Telemetry.SecurityRecordLossCause.allCases.map(\.rawValue))
                == [
                    "queue_count_limit", "queue_byte_limit", "record_too_large",
                    "delivery_failure", "incomplete_shutdown",
                ])
        #expect(
            Set(Telemetry.SecurityRecordDestination.allCases.map(\.rawValue))
                == ["all", "database", "log", "loki", "webhook"])
    }

    @Test("security-record losses carry stream, cause, and destination")
    func securityRecordLossCounter() throws {
        let metrics = TestMetrics()

        Telemetry.securityRecordsLost(
            stream: .audit,
            cause: .deliveryFailure,
            destination: .database,
            count: 3,
            factory: metrics)

        #expect(
            try metrics.expectCounter(
                "strato_security_records_lost_total",
                [
                    ("stream", "audit"),
                    ("cause", "delivery_failure"),
                    ("destination", "database"),
                ]
            ).totalValue == 3)
    }

    // MARK: - SchedulerService.placementOutcome

    @Test("scheduler errors classify as no_candidate")
    func placementOutcomeNoCandidate() {
        #expect(SchedulerService.placementOutcome(for: SchedulerError.noAvailableAgents) == "no_candidate")
        #expect(
            SchedulerService.placementOutcome(for: SchedulerError.architectureMismatch(required: .arm64))
                == "no_candidate")
    }

    @Test("any other error classifies as error")
    func placementOutcomeError() {
        struct Unexpected: Error {}
        #expect(SchedulerService.placementOutcome(for: Unexpected()) == "error")
    }
}
