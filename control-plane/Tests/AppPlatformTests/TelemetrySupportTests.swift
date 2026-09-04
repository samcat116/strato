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

    // MARK: - Resource pressure and contention

    @Test("host metrics preserve availability and measured zero")
    func hostResourceTelemetryAvailability() throws {
        let metrics = TestMetrics()
        let some = PressureStallSample(
            average10: 17.5, average60: 8, average300: 3,
            totalMicroseconds: 2_500_000)
        let telemetry = HostResourceTelemetry(
            sampledAt: Date(timeIntervalSince1970: 1),
            health: .pressured,
            cpuPressure: .available(some: some, full: nil),
            memoryPressure: .unavailable,
            ioPressure: .unavailable,
            swapTotalBytes: .available(0),
            swapUsedBytes: .available(0),
            zswapStoredBytes: .unavailable,
            zswapPoolBytes: .unavailable,
            zramUsedBytes: .unavailable,
            majorFaultsTotal: .available(12),
            reclaimScannedPagesTotal: .available(8),
            reclaimReclaimedPagesTotal: .available(4),
            oomKillsTotal: .available(0),
            mglruEnabled: .available(false))

        Telemetry.recordHostResourceTelemetry(
            agentID: "agent-1", telemetry: telemetry, factory: metrics)

        let base = [("agent_id", "agent-1")]
        #expect(try metrics.expectGauge("strato_agent_resource_health", base).lastValue == 2)
        #expect(
            try metrics.expectGauge(
                "strato_agent_pressure_average10_percent",
                base + [("resource", "cpu"), ("stall", "some")]
            ).lastValue == 17.5)
        #expect(
            try metrics.expectGauge(
                "strato_agent_pressure_total_seconds",
                base + [("resource", "cpu"), ("stall", "some")]
            ).lastValue == 2.5)
        #expect(try metrics.expectGauge("strato_agent_swap_used_bytes", base).lastValue == 0)
        #expect(
            try metrics.expectGauge(
                "strato_agent_resource_signal_available",
                base + [("signal", "swap_used_bytes")]
            ).lastValue == 1)
        #expect(
            try metrics.expectGauge(
                "strato_agent_resource_signal_available",
                base + [("signal", "zswap_stored_bytes")]
            ).lastValue == 0)
        #expect(throws: (any Error).self) {
            try metrics.expectGauge("strato_agent_zswap_stored_bytes", base)
        }
    }

    @Test("workload metrics scale CPU time, export balloon stats, and remove finalized UUIDs")
    func workloadResourceTelemetryAndCleanup() throws {
        let metrics = TestMetrics()
        let telemetry = WorkloadResourceTelemetry(
            sampledAt: Date(timeIntervalSince1970: 2),
            health: .healthy,
            cgroupV2: .available,
            memoryCurrentBytes: .available(1_024),
            memoryEvents: WorkloadMemoryEventsTelemetry(
                availability: .available, low: 0, high: 3, max: 0,
                oom: 0, oomKill: 0, oomGroupKill: 0),
            memoryPressure: .available(
                some: PressureStallSample(
                    average10: 0.5, average60: 0.25, average300: 0.1,
                    totalMicroseconds: 1_000_000),
                full: nil),
            cpuPressure: .unavailable,
            ioPressure: .unavailable,
            cpuUsageMicroseconds: .available(2_500_000),
            cpuThrottledMicroseconds: .available(750_000),
            cpuThrottledPeriodsTotal: .available(9),
            guestStealMicroseconds: .unavailable)
        let balloon = VMMemoryStats(
            totalBytes: 8_192, availableBytes: 4_096, balloonActualBytes: 7_168)

        Telemetry.recordWorkloadResourceTelemetry(
            agentID: "agent-1", workloadID: "workload-1", kind: .vm,
            telemetry: telemetry, balloon: balloon, factory: metrics)

        let base = [
            ("agent_id", "agent-1"),
            ("workload_id", "workload-1"),
            ("kind", "vm"),
        ]
        #expect(
            try metrics.expectGauge("strato_workload_cpu_usage_seconds_total", base).lastValue
                == 2.5)
        #expect(
            try metrics.expectGauge("strato_workload_balloon_actual_bytes", base).lastValue
                == 7_168)
        #expect(
            try metrics.expectGauge(
                "strato_workload_resource_signal_available",
                base + [("signal", "guest_steal_microseconds_total")]
            ).lastValue == 0)
        #expect(throws: (any Error).self) {
            try metrics.expectGauge("strato_workload_guest_steal_seconds_total", base)
        }

        Telemetry.removeWorkloadResourceTelemetry(
            agentID: "agent-1", workloadID: "workload-1", kind: .vm,
            factory: metrics)

        #expect(throws: (any Error).self) {
            try metrics.expectGauge("strato_workload_cpu_usage_seconds_total", base)
        }
        #expect(throws: (any Error).self) {
            try metrics.expectGauge(
                "strato_workload_resource_signal_available",
                base + [("signal", "cpu_usage_microseconds_total")])
        }
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
