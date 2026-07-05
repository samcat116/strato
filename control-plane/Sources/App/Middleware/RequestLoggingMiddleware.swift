import Vapor

/// Emits exactly one structured `http_request` log line per request — method,
/// path, status, duration — whether the request succeeded or failed.
///
/// On the error path the request may be turned into its HTTP response by a
/// downstream middleware (`ErrorMiddleware`) *after* it propagates back through
/// here as a thrown error, so we can't read the status off a `Response`. Instead
/// we derive the status the client will ultimately see from the thrown error
/// (`AbortError.status`, else `500`). This keeps the "one status-bearing line per
/// request" guarantee regardless of where this middleware sits in the stack — so
/// common 401/403/404 `Abort`s still get logged with their real status.
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

        func log(status: HTTPResponseStatus, error: (any Error)? = nil) {
            var metadata: Logger.Metadata = [
                "method": .string(request.method.rawValue),
                "path": .string(request.url.path),
                "status": .stringConvertible(status.code),
                "durationMs": .stringConvertible(elapsedMilliseconds()),
            ]
            if let error {
                metadata["error"] = .string(String(reflecting: error))
            }
            // Server-side failures are worth surfacing at error level; everything
            // else (incl. expected 4xx) stays at info so it's one uniform line.
            if status.code >= 500 {
                request.logger.error("http_request", metadata: metadata)
            } else {
                request.logger.info("http_request", metadata: metadata)
            }
        }

        do {
            let response = try await next.respond(to: request)
            log(status: response.status)
            return response
        } catch {
            // Mirror how ErrorMiddleware maps the error to a response status so the
            // logged status matches what the client receives, then rethrow.
            let status = (error as? any AbortError)?.status ?? .internalServerError
            log(status: status, error: error)
            throw error
        }
    }
}
