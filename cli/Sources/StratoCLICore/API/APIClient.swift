import Foundation

/// Authenticated JSON client for the Strato control-plane API.
///
/// Serialized as an actor so a burst of parallel calls can't race the
/// refresh: whoever hits the expired token first rotates it, everyone else
/// picks up the new pair.
public actor APIClient {
    public let baseURL: URL
    public let contextName: String
    private let credentialStore: CredentialStore
    private let transport: any HTTPTransport

    public init(
        baseURL: URL,
        contextName: String,
        credentialStore: CredentialStore,
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.baseURL = baseURL
        self.contextName = contextName
        self.credentialStore = credentialStore
        self.transport = transport
    }

    // MARK: - JSON coding (matches Vapor's defaults: ISO8601 dates)

    public static func jsonDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    // MARK: - Typed requests

    public func get<T: Decodable & Sendable>(_ path: String, query: [(String, String)] = []) async throws -> T {
        let response = try await send(method: "GET", path: path, query: query)
        return try Self.decode(T.self, from: response)
    }

    public func post<T: Decodable & Sendable>(_ path: String) async throws -> T {
        let response = try await send(method: "POST", path: path)
        return try Self.decode(T.self, from: response)
    }

    public func post<T: Decodable & Sendable>(_ path: String, body: some Encodable & Sendable) async throws -> T {
        let response = try await send(method: "POST", path: path, jsonBody: try Self.jsonEncoder().encode(body))
        return try Self.decode(T.self, from: response)
    }

    public func put<T: Decodable & Sendable>(_ path: String, body: some Encodable & Sendable) async throws -> T {
        let response = try await send(method: "PUT", path: path, jsonBody: try Self.jsonEncoder().encode(body))
        return try Self.decode(T.self, from: response)
    }

    /// DELETE that decodes a response body (async mutations return 202 + an
    /// operation record).
    public func delete<T: Decodable & Sendable>(_ path: String) async throws -> T {
        let response = try await send(method: "DELETE", path: path)
        return try Self.decode(T.self, from: response)
    }

    /// DELETE for endpoints that return no body (204).
    public func deleteExpectingNoContent(_ path: String) async throws {
        _ = try await send(method: "DELETE", path: path)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from response: TransportResponse) throws -> T {
        do {
            return try jsonDecoder().decode(type, from: response.body)
        } catch {
            let body = String(decoding: response.body.prefix(200), as: UTF8.self)
            throw CLIError.api(
                status: response.statusCode,
                message: "Could not decode server response (\(error)): \(body)")
        }
    }

    // MARK: - Core send with refresh-on-401

    /// Performs an authenticated request. On 401 the client attempts one
    /// refresh-token rotation, persists the new pair, and retries once.
    public func send(
        method: String, path: String, query: [(String, String)] = [], jsonBody: Data? = nil
    ) async throws -> TransportResponse {
        guard var credentials = try credentialStore.credentials(for: contextName) else {
            throw CLIError.notLoggedIn("No credentials for context '\(contextName)'.")
        }

        // Refresh proactively when the stored expiry has passed — cheaper
        // than eating a guaranteed 401 round-trip.
        if let expiresAt = credentials.expiresAt, expiresAt < Date() {
            credentials = try await refresh(credentials)
        }

        var response = try await perform(
            method: method, path: path, query: query, jsonBody: jsonBody,
            accessToken: credentials.accessToken)

        if response.statusCode == 401 {
            credentials = try await refresh(credentials)
            response = try await perform(
                method: method, path: path, query: query, jsonBody: jsonBody,
                accessToken: credentials.accessToken)
        }

        guard (200..<300).contains(response.statusCode) else {
            throw CLIError.api(status: response.statusCode, message: Self.errorMessage(from: response.body))
        }
        return response
    }

    private func perform(
        method: String, path: String, query: [(String, String)], jsonBody: Data?,
        accessToken: String
    ) async throws -> TransportResponse {
        var headers = [
            "Authorization": "Bearer \(accessToken)",
            "Accept": "application/json",
        ]
        if jsonBody != nil {
            headers["Content-Type"] = "application/json"
        }
        let request = TransportRequest(
            method: method,
            url: Self.url(baseURL: baseURL, path: path, query: query),
            headers: headers,
            body: jsonBody
        )
        return try await transport.send(request)
    }

    static func url(baseURL: URL, path: String, query: [(String, String)]) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        return components.url!
    }

    /// Decodes Vapor's `{reason}` / generic `{error}` error bodies.
    static func errorMessage(from body: Data) -> String {
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

    // MARK: - Refresh

    private func refresh(_ credentials: StoredCredentials) async throws -> StoredCredentials {
        let request = TransportRequest(
            method: "POST",
            url: Self.url(baseURL: baseURL, path: "/oauth/token", query: []),
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: formEncode([
                ("grant_type", "refresh_token"),
                ("refresh_token", credentials.refreshToken),
            ])
        )
        let response = try await transport.send(request)

        guard response.statusCode == 200 else {
            // A rejected refresh means the session is revoked, expired, or
            // was rotated elsewhere — stale credentials are useless now.
            try? credentialStore.delete(for: contextName)
            throw CLIError.notLoggedIn("Your session for context '\(contextName)' has expired or been revoked.")
        }

        let token = try Self.jsonDecoder().decode(TokenResponse.self, from: response.body)
        let updated = StoredCredentials(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: token.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        )
        try credentialStore.store(updated, for: contextName)
        return updated
    }
}
