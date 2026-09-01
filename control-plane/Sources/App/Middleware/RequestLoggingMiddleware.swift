import StratoShared
import Vapor

/// Emits exactly one structured `http_request` log line per request — method,
/// matched route, status, duration — whether the request succeeded or failed.
/// Route parameters remain placeholders so credentials and resource identifiers
/// in concrete paths never enter the process log.
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
/// (on outside `.production`).
struct RequestLoggingMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let start = DispatchTime.now()

        func elapsedMilliseconds() -> Double {
            let nanos = DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
            return Double(nanos) / 1_000_000
        }

        func log(status: HTTPResponseStatus, error: (any Error)? = nil) {
            let route = request.secretSafeLogPath
            var metadata: Logger.Metadata = [
                "method": .string(request.method.rawValue),
                "http.route": .string(route),
                // Preserve the existing field for operator queries, but make its
                // value the same bounded route template rather than a concrete URL.
                "path": .string(route),
                "status": .stringConvertible(status.code),
                "durationMs": .stringConvertible(elapsedMilliseconds()),
            ]
            if let error {
                // Error descriptions can contain request-derived values (including
                // concrete paths), so record only the stable error type here.
                metadata["error"] = .string(String(reflecting: type(of: error)))
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

extension Request {
    /// A path that is safe to copy into process logs and metrics.
    ///
    /// Prefer the matched route because its parameters remain placeholders. A
    /// middleware that rejects before routing cannot see `route`; recognize the
    /// one credential-bearing pre-routing path explicitly and fail closed for
    /// every other unmatched request rather than logging attacker-controlled
    /// path components.
    var secretSafeLogPath: String {
        if let route {
            return "/" + route.path.map { "\($0)" }.joined(separator: "/")
        }

        let components = url.path.split(separator: "/")
        if components.count == 3,
            components[0] == "auth",
            components[1] == "claim"
        {
            return "/auth/claim/:token"
        }

        return "unmatched"
    }
}

extension ErrorMiddleware {
    /// Render Vapor-compatible error responses while emitting one always-on,
    /// secret-safe event independently of the optional access log.
    static func secretSafeDefault(environment: Environment) -> ErrorMiddleware {
        .init { request, error in
            let status: HTTPResponseStatus
            let reason: String
            var headers: HTTPHeaders

            switch error {
            case let debugAbort as (DebuggableError & AbortError):
                (reason, status, headers) = (debugAbort.reason, debugAbort.status, debugAbort.headers)
            case let abort as AbortError:
                (reason, status, headers) = (abort.reason, abort.status, abort.headers)
            case let debugError as DebuggableError:
                (reason, status, headers) = (debugError.reason, .internalServerError, [:])
            default:
                reason = environment.isRelease ? "Something went wrong." : String(describing: error)
                (status, headers) = (.internalServerError, [:])
            }

            let route = request.secretSafeLogPath
            let metadata: Logger.Metadata = [
                "method": .string(request.method.rawValue),
                "http.route": .string(route),
                "path": .string(route),
                "status": .stringConvertible(status.code),
                "error": .string(String(reflecting: type(of: error))),
                LogMetadata.Key.requestID: .string(request.id),
            ]
            if status.code >= 500 {
                request.logger.error("http_request_error", metadata: metadata)
            } else {
                request.logger.info("http_request_error", metadata: metadata)
            }

            let body: Response.Body
            do {
                let encoder = try ContentConfiguration.global.requireEncoder(for: .json)
                var buffer = request.byteBufferAllocator.buffer(capacity: 0)
                try encoder.encode(
                    RequestErrorResponse(error: true, reason: reason),
                    to: &buffer,
                    headers: &headers
                )
                body = .init(buffer: buffer, byteBufferAllocator: request.byteBufferAllocator)
            } catch {
                body = .init(
                    string: "Oops: \(String(describing: error))\nWhile encoding error: \(reason)",
                    byteBufferAllocator: request.byteBufferAllocator
                )
                headers.contentType = .plainText
            }

            return Response(status: status, headers: headers, body: body)
        }
    }
}

private struct RequestErrorResponse: Codable {
    let error: Bool
    let reason: String
}
