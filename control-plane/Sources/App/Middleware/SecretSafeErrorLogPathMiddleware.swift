import Vapor

/// Removes concrete paths and queries before Vapor's error middleware records
/// a failed request. This middleware must remain immediately inside
/// `ErrorMiddleware` so downstream logging can still use the original request
/// while the outer error reporter sees only the safe route pattern.
struct SecretSafeErrorLogPathMiddleware: AsyncMiddleware {
    func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch {
            request.url = URI(path: request.secretSafeLogPath)
            throw error
        }
    }
}
