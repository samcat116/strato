import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A single HTTP exchange, abstracted so tests can script responses without a
/// network.
public struct TransportRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct TransportResponse: Sendable {
    public var statusCode: Int
    public var body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: TransportRequest) async throws -> TransportResponse
}

/// The real transport. Plain HTTPS with bearer auth — no client certificates —
/// so URLSession works on both macOS and Linux.
public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: TransportRequest) async throws -> TransportResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CLIError.network("Non-HTTP response from \(request.url)")
        }
        return TransportResponse(statusCode: httpResponse.statusCode, body: data)
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
