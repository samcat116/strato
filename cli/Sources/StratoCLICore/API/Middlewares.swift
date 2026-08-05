import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Signs every request with the context's access token and, on a 401, rotates
/// the token pair once and replays the request.
struct AuthenticationMiddleware: ClientMiddleware {
    let session: CredentialSession

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        // `@concurrent` is explicit because this package enables
        // `NonisolatedNonsendingByDefault`, which would otherwise give the
        // parameter caller-isolated semantics the protocol does not declare.
        next: @concurrent @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        // Buffered up front because an `HTTPBody` may only be iterated once and
        // the retry below needs to send the same bytes again.
        var bytes: [UInt8]?
        if let body {
            bytes = try await [UInt8](collecting: body, upTo: URLSessionClientTransport.maxBodyBytes)
        }

        let stale = try await session.accessToken()
        var signed = request
        signed.headerFields[.authorization] = "Bearer \(stale)"

        let response = try await next(signed, bytes.map { HTTPBody($0) }, baseURL)
        guard response.0.status.code == 401 else { return response }

        let rotated = try await session.refreshedAccessToken(replacing: stale)
        signed.headerFields[.authorization] = "Bearer \(rotated)"
        return try await next(signed, bytes.map { HTTPBody($0) }, baseURL)
    }
}

/// Turns any non-2xx response into a `CLIError` before the generated code sees
/// it, so command bodies can read `.ok`/`.accepted` without a `switch` over
/// every documented failure. The device flow deliberately runs without this:
/// it dispatches on the OAuth error codes in a 400 body.
struct ErrorMappingMiddleware: ClientMiddleware {
    /// Error envelopes are a sentence; anything larger is a truncated excerpt.
    static let maxErrorBodyBytes = 64 * 1024

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        // `@concurrent` is explicit because this package enables
        // `NonisolatedNonsendingByDefault`, which would otherwise give the
        // parameter caller-isolated semantics the protocol does not declare.
        next: @concurrent @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let (response, responseBody) = try await next(request, body, baseURL)
        guard !(200..<300).contains(response.status.code) else { return (response, responseBody) }

        var payload = Data()
        if let responseBody {
            payload = try await Data(collecting: responseBody, upTo: Self.maxErrorBodyBytes)
        }
        throw CLIError.api(status: response.status.code, message: Self.message(from: payload))
    }

    /// Decodes Vapor's `{reason}` / generic `{error}` error bodies.
    static func message(from body: Data) -> String {
        struct VaporError: Decodable {
            let reason: String?
        }
        struct GenericError: Decodable {
            let error: String?
        }
        if let vapor = try? JSONDecoder().decode(VaporError.self, from: body), let reason = vapor.reason {
            return reason
        }
        // Vapor's `{error: true, reason: ...}` uses a Bool `error`; only treat
        // a String `error` as a message (the OAuth error shape).
        if let generic = try? JSONDecoder().decode(GenericError.self, from: body), let message = generic.error {
            return message
        }
        return String(decoding: body.prefix(200), as: UTF8.self)
    }
}
