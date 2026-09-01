import Vapor

/// Emits RED metrics (request count + duration) for every HTTP request, so the
/// whole API surface is observable without per-route instrumentation.
///
/// Labels are kept low-cardinality on purpose: `route` is the *matched route
/// pattern* (`/api/vms/:vmID`), never the concrete path, so a million VMs still
/// map to one series; unmatched requests (genuine 404s with no route) fall back
/// to `unmatched`. The counter buckets status by class (`2xx`/`4xx`/`5xx`),
/// while the duration timer carries only method + route.
///
/// Like `RequestLoggingMiddleware`, the ultimate client-visible status on the
/// error path is derived from the thrown error rather than a `Response`, since
/// `ErrorMiddleware` downstream turns the error into a response only after it
/// propagates back through here. `request.route` is populated by the router
/// during `next.respond`, so it is read after the call completes.
///
/// Emission goes through the swift-metrics facade, which is a no-op unless
/// OpenTelemetry is bootstrapped (see `Telemetry`), so this costs nothing when
/// metrics are disabled.
struct MetricsMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let clock = ContinuousClock()
        let start = clock.now

        func record(statusCode: UInt) {
            let method = request.method.rawValue
            let statusClass = "\(statusCode / 100)xx"
            let durationSeconds = (clock.now - start).asSeconds
            let route = request.safeLogRoute
            Telemetry.recordHTTPRequest(
                method: method,
                route: route,
                statusClass: statusClass,
                durationSeconds: durationSeconds
            )
        }

        do {
            let response = try await next.respond(to: request)
            record(statusCode: response.status.code)
            return response
        } catch {
            let status = (error as? any AbortError)?.status ?? .internalServerError
            record(statusCode: status.code)
            throw error
        }
    }

    /// The low-cardinality `route` label built from the matched route's path
    /// segments (e.g. `["api", "vms", ":vmID"]` -> `/api/vms/:vmID`), or
    /// `unmatched` when routing found no route (a genuine 404). Takes plain
    /// strings — the caller maps the route's `PathComponent`s to their
    /// descriptions — so the derivation stays unit-testable without standing up
    /// a `Request` and without naming the ambiguous `PathComponent` type.
    static func routeLabel(fromSegments segments: [String]?) -> String {
        guard let segments else { return "unmatched" }
        return "/" + segments.joined(separator: "/")
    }
}

extension Request {
    /// A bounded route label safe for logs and metrics. Vapor populates `route`
    /// before middleware runs for matched requests; genuine unmatched requests
    /// use one constant rather than any attacker-controlled URL component.
    var safeLogRoute: String {
        let routeSegments = route?.path.map { "\($0)" }
        return MetricsMiddleware.routeLabel(fromSegments: routeSegments)
    }
}
