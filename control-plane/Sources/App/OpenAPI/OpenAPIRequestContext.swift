import OpenAPIRuntime
import Vapor

/// Access to the Vapor `Request` from inside a generated OpenAPI handler.
///
/// Generated handlers (`APIProtocol`) receive only the decoded operation input,
/// so the request — and with it the database, the authenticated user, and the
/// logger — is carried across the call boundary in a task local set by
/// ``OpenAPIRequestInjectionMiddleware``. This is the pattern swift-openapi-vapor
/// documents for request injection; we use a plain task local rather than
/// pulling in swift-dependencies for it.
enum OpenAPIRequestContext {
    @TaskLocal static var current: Request?

    /// The request being served, or a 500 if a handler ran outside the transport.
    static func require() throws -> Request {
        guard let current else {
            throw Abort(.internalServerError, reason: "OpenAPI handler ran outside a request context")
        }
        return current
    }
}

/// Bridges Vapor and the generated OpenAPI handlers, in both directions.
///
/// * **Inbound** — publishes the `Request` as a task local so handlers can reach
///   `req.db` / `req.auth` (see ``OpenAPIRequestContext``).
/// * **Outbound** — unwraps `ServerError`. swift-openapi-runtime wraps anything a
///   handler throws, which would otherwise hide `Abort` from Vapor's
///   `ErrorMiddleware` and turn every deliberate 4xx into a 500. Unwrapping keeps
///   generated surfaces byte-identical to the hand-written controllers: same
///   `{"error": true, "reason": …}` envelope, same status, same logging.
///
/// Registered as the innermost middleware on the routes builder the generated
/// handlers are attached to — task locals set further out do not survive Vapor's
/// responder chain reliably.
struct OpenAPIRequestInjectionMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do {
            return try await OpenAPIRequestContext.$current.withValue(request) {
                try await next.respond(to: request)
            }
        } catch let serverError as ServerError {
            throw Self.unwrap(serverError)
        }
    }

    /// Recover the most Vapor-meaningful error inside a `ServerError`.
    static func unwrap(_ serverError: ServerError) -> any Error {
        let underlying = serverError.underlyingError
        // Deliberate 4xx/5xx from handler code: hand it to Vapor untouched.
        if let abort = underlying as? any AbortError {
            return abort
        }
        // Runtime failures the request itself caused — an undecodable body, an
        // unsupported content type — carry their own status (400, 415, …).
        if let convertible = underlying as? any HTTPResponseConvertible {
            let code = Int(convertible.httpStatus.code)
            if code < 500 {
                return Abort(HTTPResponseStatus(statusCode: code), reason: serverError.causeDescription)
            }
        }
        // Anything else is a genuine server-side failure; let Vapor log and 500 it.
        return underlying
    }
}
