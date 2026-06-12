import Vapor

/// Emits one structured log line per HTTP request with method, path, status, and
/// duration. Registered as the outermost middleware so the timing and status
/// reflect the full request (including anything downstream middleware does).
///
/// Gated by the `REQUEST_LOGGING` env var; see `configure.swift` for the default
/// (on outside `.production`). There was previously no request logging at all,
/// which left the control plane silent about the traffic it was handling.
struct RequestLoggingMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let start = DispatchTime.now()

        func elapsedMilliseconds() -> Double {
            let nanos = DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
            return Double(nanos) / 1_000_000
        }

        do {
            let response = try await next.respond(to: request)
            request.logger.info("http_request", metadata: [
                "method": .string(request.method.rawValue),
                "path": .string(request.url.path),
                "status": .stringConvertible(response.status.code),
                "durationMs": .stringConvertible(elapsedMilliseconds())
            ])
            return response
        } catch {
            // An error propagated past downstream middleware (e.g. no ErrorMiddleware
            // converted it). Still record the request so failures aren't invisible.
            request.logger.error("http_request_failed", metadata: [
                "method": .string(request.method.rawValue),
                "path": .string(request.url.path),
                "durationMs": .stringConvertible(elapsedMilliseconds()),
                "error": .string(String(reflecting: error))
            ])
            throw error
        }
    }
}
