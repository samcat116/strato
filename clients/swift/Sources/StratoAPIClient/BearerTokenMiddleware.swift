import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Attaches a Strato API key to every request as `Authorization: Bearer …`.
///
/// The control plane accepts two schemes interchangeably (`bearerAuth` for API
/// keys, `cookieAuth` for a passkey session); API keys are the programmatic one,
/// so this ships with the client rather than being rewritten per consumer.
public struct BearerTokenMiddleware: ClientMiddleware {
    private let token: String

    public init(token: String) {
        self.token = token
    }

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        request.headerFields[.authorization] = "Bearer \(token)"
        return try await next(request, body, baseURL)
    }
}
