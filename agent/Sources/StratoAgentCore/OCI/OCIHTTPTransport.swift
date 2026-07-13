import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A single HTTP request the OCI client wants performed. Deliberately tiny —
/// the client owns auth, retries, and redirects; the transport just moves
/// bytes — so tests drive the whole client through a scripted transport.
public struct OCIHTTPRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]

    public init(method: String = "GET", url: URL, headers: [String: String] = [:]) {
        self.method = method
        self.url = url
        self.headers = headers
    }
}

/// A buffered HTTP response (manifests, token JSON — always small).
public struct OCIHTTPResponse: Sendable {
    public let statusCode: Int
    /// Header names lowercased, so lookups are case-insensitive.
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = Dictionary(
            headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

/// HTTP for the OCI registry client. Implementations MUST NOT follow
/// redirects: registries redirect blob downloads to pre-signed CDN URLs, and
/// the client must see the 3xx itself so it can drop the `Authorization`
/// header before following (a forwarded registry token breaks S3-style signed
/// URLs and leaks the token to a third party).
public protocol OCIHTTPTransport: Sendable {
    /// Performs the request and buffers the whole body (small responses only:
    /// manifests, configs, token endpoints).
    func execute(_ request: OCIHTTPRequest) async throws -> OCIHTTPResponse

    /// Performs the request, streaming the body to `destinationPath`
    /// (overwriting it). The file is only meaningful when the returned status
    /// is 200. Used for layer blobs, which can be gigabytes.
    func download(_ request: OCIHTTPRequest, to destinationPath: String) async throws
        -> (statusCode: Int, headers: [String: String])
}

/// The production transport: URLSession with automatic redirects disabled
/// (see `OCIHTTPTransport` for why).
public final class URLSessionOCITransport: NSObject, OCIHTTPTransport, URLSessionTaskDelegate,
    @unchecked Sendable
{
    private var session: URLSession!

    public override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        // Layer blobs can be large and registries slow; bound the whole
        // transfer generously rather than tightly.
        configuration.timeoutIntervalForResource = 3600
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func execute(_ request: OCIHTTPRequest) async throws -> OCIHTTPResponse {
        let (data, response) = try await session.data(for: urlRequest(for: request))
        guard let http = response as? HTTPURLResponse else {
            throw OCIError.malformedResponse(detail: "non-HTTP response from \(request.url.absoluteString)")
        }
        return OCIHTTPResponse(statusCode: http.statusCode, headers: headerMap(http), body: data)
    }

    public func download(_ request: OCIHTTPRequest, to destinationPath: String) async throws
        -> (statusCode: Int, headers: [String: String])
    {
        let (tempURL, response) = try await session.download(for: urlRequest(for: request))
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: tempURL)
            throw OCIError.malformedResponse(detail: "non-HTTP response from \(request.url.absoluteString)")
        }
        do {
            try? FileManager.default.removeItem(atPath: destinationPath)
            try FileManager.default.moveItem(at: tempURL, to: URL(fileURLWithPath: destinationPath))
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        return (http.statusCode, headerMap(http))
    }

    // Refuse every redirect: the 3xx response is delivered to the caller,
    // which follows it deliberately (without credentials).
    public func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    private func urlRequest(for request: OCIHTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        return urlRequest
    }

    private func headerMap(_ response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            if let name = name as? String, let value = value as? String {
                headers[name.lowercased()] = value
            }
        }
        return headers
    }
}
