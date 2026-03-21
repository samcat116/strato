import Foundation
import AsyncHTTPClient
import Crypto
import Logging

/// Configuration for SSF Receiver
public struct SSFReceiverConfiguration: Sendable {
    /// The transmitter's base URL
    public let transmitterURL: URL
    
    /// Authentication token for API calls
    public let authToken: String?
    
    /// Expected issuer URL (defaults to transmitterURL)
    public let expectedIssuer: URL?
    
    /// Expected audience identifiers
    public let expectedAudience: [String]?
    
    /// Automatic JWKS fetching and caching
    public let autoFetchJWKS: Bool
    
    /// HTTP client configuration
    public let httpClient: HTTPClient?
    
    /// Logging level
    public let logLevel: Logger.Level
    
    public init(
        transmitterURL: URL,
        authToken: String? = nil,
        expectedIssuer: URL? = nil,
        expectedAudience: [String]? = nil,
        autoFetchJWKS: Bool = true,
        httpClient: HTTPClient? = nil,
        logLevel: Logger.Level = .info
    ) {
        self.transmitterURL = transmitterURL
        self.authToken = authToken
        self.expectedIssuer = expectedIssuer ?? transmitterURL
        self.expectedAudience = expectedAudience
        self.autoFetchJWKS = autoFetchJWKS
        self.httpClient = httpClient
        self.logLevel = logLevel
    }
}

/// Event handler protocol for processing received security events
public protocol SSFEventHandler: Sendable {
    /// Handle a received security event
    func handleEvent(_ token: SecurityEventToken) async throws
    
    /// Handle event processing errors
    func handleError(_ error: SSFError, token: SecurityEventToken?) async
}

