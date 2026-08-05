import Foundation
import HTTPTypes
import OpenAPIRuntime

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The CLI's `ClientTransport`: plain HTTPS with bearer auth — no client
/// certificates — so `URLSession` works on both macOS and Linux. Every body is
/// buffered rather than streamed; the CLI only exchanges small JSON documents,
/// and buffering is what lets the auth middleware replay a request after a
/// token refresh.
public struct URLSessionClientTransport: ClientTransport {
    /// Ceiling on a single buffered body. Well above any JSON document the API
    /// serves; a runaway response fails loudly instead of exhausting memory.
    static let maxBodyBytes = 32 * 1024 * 1024

    public init() {}

    public func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var urlRequest = URLRequest(url: try Self.url(baseURL: baseURL, request: request))
        urlRequest.httpMethod = request.method.rawValue
        for field in request.headerFields {
            urlRequest.addValue(field.value, forHTTPHeaderField: field.name.canonicalName)
        }
        if let body {
            urlRequest.httpBody = try await Data(collecting: body, upTo: Self.maxBodyBytes)
        }

        let (data, response) = try await data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CLIError.network("Non-HTTP response from \(urlRequest.url?.absoluteString ?? "the server")")
        }
        return (
            HTTPResponse(
                status: .init(code: httpResponse.statusCode),
                headerFields: Self.headerFields(of: httpResponse)),
            HTTPBody(data)
        )
    }

    /// Joins the server URL with the operation's path and query. The generated
    /// client hands over an already percent-encoded relative path, so the two
    /// halves are spliced as components rather than re-encoded.
    static func url(baseURL: URL, request: HTTPRequest) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
            let requestComponents = URLComponents(string: request.path ?? "")
        else {
            throw CLIError.network("Could not build a request URL from \(baseURL.absoluteString)")
        }
        // Operation paths are absolute, so a server URL written with a trailing
        // slash would otherwise produce `//api/...`. Any path prefix before it
        // is kept: a control plane may be mounted under one.
        var prefix = components.percentEncodedPath
        while prefix.hasSuffix("/") { prefix.removeLast() }
        components.percentEncodedPath = prefix + requestComponents.percentEncodedPath
        components.percentEncodedQuery = requestComponents.percentEncodedQuery
        guard let url = components.url else {
            throw CLIError.network("Could not build a request URL from \(baseURL.absoluteString)")
        }
        return url
    }

    private static func headerFields(of response: HTTPURLResponse) -> HTTPFields {
        var fields = HTTPFields()
        for (name, value) in response.allHeaderFields {
            guard let name = name as? String, let value = value as? String,
                let fieldName = HTTPField.Name(name)
            else { continue }
            fields[fieldName] = value
        }
        return fields
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        #if canImport(FoundationNetworking)
        // swift-corelibs-foundation's async URLSession bridge; wrapped so a
        // cancelled Task can't leak the continuation.
        return try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: CLIError.network("Empty response"))
                }
            }.resume()
        }
        #else
        return try await URLSession.shared.data(for: request)
        #endif
    }
}
