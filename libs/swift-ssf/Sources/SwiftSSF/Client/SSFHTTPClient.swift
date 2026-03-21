import Foundation
import AsyncHTTPClient
import NIOFoundationCompat
import NIOHTTP1
import NIO
import Logging

/// HTTP client for communicating with SSF transmitters
public actor SSFHTTPClient {
    private let httpClient: HTTPClient
    private let baseURL: URL
    private let authToken: String?
    private let logger = Logger(label: "SwiftSSF.HTTPClient")
    private let jsonDecoder: JSONDecoder
    private let jsonEncoder: JSONEncoder
    
    public init(baseURL: URL, authToken: String? = nil, httpClient: HTTPClient? = nil) {
        self.baseURL = baseURL
        self.authToken = authToken
        self.httpClient = httpClient ?? HTTPClient(eventLoopGroupProvider: .singleton)
        
        self.jsonDecoder = JSONDecoder()
        self.jsonEncoder = JSONEncoder()
        
        // Configure JSON coding
        jsonDecoder.dateDecodingStrategy = .secondsSince1970
        jsonEncoder.dateEncodingStrategy = .secondsSince1970
    }
    
    deinit {
        Task {
            try? await httpClient.shutdown()
        }
    }
    
    // MARK: - Generic HTTP Methods
    
    /// Perform a GET request
    public func get<T: Codable>(
        path: String,
        responseType: T.Type,
        queryItems: [URLQueryItem] = []
    ) async throws -> T {
        let url = try buildURL(path: path, queryItems: queryItems)
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .GET
        addAuthenticationHeaders(&request)
        
        return try await performRequest(request, responseType: responseType)
    }
    
    /// Perform a POST request
    public func post<T: Codable, U: Codable>(
        path: String,
        body: T,
        responseType: U.Type
    ) async throws -> U {
        let url = try buildURL(path: path)
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .POST
        addAuthenticationHeaders(&request)
        addJSONHeaders(&request)
        
        let bodyData = try jsonEncoder.encode(body)
        request.body = .bytes(ByteBuffer(data: bodyData))
        
        return try await performRequest(request, responseType: responseType)
    }
    
    /// Perform a PUT request
    public func put<T: Codable, U: Codable>(
        path: String,
        body: T,
        responseType: U.Type
    ) async throws -> U {
        let url = try buildURL(path: path)
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .PUT
        addAuthenticationHeaders(&request)
        addJSONHeaders(&request)
        
        let bodyData = try jsonEncoder.encode(body)
        request.body = .bytes(ByteBuffer(data: bodyData))
        
        return try await performRequest(request, responseType: responseType)
    }
    
    /// Perform a DELETE request
    public func delete(path: String) async throws {
        let url = try buildURL(path: path)
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .DELETE
        addAuthenticationHeaders(&request)
        
        let response = try await httpClient.execute(request, timeout: .seconds(30))
        try await handleErrorResponse(response)
    }
    
    // MARK: - Stream Management API
    
    /// Get stream configuration
    public func getStream(id: String) async throws -> EventStream {
        return try await get(path: "/streams/\(id)", responseType: EventStream.self)
    }
    
    /// Create a new stream
    public func createStream(_ request: CreateStreamRequest) async throws -> EventStream {
        return try await post(path: "/streams", body: request, responseType: EventStream.self)
    }
    
    /// Update a stream
    public func updateStream(_ id: String, _ request: UpdateStreamRequest) async throws -> EventStream {
        return try await put(path: "/streams/\(id)", body: request, responseType: EventStream.self)
    }
    
    /// Delete a stream
    public func deleteStream(id: String) async throws {
        try await delete(path: "/streams/\(id)")
    }
    
    /// Get stream status
    public func getStreamStatus(id: String) async throws -> StreamStatus {
        struct StatusResponse: Codable {
            let status: StreamStatus
        }
        
        let response = try await get(path: "/streams/\(id)/status", responseType: StatusResponse.self)
        return response.status
    }
    
    /// Add subject to stream
    public func addSubject(streamId: String, subject: SubjectIdentifier) async throws {
        let request = AddSubjectRequest(subject: subject)
        let _: EmptyResponse = try await post(path: "/streams/\(streamId)/add-subject", body: request, responseType: EmptyResponse.self)
    }
    
    /// Remove subject from stream
    public func removeSubject(streamId: String, subject: SubjectIdentifier) async throws {
        let request = RemoveSubjectRequest(subject: subject)
        let _: EmptyResponse = try await post(path: "/streams/\(streamId)/remove-subject", body: request, responseType: EmptyResponse.self)
    }
    
    /// Request stream verification
    public func verifyStream(streamId: String, state: String? = nil) async throws -> VerificationResponse {
        let request = VerificationRequest(state: state)
        return try await post(path: "/streams/\(streamId)/verify", body: request, responseType: VerificationResponse.self)
    }
    
    // MARK: - Event Polling
    
    /// Poll for events from a stream
    public func pollEvents(streamId: String, maxEvents: Int = 100) async throws -> PollEventsResponse {
        let queryItems = [URLQueryItem(name: "max_events", value: String(maxEvents))]
        return try await get(
            path: "/streams/\(streamId)/poll",
            responseType: PollEventsResponse.self,
            queryItems: queryItems
        )
    }
    
    /// Acknowledge received events
    public func acknowledgeEvents(streamId: String, eventIds: [String]) async throws {
        struct AckRequest: Codable {
            let event_ids: [String]
        }
        
        let request = AckRequest(event_ids: eventIds)
        let _: EmptyResponse = try await post(path: "/streams/\(streamId)/ack", body: request, responseType: EmptyResponse.self)
    }
    
    // MARK: - Discovery
    
    /// Get transmitter configuration
    public func getConfiguration() async throws -> TransmitterConfiguration {
        return try await get(path: "/.well-known/ssf_configuration", responseType: TransmitterConfiguration.self)
    }
    
    /// Get JWKS endpoint
    public func getJWKSURL() async throws -> URL {
        let config = try await getConfiguration()
        return config.jwks_uri
    }
    
    // MARK: - Private Methods
    
    private func buildURL(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw SSFError.configurationError("Invalid base URL")
        }
        
        components.path = path
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        
        guard let url = components.url else {
            throw SSFError.configurationError("Failed to build URL")
        }
        
        return url
    }
    
    private func addAuthenticationHeaders(_ request: inout HTTPClientRequest) {
        if let authToken = authToken {
            request.headers.add(name: "Authorization", value: "Bearer \(authToken)")
        }
    }
    
    private func addJSONHeaders(_ request: inout HTTPClientRequest) {
        request.headers.add(name: "Content-Type", value: "application/json")
        request.headers.add(name: "Accept", value: "application/json")
    }
    
    private func performRequest<T: Codable>(
        _ request: HTTPClientRequest,
        responseType: T.Type
    ) async throws -> T {
        logger.debug("Performing \(request.method) request to \(request.url)")
        
        do {
            let response = try await httpClient.execute(request, timeout: .seconds(30))
            try await handleErrorResponse(response)
            
            let body = try await response.body.collect(upTo: 1024 * 1024) // 1MB limit
            let data = Data(buffer: body)
            
            if T.self == EmptyResponse.self {
                return EmptyResponse() as! T
            }
            
            return try jsonDecoder.decode(T.self, from: data)
        } catch let error as SSFError {
            throw error
        } catch {
            throw SSFError.networkError(error)
        }
    }
    
    private func handleErrorResponse(_ response: HTTPClientResponse) async throws {
        guard response.status.code >= 400 else { return }
        
        let body = try await response.body.collect(upTo: 1024 * 1024)
        let data = Data(buffer: body)
        
        // Try to parse as SSF error response
        if let errorResponse = try? jsonDecoder.decode(SSFHTTPError.self, from: data) {
            switch response.status.code {
            case 401:
                throw SSFError.authenticationFailed(errorResponse.error_description ?? errorResponse.error)
            case 403:
                throw SSFError.authorizationFailed(errorResponse.error_description ?? errorResponse.error)
            case 404:
                if errorResponse.error == SSFErrorCode.streamNotFound.rawValue {
                    throw SSFError.streamNotFound(errorResponse.error_description ?? "Stream not found")
                } else {
                    throw SSFError.httpError(statusCode: Int(response.status.code), message: errorResponse.error_description)
                }
            case 500...599:
                throw SSFError.serverError(errorResponse.error_description ?? errorResponse.error)
            default:
                throw SSFError.httpError(statusCode: Int(response.status.code), message: errorResponse.error_description)
            }
        } else {
            // Generic HTTP error
            let message = String(data: data, encoding: .utf8)
            throw SSFError.httpError(statusCode: Int(response.status.code), message: message)
        }
    }
}

