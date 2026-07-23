import Foundation
import Vapor

// MARK: - Issuance metrics provider

/// SVID issuance counts over a rolling window, backing the Workload Identity
/// view's "Issuance" panel.
///
/// The control plane is not in the SVID signing path — the SPIRE server signs
/// SVIDs and emits the counters — so issuance figures come from an external
/// metrics store rather than control-plane state. The provider is an
/// abstraction so the controller can be tested without a live Prometheus.
public protocol SPIREIssuanceMetricsProvider: Sendable {
    /// Fetch X.509-SVID and JWT-SVID signing counts over the configured window.
    /// Throws when the metrics store cannot be reached or its response does not
    /// parse — callers surface that as an "unavailable" panel, never a 500.
    func issuanceCounts(client: any Client) async throws -> SPIREIssuanceCounts
}

/// SVID signings observed over `windowHours`.
public struct SPIREIssuanceCounts: Sendable, Equatable {
    public let windowHours: Int
    public let x509SVIDs: Int
    public let jwtSVIDs: Int

    public init(windowHours: Int, x509SVIDs: Int, jwtSVIDs: Int) {
        self.windowHours = windowHours
        self.x509SVIDs = x509SVIDs
        self.jwtSVIDs = jwtSVIDs
    }
}

// MARK: - Configuration

/// Where and how to query issuance telemetry from Prometheus.
///
/// The default metric names are the SPIRE server's CA-signing counters
/// (`server_ca sign x509_svid` / `jwt_svid`, exported by the go-metrics
/// Prometheus sink under the `spire_server` service prefix). They are
/// overridable because SPIRE's telemetry prefix and exact metric names can
/// differ by version and sink configuration.
public struct SPIREIssuanceMetricsConfig: Sendable, Equatable {
    /// Base URL of the Prometheus HTTP API (e.g. `http://prometheus:9090`).
    public let prometheusBaseURL: String
    /// Counter metric for X.509-SVID signings.
    public let x509SVIDMetric: String
    /// Counter metric for JWT-SVID signings.
    public let jwtSVIDMetric: String
    /// Rolling window, in hours, for the `increase()` range.
    public let windowHours: Int

    public init(
        prometheusBaseURL: String,
        x509SVIDMetric: String = "spire_server_server_ca_sign_x509_svid",
        jwtSVIDMetric: String = "spire_server_server_ca_sign_jwt_svid",
        windowHours: Int = 24
    ) {
        self.prometheusBaseURL = prometheusBaseURL
        self.x509SVIDMetric = x509SVIDMetric
        self.jwtSVIDMetric = jwtSVIDMetric
        self.windowHours = windowHours
    }

    /// Build from the environment, or nil when issuance metrics are not
    /// configured (`SPIRE_METRICS_PROMETHEUS_URL` unset/empty). A window of
    /// zero or less falls back to 24h so a misconfiguration cannot produce a
    /// nonsensical `increase()` range.
    public static func fromEnvironment() -> SPIREIssuanceMetricsConfig? {
        guard let baseURL = Environment.get("SPIRE_METRICS_PROMETHEUS_URL"),
            !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }

        let window = Environment.get("SPIRE_ISSUANCE_WINDOW_HOURS").flatMap(Int.init)
        return SPIREIssuanceMetricsConfig(
            prometheusBaseURL: baseURL.trimmingCharacters(in: .whitespaces),
            x509SVIDMetric: Environment.get("SPIRE_METRICS_X509_SVID_METRIC")
                ?? "spire_server_server_ca_sign_x509_svid",
            jwtSVIDMetric: Environment.get("SPIRE_METRICS_JWT_SVID_METRIC")
                ?? "spire_server_server_ca_sign_jwt_svid",
            windowHours: (window ?? 24) > 0 ? (window ?? 24) : 24
        )
    }
}

// MARK: - Prometheus provider

/// Queries a Prometheus HTTP API for SPIRE SVID-signing counts using
/// `sum(increase(<metric>[<window>h]))` instant queries.
public struct PrometheusIssuanceMetricsProvider: SPIREIssuanceMetricsProvider {
    private let config: SPIREIssuanceMetricsConfig
    private let logger: Logger

    public init(config: SPIREIssuanceMetricsConfig, logger: Logger) {
        self.config = config
        self.logger = logger
    }

    public func issuanceCounts(client: any Client) async throws -> SPIREIssuanceCounts {
        async let x509 = query(config.x509SVIDMetric, client: client)
        async let jwt = query(config.jwtSVIDMetric, client: client)
        return SPIREIssuanceCounts(
            windowHours: config.windowHours,
            x509SVIDs: try await x509,
            jwtSVIDs: try await jwt
        )
    }

