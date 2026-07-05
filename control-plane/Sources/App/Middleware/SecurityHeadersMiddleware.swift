import Vapor

/// Adds standard HTTP security headers to every response — including error
/// responses. It must be registered at the *front* of the middleware chain (see
/// `configure.swift`, `at: .beginning`) so it wraps Vapor's default
/// `ErrorMiddleware`: that way a thrown error is turned into a `Response` by
/// `ErrorMiddleware` below and propagates back up through here, where the headers
/// are applied. If it sat inside `ErrorMiddleware` instead, synthesized 4xx/5xx
/// responses would bypass it entirely.
///
/// Being outermost, the headers land on API JSON, static assets, and error pages
/// alike.
///
/// `Content-Security-Policy` is only applied when the handler hasn't already set
/// one, so endpoints that need a looser policy (e.g. `/api/docs`, which loads
/// Swagger UI from a CDN) can opt out by supplying their own.
///
/// The default same-origin CSP is *not* applied to `text/html` responses. When
/// `FileMiddleware` serves the bundled Next.js frontend from `Public/`, those
/// pages carry inline hydration scripts (`self.__next_f.push(...)`) that a
/// `default-src 'self'` policy with no script nonce/hash would block, leaving the
/// UI stuck on its loading shell. HTML pages either ship their own CSP
/// (`/api/docs`) or rely on `X-Frame-Options`/`nosniff` here plus the CSP set by
/// the production frontend container; the strict default is reserved for the API
/// and static assets.
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

        let isHTML =
            response.headers.contentType.map {
                $0.type == "text" && $0.subType == "html"
            } ?? false
        if !isHTML, !response.headers.contains(name: "Content-Security-Policy") {
            response.headers.replaceOrAdd(
                name: "Content-Security-Policy",
                value: Self.defaultContentSecurityPolicy
            )
        }

        return response
    }
}
