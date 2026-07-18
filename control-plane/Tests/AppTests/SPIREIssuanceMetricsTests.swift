import Foundation
import Testing

@testable import App

/// Tests for the Prometheus issuance-metrics parsing: decoding the instant
/// vector samples and summing them into a whole SVID count without trapping on
/// the special (non-finite) values Prometheus can return.
@Suite("SPIRE Issuance Metrics Tests")
struct SPIREIssuanceMetricsTests {

    private func decodeSample(_ json: String) throws -> PrometheusSample {
        try JSONDecoder().decode(PrometheusSample.self, from: Data(json.utf8))
    }

    @Test("Decodes a normal instant-vector sample value")
    func decodesNumericSample() throws {
        let sample = try decodeSample(#"{"metric":{},"value":[1710000000,"1280.4"]}"#)
        #expect(sample.value == 1280.4)
    }

    @Test("Coerces NaN / Inf / -Inf samples to zero instead of trapping")
    func coercesNonFiniteSamples() throws {
        // Prometheus sends these as quoted strings; Double(_:) parses them to
        // non-finite values (not nil), which would trap in Int(_:) downstream.
        for raw in ["NaN", "Inf", "+Inf", "-Inf"] {
            let sample = try decodeSample(#"{"metric":{},"value":[0,"\#(raw)"]}"#)
            #expect(sample.value == 0, "expected \(raw) to coerce to 0")
        }
    }

    @Test("Sums samples and rounds to a whole count")
    func sumsAndRounds() {
        let total = PrometheusIssuanceMetricsProvider.sumInstantVector([
            PrometheusSample(value: 12.6),
            PrometheusSample(value: 0.4),
        ])
        #expect(total == 13)
    }

    @Test("An empty result set sums to zero")
    func emptySumsToZero() {
        #expect(PrometheusIssuanceMetricsProvider.sumInstantVector([]) == 0)
    }

    @Test("A non-finite total collapses to zero rather than trapping")
    func nonFiniteTotalIsZero() {
        // Defense in depth: even if a non-finite value reached the summer, the
        // conversion to Int must not trap.
        let total = PrometheusIssuanceMetricsProvider.sumInstantVector([
            PrometheusSample(value: .infinity)
        ])
        #expect(total == 0)
    }

    @Test("An oversized finite total collapses to zero rather than trapping")
    func oversizedTotalIsZero() {
        // A finite value far beyond Int.max would trap Int(_:); Int(exactly:)
        // returns nil and we fall back to 0.
        let total = PrometheusIssuanceMetricsProvider.sumInstantVector([
            PrometheusSample(value: 1e30)
        ])
        #expect(total == 0)
    }

    @Test("Sanitizes credentials and path out of the Prometheus base URL")
    func sanitizesBaseURL() {
        #expect(
            PrometheusIssuanceMetricsProvider.sanitizedBaseURL("http://user:token@prometheus:9090/foo?x=1")
                == "http://prometheus:9090")
        #expect(
            PrometheusIssuanceMetricsProvider.sanitizedBaseURL("http://prometheus:9090") == "http://prometheus:9090")
        // Unparseable input reveals nothing.
        #expect(PrometheusIssuanceMetricsProvider.sanitizedBaseURL("not a url") == "<prometheus>")
    }

    @Test("Builds the Prometheus query URL, trimming a trailing slash")
    func buildsQueryURI() {
        let uri = PrometheusIssuanceMetricsProvider.queryURI(
            base: "http://prometheus:9090/", encodedQuery: "abc")
        #expect(uri?.string == "http://prometheus:9090/api/v1/query?query=abc")
    }
}
