import Vapor

/// Emits exactly one structured `http_request` log line per request — method,
/// route template, status, duration — whether the request succeeded or failed.
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
            var routeSegments: [String]?
            if let matchedRoute = request.route {
                routeSegments = matchedRoute.path.map { "\($0)" }
            }
            let route = MetricsMiddleware.routeLabel(fromSegments: routeSegments)
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

extension Application {
    /// Replace Vapor's default concrete-path access logger with Strato's
    /// route-template logger while retaining Vapor's default error responses.
    /// This must run before the rest of the application middleware is added.
    func configureRequestLogging(enabled: Bool) {
        var configuredMiddleware = Middlewares()
        configuredMiddleware.use(ErrorMiddleware.requestLogSafeDefault(environment: environment))
        if enabled {
            configuredMiddleware.use(RequestLoggingMiddleware())
        }
        middleware = configuredMiddleware

        if enabled {
            logger.info("Request logging enabled")
        }
    }
}

extension ErrorMiddleware {
    /// Vapor's default error middleware reports the concrete request URL and the
    /// full error description. Render the same response without creating a second,
    /// secret-bearing request log; `RequestLoggingMiddleware` records the safe event.
    fileprivate static func requestLogSafeDefault(environment: Environment) -> ErrorMiddleware {
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
