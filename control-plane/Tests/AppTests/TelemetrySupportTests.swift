import Foundation
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
}
