import Vapor

/// Adds standard HTTP security headers to every response — including error
/// responses, since `ErrorMiddleware` has already turned thrown errors into a
/// `Response` by the time it propagates back through here.
///
/// Registered as one of the outermost middlewares (see `configure.swift`) so the
/// headers land on API JSON, static assets, and error pages alike.
///
/// `Content-Security-Policy` is only applied when the handler hasn't already set
/// one, so endpoints that need a looser policy (e.g. `/api/docs`, which loads
/// Swagger UI from a CDN) can opt out by supplying their own.
///
/// HSTS is gated on `enableHSTS` because `Strict-Transport-Security` must only be
/// sent over HTTPS; sending it from a plaintext dev server would pin browsers to
/// an https:// origin that doesn't exist locally.
struct SecurityHeadersMiddleware: AsyncMiddleware {
    /// Send `Strict-Transport-Security`. Enable only when served behind TLS.
    let enableHSTS: Bool

    /// Default policy for responses that don't set their own. Locks the control
    /// plane to same-origin resources and forbids being framed.
    static let defaultContentSecurityPolicy =
        "default-src 'self'; frame-ancestors 'none'; base-uri 'self'; object-src 'none'"

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)

        response.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        response.headers.replaceOrAdd(name: "X-Frame-Options", value: "DENY")
        response.headers.replaceOrAdd(name: "Referrer-Policy", value: "strict-origin-when-cross-origin")

        if enableHSTS {
            response.headers.replaceOrAdd(
                name: "Strict-Transport-Security",
                value: "max-age=31536000; includeSubDomains"
            )
        }

        if !response.headers.contains(name: "Content-Security-Policy") {
            response.headers.replaceOrAdd(
                name: "Content-Security-Policy",
                value: Self.defaultContentSecurityPolicy
            )
        }

        return response
    }
}
