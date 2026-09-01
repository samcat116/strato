import StratoShared
import Vapor

/// Copies Vapor's request identifier into Strato's canonical log taxonomy.
///
/// Vapor creates each request logger with `request-id`. Keep that provider-owned
/// key through the bounded STR-284 compatibility window, while adding the
/// canonical key for control-plane console and OTLP sinks.
struct RequestLogMetadataMiddleware: AsyncMiddleware {
    func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        var logger = request.logger
        logger[metadataKey: LogMetadata.Key.requestID] = .string(request.id)
        request.logger = logger
        return try await next.respond(to: request)
    }
}