    /// Run one `sum(increase(metric[<window>h]))` instant query and return the
    /// rounded scalar result (0 when the series is absent — a metric that has
    /// never been emitted reads as no issuance rather than an error).
    private func query(_ metric: String, client: any Client) async throws -> Int {
        let promQL = "sum(increase(\(metric)[\(config.windowHours)h]))"
        guard
            let encoded = promQL.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
            let uri = Self.queryURI(base: config.prometheusBaseURL, encodedQuery: encoded)
        else {
            throw SPIREIssuanceMetricsError.invalidConfiguration(
                "Could not build a Prometheus query URL from base \(Self.sanitizedBaseURL(config.prometheusBaseURL))"
            )
        }

        let response: ClientResponse
        do {
            response = try await client.get(uri)
        } catch {
            throw SPIREIssuanceMetricsError.unreachable(
                "\(Self.sanitizedBaseURL(config.prometheusBaseURL)): \(error)")
        }

        guard response.status == .ok else {
            throw SPIREIssuanceMetricsError.requestFailed(
                "Prometheus returned \(response.status.code) for \(metric)")
        }

        let body = response.body.map { Data(buffer: $0) } ?? Data()
        let parsed: PrometheusQueryResponse
        do {
            parsed = try JSONDecoder().decode(PrometheusQueryResponse.self, from: body)
        } catch {
            throw SPIREIssuanceMetricsError.requestFailed("Prometheus response did not parse: \(error)")
        }
        guard parsed.status == "success" else {
            throw SPIREIssuanceMetricsError.requestFailed(
                "Prometheus query status was '\(parsed.status)' for \(metric)")
        }

        return Self.sumInstantVector(parsed.data?.result ?? [])
    }

    /// Sum an instant-vector query result and round to a whole SVID count.
    /// `increase()` is a float estimate; a `sum(...)` yields at most one sample.
    /// `Int(exactly:)` returns nil for NaN/Inf and for finite totals that
    /// overflow `Int`, so an implausibly large or bad result collapses to 0
    /// rather than trapping in `Int(_:)`.
    static func sumInstantVector(_ samples: [PrometheusSample]) -> Int {
        let total = samples.reduce(0.0) { $0 + $1.value }
        return Int(exactly: total.rounded()) ?? 0
    }

    /// A Prometheus base URL reduced to `scheme://host[:port]` for use in
    /// errors and logs — userinfo (basic-auth credentials or tokens), path, and
    /// query are dropped so they never reach a user-facing warning or a log.
    static func sanitizedBaseURL(_ raw: String) -> String {
        guard let components = URLComponents(string: raw), let host = components.host else {
            return "<prometheus>"
        }
        var sanitized = ""
        if let scheme = components.scheme { sanitized += "\(scheme)://" }
        sanitized += host
        if let port = components.port { sanitized += ":\(port)" }
        return sanitized
    }

    static func queryURI(base: String, encodedQuery: String) -> URI? {
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard !trimmedBase.isEmpty else { return nil }
        return URI(string: "\(trimmedBase)/api/v1/query?query=\(encodedQuery)")
    }
}

// MARK: - Prometheus response types

/// The subset of the Prometheus `/api/v1/query` response we consume.
struct PrometheusQueryResponse: Decodable {
    let status: String
    let data: PrometheusQueryData?
}

struct PrometheusQueryData: Decodable {
    let resultType: String
    let result: [PrometheusSample]
}

/// One instant-vector sample. Its `value` is a `[<unix-ts>, "<value>"]` pair in
/// the wire format; we keep only the numeric value.
struct PrometheusSample: Decodable {
    let value: Double

    private enum CodingKeys: String, CodingKey { case value }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var pair = try container.nestedUnkeyedContainer(forKey: .value)
        _ = try pair.decode(Double.self)  // timestamp — unused
        let raw = try pair.decode(String.self)
        // Prometheus reports NaN/+Inf/-Inf as quoted strings, and `Double(_:)`
        // parses those to non-finite values (not nil), so the `?? 0` fallback
        // alone would let a NaN/Inf through to `Int(_:)`, which traps. Coerce
        // any non-numeric or non-finite sample to zero.
        let parsed = Double(raw) ?? 0
        self.value = parsed.isFinite ? parsed : 0
    }

    init(value: Double) {
        self.value = value
    }
}

// MARK: - Errors

public enum SPIREIssuanceMetricsError: Error, LocalizedError {
    case invalidConfiguration(String)
    case unreachable(String)
    case requestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let details):
            return "Invalid SPIRE issuance metrics configuration: \(details)"
        case .unreachable(let details):
            return "Prometheus unreachable: \(details)"
        case .requestFailed(let details):
            return "Prometheus request failed: \(details)"
        }
    }
}

// MARK: - Vapor Application Extension

extension Application {
    private struct SPIREIssuanceMetricsKey: StorageKey {
        typealias Value = any SPIREIssuanceMetricsProvider
    }

    /// The issuance-metrics provider backing the Workload Identity view, or nil
    /// when no metrics store is configured (the panel then reports unavailable).
    public var spireIssuanceMetrics: (any SPIREIssuanceMetricsProvider)? {
        get { storage[SPIREIssuanceMetricsKey.self] }
        set { setStorageValue(SPIREIssuanceMetricsKey.self, to: newValue) }
    }

    /// Configure SVID issuance telemetry for the Workload Identity view. No-op
    /// unless `SPIRE_METRICS_PROMETHEUS_URL` is set, so deployments without a
    /// Prometheus scraping SPIRE keep working with the panel simply unavailable.
    public func configureSPIREIssuanceMetrics() {
        guard let config = SPIREIssuanceMetricsConfig.fromEnvironment() else { return }
        spireIssuanceMetrics = PrometheusIssuanceMetricsProvider(config: config, logger: logger)
        // Sanitized so basic-auth credentials or tokens in the URL never land in logs.
        let sanitizedURL = PrometheusIssuanceMetricsProvider.sanitizedBaseURL(config.prometheusBaseURL)
        logger.info(
            "SPIRE issuance metrics configured",
            metadata: [
                "prometheusBaseURL": .string(sanitizedURL),
                "windowHours": .string("\(config.windowHours)"),
            ])
    }
}
