import Vapor

/// Surface confirmed PostgreSQL aborts even on paths that do not yet opt into
/// transaction retries. This middleware never replays an HTTP handler: it may
/// have performed an external effect before reaching the failed statement.
struct DatabaseTransientErrorMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch {
            guard let failure = DatabaseTransactionFailure.classify(error) else { throw error }
            throw DatabaseTransactionRetryExhausted(sqlState: failure.rawValue)
        }
    }
}