/// Main SSF Receiver implementation
public actor SSFReceiver {
    private let configuration: SSFReceiverConfiguration
    private let httpClient: SSFHTTPClient
    private let jwtProcessor: JWTProcessor
    private let jwksClient: JWKSClient
    private let logger: Logger
    
    private var cachedJWKS: JWKSet?
    private var cachedConfiguration: TransmitterConfiguration?
    
    public init(configuration: SSFReceiverConfiguration) {
        self.configuration = configuration
        
        let httpClientInstance = configuration.httpClient ?? HTTPClient(eventLoopGroupProvider: .singleton)
        self.httpClient = SSFHTTPClient(
            baseURL: configuration.transmitterURL,
            authToken: configuration.authToken,
            httpClient: httpClientInstance
        )
        
        self.jwtProcessor = JWTProcessor()
        self.jwksClient = JWKSClient(httpClient: httpClientInstance)
        
        var logger = Logger(label: "SwiftSSF.Receiver")
        logger.logLevel = configuration.logLevel
        self.logger = logger
    }
    
    // MARK: - Stream Management
    
    /// Create a new event stream
    public func createStream(
        audience: [String],
        eventsRequested: [String],
        delivery: DeliveryConfiguration,
        description: String? = nil
    ) async throws -> EventStream {
        logger.info("Creating new event stream")
        
        let request = CreateStreamRequest(
            aud: audience,
            events_requested: eventsRequested,
            delivery: delivery,
            description: description
        )
        
        return try await httpClient.createStream(request)
    }
    
    /// Get an existing stream
    public func getStream(id: String) async throws -> EventStream {
        return try await httpClient.getStream(id: id)
    }
    
    /// Update a stream
    public func updateStream(
        id: String,
        eventsRequested: [String]? = nil,
        delivery: DeliveryConfiguration? = nil,
        status: StreamStatus? = nil,
        description: String? = nil
    ) async throws -> EventStream {
        let request = UpdateStreamRequest(
            events_requested: eventsRequested,
            delivery: delivery,
            status: status,
            description: description
        )
        
        return try await httpClient.updateStream(id, request)
    }
    
    /// Delete a stream
    public func deleteStream(id: String) async throws {
        logger.info("Deleting stream \(id)")
        try await httpClient.deleteStream(id: id)
    }
    
    /// Get stream status
    public func getStreamStatus(id: String) async throws -> StreamStatus {
        return try await httpClient.getStreamStatus(id: id)
    }
    
    /// Add a subject to a stream
    public func addSubject(streamId: String, subject: SubjectIdentifier) async throws {
        logger.debug("Adding subject to stream \(streamId)")
        try await httpClient.addSubject(streamId: streamId, subject: subject)
    }
    
    /// Remove a subject from a stream
    public func removeSubject(streamId: String, subject: SubjectIdentifier) async throws {
        logger.debug("Removing subject from stream \(streamId)")
        try await httpClient.removeSubject(streamId: streamId, subject: subject)
    }
    
    /// Verify a stream
    public func verifyStream(id: String, state: String? = nil) async throws -> VerificationResponse {
        logger.info("Verifying stream \(id)")
        return try await httpClient.verifyStream(streamId: id, state: state)
    }
    
    // MARK: - Event Processing
    
    /// Poll for events from a stream
    public func pollEvents(
        streamId: String,
        maxEvents: Int = 100,
        handler: SSFEventHandler
    ) async throws -> Int {
        logger.debug("Polling events from stream \(streamId)")
        
        let response = try await httpClient.pollEvents(streamId: streamId, maxEvents: maxEvents)
        var processedEvents = 0
        var processedEventIds: [String] = []
        
        for setToken in response.sets {
            do {
                let securityEventToken = try await parseAndValidateToken(setToken)
                try await handler.handleEvent(securityEventToken)
                processedEvents += 1
                processedEventIds.append(securityEventToken.payload.jti)
            } catch {
                logger.error("Failed to process event: \(error)")
                let ssfError = error as? SSFError ?? SSFError.unknown(error)
                await handler.handleError(ssfError, token: nil)
            }
        }
        
        // Acknowledge processed events
        if !processedEventIds.isEmpty {
            try await httpClient.acknowledgeEvents(streamId: streamId, eventIds: processedEventIds)
            logger.debug("Acknowledged \(processedEventIds.count) events")
        }
        
        return processedEvents
    }
    
    /// Process a single SET token
    public func processSecurityEventToken(
        _ token: String,
        handler: SSFEventHandler
    ) async {
        do {
            let securityEventToken = try await parseAndValidateToken(token)
            try await handler.handleEvent(securityEventToken)
        } catch {
            logger.error("Failed to process security event token: \(error)")
            let ssfError = error as? SSFError ?? SSFError.unknown(error)
            await handler.handleError(ssfError, token: nil)
        }
    }
    
    // MARK: - Discovery
    
    /// Get transmitter configuration
    public func getTransmitterConfiguration() async throws -> TransmitterConfiguration {
        if let cached = cachedConfiguration {
            return cached
        }
        
        logger.info("Fetching transmitter configuration")
        let config = try await httpClient.getConfiguration()
        cachedConfiguration = config
        return config
    }
    
    /// Get supported events from transmitter
    public func getSupportedEvents() async throws -> [String] {
        let config = try await getTransmitterConfiguration()
        return config.events_supported ?? []
    }
    
    /// Get supported delivery methods
    public func getSupportedDeliveryMethods() async throws -> [String] {
        let config = try await getTransmitterConfiguration()
        return config.delivery_methods_supported
    }
    
    // MARK: - Private Methods
    
    private func parseAndValidateToken(_ token: String) async throws -> SecurityEventToken {
        let publicKey = try await getValidationKey(for: token)
        
        return try await jwtProcessor.parseSecurityEventToken(
            token,
            expectedIssuer: configuration.expectedIssuer,
            expectedAudience: configuration.expectedAudience,
            publicKey: publicKey
        )
    }
    
    private func getValidationKey(for token: String) async throws -> P256.Signing.PublicKey? {
        guard configuration.autoFetchJWKS else {
            return nil
        }
        
        // Parse token to get key ID
        let (header, _) = try await jwtProcessor.parseJWT(token)
        
        guard let keyId = header.kid else {
            logger.warning("JWT does not contain key ID, skipping signature verification")
            return nil
        }
        
        // Get JWKS
        let jwks = try await getJWKS()
        
        // Find the specific key
        return try await jwksClient.getPublicKey(jwks: jwks, keyId: keyId)
    }
    
    private func getJWKS() async throws -> JWKSet {
        if let cached = cachedJWKS {
            return cached
        }
        
        let config = try await getTransmitterConfiguration()
        let jwks = try await jwksClient.fetchJWKS(from: config.jwks_uri)
        cachedJWKS = jwks
        return jwks
    }
    
    /// Clear cached data
    public func clearCache() async {
        cachedJWKS = nil
        cachedConfiguration = nil
        await jwksClient.clearCache()
        logger.debug("Cleared all caches")
    }
}

// MARK: - Default Event Handler

/// Simple logging event handler for development and testing
public struct LoggingEventHandler: SSFEventHandler {
    private let logger = Logger(label: "SwiftSSF.LoggingEventHandler")
    
    public init() {}
    
    public func handleEvent(_ token: SecurityEventToken) async throws {
        logger.info("Received security event from \(token.payload.iss)")
        logger.debug("Event details: \(token.payload.events)")
    }
    
    public func handleError(_ error: SSFError, token: SecurityEventToken?) async {
        logger.error("Error processing event: \(error.localizedDescription)")
        if let token = token {
            logger.debug("Failed token issuer: \(token.payload.iss)")
        }
    }
}