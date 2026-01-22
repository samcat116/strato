import Foundation
import WebSocketKit
import NIOCore
import NIOPosix
import NIOSSL
import Logging
import StratoShared

// Thread-safe boolean wrapper for continuation resume tracking
final class AtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ initialValue: Bool) {
        self.value = initialValue
    }

    func testAndSet(_ newValue: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let oldValue = value
        value = newValue
        return oldValue
    }
}

// Thread-safe WebSocket wrapper to avoid EventLoop affinity issues
final class LockedWebSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var ws: WebSocket?

    init() {
        self.ws = nil
    }

    func set(_ newValue: WebSocket?) {
        lock.lock()
        defer { lock.unlock() }
        ws = newValue
    }

    func get() -> WebSocket? {
        lock.lock()
        defer { lock.unlock() }
        return ws
    }
}

actor WebSocketClient {
    private let url: String
    private weak var agent: Agent?
    private let logger: Logger
    private let eventLoopGroup: MultiThreadedEventLoopGroup

    // TLS configuration for mTLS (optional, nil for unencrypted connections)
    private var tlsConfiguration: TLSConfiguration?

    // WebSocket state managed via thread-safe wrapper to avoid EventLoop affinity issues
    private let wsHolder: LockedWebSocket
    private var isConnected = false
    private var heartbeatTask: Task<Void, Never>?

    init(url: String, agent: Agent, logger: Logger, tlsConfiguration: TLSConfiguration? = nil) {
        self.url = url
        self.agent = agent
        self.logger = logger
        self.tlsConfiguration = tlsConfiguration
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.wsHolder = LockedWebSocket()
    }

    /// Update TLS configuration (for SVID rotation)
    func updateTLSConfiguration(_ tlsConfig: TLSConfiguration?) {
        self.tlsConfiguration = tlsConfig
        logger.info("TLS configuration updated")
    }

    func connect() async throws {
        logger.info("Attempting to connect to WebSocket server", metadata: ["url": .string(url)])

        // Parse URL
        guard let parsedURL = URL(string: url) else {
            throw WebSocketClientError.invalidURL(url)
        }

        // WebSocketKit expects ws:// or wss:// scheme
        let scheme = parsedURL.scheme ?? "ws"
        guard scheme == "ws" || scheme == "wss" else {
            throw WebSocketClientError.invalidURL("Invalid scheme: \(scheme)")
        }

        // Log TLS status
        if let tlsConfig = tlsConfiguration {
            logger.info("Connecting with mTLS enabled", metadata: [
                "scheme": .string(scheme),
                "certificateVerification": .string(String(describing: tlsConfig.certificateVerification))
            ])
        } else {
            logger.debug("Connecting without TLS (plain WebSocket)")
        }

        // Create connection and wait for it to be established
        let eventLoop = eventLoopGroup.next()

        // Build WebSocket client configuration with optional TLS
        var wsConfig = WebSocketKit.WebSocketClient.Configuration()
        if let tlsConfig = tlsConfiguration {
            wsConfig.tlsConfiguration = tlsConfig
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = AtomicBool(false)
            let wsHolderRef = self.wsHolder
            let loggerRef = self.logger
            let agentRef = self.agent

            // Create connection - this returns immediately, callback fires when connected
            WebSocket.connect(
                to: url,
                configuration: wsConfig,
                on: eventLoop
            ) { ws in
                // Store WebSocket in thread-safe box (still on EventLoop)
                wsHolderRef.set(ws)

                // Set up handlers directly on the EventLoop (no Task hop)
                ws.onText { _, text in
                    loggerRef.debug("Received WebSocket text message", metadata: ["length": .string("\(text.count)")])

                    // Parse JSON to MessageEnvelope
                    guard let data = text.data(using: .utf8) else {
                        loggerRef.error("Failed to convert text message to UTF-8 data")
                        return
                    }

                    do {
                        let envelope = try JSONDecoder().decode(MessageEnvelope.self, from: data)
                        loggerRef.info("Received message from control plane", metadata: [
                            "type": .string(envelope.type.rawValue)
                        ])

                        // Handle message in a Task to bridge to async
                        Task { [weak agent = agentRef] in
                            await agent?.handleMessage(envelope)
                        }
                    } catch {
                        loggerRef.error("Failed to decode text message: \(error)")
                    }
                }

                ws.onBinary { _, buffer in
                    loggerRef.debug("Received WebSocket binary message")

                    // Convert binary buffer to string
                    guard let text = buffer.getString(at: 0, length: buffer.readableBytes) else {
                        loggerRef.error("Failed to convert binary buffer to string")
                        return
                    }

                    // Parse JSON to MessageEnvelope
                    guard let data = text.data(using: .utf8) else {
                        loggerRef.error("Failed to convert string to UTF-8 data")
                        return
                    }

                    do {
                        let envelope = try JSONDecoder().decode(MessageEnvelope.self, from: data)
                        loggerRef.info("Received message from control plane", metadata: [
                            "type": .string(envelope.type.rawValue)
                        ])

                        // Handle message in a Task to bridge to async
                        Task { [weak agent = agentRef] in
                            await agent?.handleMessage(envelope)
                        }
                    } catch {
                        loggerRef.error("Failed to decode message: \(error)")
                    }
                }

                ws.onClose.whenComplete { _ in
                    loggerRef.info("WebSocket connection closed")
                    wsHolderRef.set(nil)
                }

                loggerRef.info("WebSocket connection established and ready")

                // Resume to indicate successful connection
                if !resumed.testAndSet(true) {
                    continuation.resume()
                }
            }.whenFailure { error in
                if !resumed.testAndSet(true) {
                    continuation.resume(throwing: WebSocketClientError.connectionFailed("Failed to connect: \(error.localizedDescription)"))
                }
            }
        }

        // Mark as connected and start heartbeat after successful connection
        isConnected = true
        startHeartbeat()

        logger.info("WebSocket connect() returned - connection should stay alive")
    }

    func disconnect() async {
        guard isConnected else {
            return
        }

        logger.info("Disconnecting from WebSocket server")

        // Stop heartbeat
        heartbeatTask?.cancel()
        heartbeatTask = nil

        // Close WebSocket
        if let ws = wsHolder.get() {
            try? await ws.close().get()
        }

        wsHolder.set(nil)
        isConnected = false
        logger.info("Disconnected from WebSocket server")
    }

    func sendMessage<T: WebSocketMessage>(_ message: T) async throws {
        guard isConnected else {
            throw WebSocketClientError.notConnected
        }

        guard let ws = wsHolder.get() else {
            throw WebSocketClientError.notConnected
        }

        logger.debug("Sending WebSocket message", metadata: [
            "type": .string(message.type.rawValue),
            "requestId": .string(message.requestId)
        ])

        // Encode message to JSON
        let envelope = try MessageEnvelope(message: message)
        let data = try JSONEncoder().encode(envelope)

        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw WebSocketClientError.encodingError("Failed to convert message to UTF-8")
        }

        logger.debug("Message payload", metadata: ["payload": .string(jsonString)])

        // Send as text frame
        try await ws.send(jsonString)

        logger.debug("WebSocket message sent successfully")
    }

    // MARK: - Private Methods

    private func startHeartbeat() {
        heartbeatTask = Task {
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

    deinit {
        heartbeatTask?.cancel()
        try? eventLoopGroup.syncShutdownGracefully()
    }
}

// MARK: - Errors

enum WebSocketClientError: Error, LocalizedError, Sendable {
    case invalidURL(String)
    case connectionFailed(String)
    case notConnected
    case encodingError(String)

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
        }
    }
}