// MARK: - Response Types

/// Empty response for operations that don't return data
public struct EmptyResponse: Codable, Sendable {
    public init() {}
}

/// Response for polling events
public struct PollEventsResponse: Codable, Sendable {
    /// The security event tokens
    public let sets: [String]
    
    /// Whether more events are available
    public let more_available: Bool?
    
    public init(sets: [String], more_available: Bool? = nil) {
        self.sets = sets
        self.more_available = more_available
    }
}

/// Transmitter configuration from discovery endpoint
public struct TransmitterConfiguration: Codable, Sendable {
    /// Issuer URL
    public let issuer: URL
    
    /// JWKS endpoint
    public let jwks_uri: URL
    
    /// Supported delivery methods
    public let delivery_methods_supported: [String]
    
    /// Configuration endpoint
    public let configuration_endpoint: URL?
    
    /// Status endpoint
    public let status_endpoint: URL?
    
    /// Add subject endpoint
    public let add_subject_endpoint: URL?
    
    /// Remove subject endpoint
    public let remove_subject_endpoint: URL?
    
    /// Verification endpoint
    public let verification_endpoint: URL?
    
    /// Supported events
    public let events_supported: [String]?
    
    public init(
        issuer: URL,
        jwks_uri: URL,
        delivery_methods_supported: [String],
        configuration_endpoint: URL? = nil,
        status_endpoint: URL? = nil,
        add_subject_endpoint: URL? = nil,
        remove_subject_endpoint: URL? = nil,
        verification_endpoint: URL? = nil,
        events_supported: [String]? = nil
    ) {
        self.issuer = issuer
        self.jwks_uri = jwks_uri
        self.delivery_methods_supported = delivery_methods_supported
        self.configuration_endpoint = configuration_endpoint
        self.status_endpoint = status_endpoint
        self.add_subject_endpoint = add_subject_endpoint
        self.remove_subject_endpoint = remove_subject_endpoint
        self.verification_endpoint = verification_endpoint
        self.events_supported = events_supported
    }
}