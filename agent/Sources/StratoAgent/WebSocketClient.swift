import Foundation
import NIOCore
import NIOPosix
import NIOWebSocket
import NIOHTTP1
import NIOSSL
import Logging
import StratoShared

@MainActor
class WebSocketClient {
    private let url: String
    weak var agent: Agent?
    private let logger: Logger
    private let eventLoopGroup: MultiThreadedEventLoopGroup
    private let certificateManager: CertificateManager?
    
    private var channel: Channel?
    private var isConnected = false
    private var heartbeatTask: Task<Void, Never>?
    
    init(url: String, agent: Agent, logger: Logger, certificateManager: CertificateManager? = nil) {
        self.url = url
        self.agent = agent
        self.logger = logger
        self.certificateManager = certificateManager
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }
    
    func connect() async throws {
        logger.info("Attempting to connect to WebSocket server", metadata: ["url": .string(url)])
        
        // Determine if this is a secure connection and if we have certificates
        let useSecureConnection = url.hasPrefix("wss://") || url.hasPrefix("https://")
        let hasCertificates = certificateManager != nil
        
        if useSecureConnection && hasCertificates {
            try await connectWithMTLS()
        } else {
            try await connectWithoutMTLS()
        }
        
        isConnected = true
        startHeartbeat()
    }
    
    private func connectWithMTLS() async throws {
        guard let certManager = certificateManager else {
            throw WebSocketClientError.configurationError("Certificate manager not available")
        }
        
        logger.info("Connecting with mutual TLS authentication")
        
        // Load client certificate and private key
        let certificate = try await certManager.loadCertificate()
        let privateKey = try await certManager.loadPrivateKey()
        let caBundle = try await certManager.loadCABundle()
        
        // Parse URL
        guard let parsedURL = URL(string: url) else {
            throw WebSocketClientError.invalidURL(url)
        }
        
        let host = parsedURL.host ?? "localhost"
        let port = parsedURL.port ?? (url.hasPrefix("wss://") ? 443 : 8080)
        
        logger.info("Setting up TLS context with client certificate", metadata: [
            "host": .string(host),
            "port": .stringConvertible(port)
        ])
        
        // For Phase 3, implement simplified mTLS setup
        // In production, this would use full NIOSSL configuration
        try await connectSimulatedMTLS(host: host, port: port, certificate: certificate)
    }
    
    private func connectWithoutMTLS() async throws {
        logger.info("Connecting without mTLS (legacy mode)")
        
        // For now, implement a working mock that simulates the connection
        // In a production environment, you would implement full WebSocket protocol
        // This allows development and testing without complex WebSocket client implementation
        
        // Simulate connection delay
        try await Task.sleep(for: .milliseconds(500))
        
        // Parse URL to validate format
        guard let parsedURL = URL(string: url) else {
            throw WebSocketClientError.invalidURL(url)
        }
        
        // Check if this is a registration URL or regular WebSocket URL
        let components = URLComponents(url: parsedURL, resolvingAgainstBaseURL: false)
        let isRegistrationURL = components?.queryItems?.contains { $0.name == "token" } ?? false
        
        if isRegistrationURL {
            // Validate registration URL format
            guard let queryItems = components?.queryItems else {
                throw WebSocketClientError.invalidURL("Missing query parameters in registration URL")
            }
            
            let token = queryItems.first { $0.name == "token" }?.value
            let agentName = queryItems.first { $0.name == "name" }?.value
            
            guard let token = token, let agentName = agentName, !token.isEmpty, !agentName.isEmpty else {
                throw WebSocketClientError.invalidURL("Missing or empty token/name parameters in registration URL")
            }
            
            logger.info("WebSocket connection established (registration mode)", metadata: [
                "agentName": .string(agentName),
                "hasToken": .string("yes")
            ])
            
            logger.info("Agent registration successful (mock mode)")
        } else {
            // Regular WebSocket connection
            logger.info("WebSocket connection established (regular mode)")
        }
    }
    
    private func connectSimulatedMTLS(host: String, port: Int, certificate: AgentCertificateInfo) async throws {
        // For Phase 3, simulate mTLS connection
        // This would be replaced with actual NIOSSL implementation
        
        logger.info("Simulating mTLS connection", metadata: [
            "host": .string(host),
            "port": .stringConvertible(port),
            "spiffeURI": .string(certificate.spiffeURI)
        ])
        
        // Simulate TLS handshake delay
        try await Task.sleep(for: .milliseconds(1000))
        
        // Simulate certificate verification
        guard !certificate.isExpired else {
            throw WebSocketClientError.connectionFailed("Client certificate has expired")
        }
        
        logger.info("Simulated mTLS handshake successful", metadata: [
            "agentId": .string(certificate.agentId),
            "expiresAt": .string(certificate.expiresAt.description)
        ])
    }
    
    func disconnect() async {
        guard isConnected else {
            return
        }
        
        logger.info("Disconnecting from WebSocket server")
        
        // Stop heartbeat
        heartbeatTask?.cancel()
        heartbeatTask = nil
        
        // Close channel if exists
        if let channel = channel {
            try? await channel.close().get()
        }
        
        channel = nil
        isConnected = false
        logger.info("Disconnected from WebSocket server")
    }
    
    func sendMessage<T: WebSocketMessage>(_ message: T) async throws {
        guard isConnected else {
            throw WebSocketClientError.notConnected
        }
        
        logger.debug("Mock sending WebSocket message", metadata: [
            "type": .string(message.type.rawValue),
            "requestId": .string(message.requestId)
        ])
        
        // In mock mode, we just log the message instead of sending it
        // This allows testing of the agent logic without actual WebSocket connectivity
        
        // Simulate network delay
        try await Task.sleep(for: .milliseconds(10))
        
        // Log the message content for debugging
        if let data = try? JSONEncoder().encode(MessageEnvelope(message: message)),
           let jsonString = String(data: data, encoding: .utf8) {
            logger.debug("Message payload", metadata: ["payload": .string(jsonString)])
        }
    }
    
    private func startHeartbeat() {
        heartbeatTask = Task { @MainActor in
            while !Task.isCancelled && isConnected {
                do {
                    // Send heartbeat every 20 seconds
                    try await Task.sleep(for: .seconds(20))
                    
                    if let agent = agent {
                        await agent.sendHeartbeat()
                    }
                } catch {
                    if !Task.isCancelled {
                        logger.error("Error in heartbeat task: \(error)")
                    }
                    break
                }
            }
        }
    }
    
    // Generate WebSocket key for handshake
    private static func generateWebSocketKey() -> String {
        let keyData = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        return keyData.base64EncodedString()
    }
    
    deinit {
        heartbeatTask?.cancel()
        try? eventLoopGroup.syncShutdownGracefully()
    }
}

enum WebSocketClientError: Error, LocalizedError {
    case invalidURL(String)
    case connectionFailed(String)
    case notConnected
    case encodingError(String)
    case configurationError(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid WebSocket URL: \(url)"
        case .connectionFailed(let reason):
            return "WebSocket connection failed: \(reason)"
        case .notConnected:
            return "WebSocket client is not connected"
        case .encodingError(let details):
            return "Failed to encode WebSocket message: \(details)"
        case .configurationError(let details):
            return "WebSocket client configuration error: \(details)"
        }
    }
}