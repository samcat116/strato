import Foundation
import WebSocketKit
import NIOCore
import NIOPosix
import NIOSSL
import NIOHTTP1
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
    private var url: String
    private weak var agent: Agent?
    private let logger: Logger
    private let eventLoopGroup: MultiThreadedEventLoopGroup

    // Single-use registration token, presented in an `Authorization: Bearer` header
    // at connect time (kept out of the URL so it never lands in proxy/ingress logs).
    // Nil for mTLS-authenticated connections. Rotated between reconnects via
    // `updateToken(_:)` after the control plane hands back a fresh one.
    private var registrationToken: String?

    // TLS configuration for mTLS (optional, nil for unencrypted connections)
    private var tlsConfiguration: TLSConfiguration?

    // WebSocket state managed via thread-safe wrapper to avoid EventLoop affinity issues
    private let wsHolder: LockedWebSocket
    private var isConnected = false
    private var heartbeatTask: Task<Void, Never>?

    // Ordered hand-off for inbound frames. `onText`/`onBinary` fire sequentially on the
    // single connection EventLoop, so yielding here preserves arrival order; the agent
    // drains this stream and dispatches each frame onto a per-resource serial lane. This
    // replaces the previous "one detached Task per frame" model, which gave no FIFO
    // guarantee and could reorder operations for the same VM (see issue #179).
    private let inboundContinuation: AsyncStream<MessageEnvelope>.Continuation

    // Distinguishes an operator-initiated disconnect (no reconnect) from an unexpected
    // drop (triggers the agent's reconnection loop).
    private var intentionalDisconnect = false

    init(url: String, agent: Agent, logger: Logger, tlsConfiguration: TLSConfiguration? = nil, registrationToken: String? = nil, inboundContinuation: AsyncStream<MessageEnvelope>.Continuation) {
        self.url = url
        self.agent = agent
        self.logger = logger
        self.tlsConfiguration = tlsConfiguration
        self.registrationToken = registrationToken
        self.inboundContinuation = inboundContinuation
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.wsHolder = LockedWebSocket()
    }

    /// Update TLS configuration (for SVID rotation)
    func updateTLSConfiguration(_ tlsConfig: TLSConfiguration?) {
        self.tlsConfiguration = tlsConfig
        logger.info("TLS configuration updated")
    }

    /// Update the connection URL. Takes effect on the next connect; the current
    /// connection is unaffected.
    func updateURL(_ newURL: String) {
        self.url = newURL
    }

    /// Update the registration token (for single-use token rotation). Takes effect
    /// on the next connect; the current connection is unaffected.
    func updateToken(_ newToken: String?) {
        self.registrationToken = newToken
    }

    func connect() async throws {
        logger.info("Attempting to connect to WebSocket server", metadata: ["url": .string(url)])

        // A fresh connection attempt is, by definition, not an intentional disconnect.
        intentionalDisconnect = false

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

        // Present the registration token in an Authorization header rather than the
        // URL query string, so it never appears in proxy/ingress/load-balancer logs.
        var headers = HTTPHeaders()
        if let token = registrationToken {
            headers.add(name: "Authorization", value: "Bearer \(token)")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = AtomicBool(false)
            let wsHolderRef = self.wsHolder
            let loggerRef = self.logger
            let inboundRef = self.inboundContinuation

            // Create connection - this returns immediately, callback fires when connected.
            // Capture self weakly so the onClose handler can hop back to the actor without
            // forming a self -> wsHolder -> ws -> onClose -> self retain cycle.
            WebSocket.connect(
                to: url,
                headers: headers,
                configuration: wsConfig,
                on: eventLoop
            ) { [weak self] ws in
                // Immutable, Sendable weak reference to this actor for use in the
                // nested close handler (avoids capturing the mutable `self` binding).
                let clientRef = self

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
                        let envelope = try WireProtocol.makeDecoder().decode(MessageEnvelope.self, from: data)
                        loggerRef.info("Received message from control plane", metadata: [
                            "type": .string(envelope.type.rawValue)
                        ])

                        // Preserve arrival order: hand off to the agent's ordered inbound
                        // pipeline rather than spawning an unordered per-frame Task.
                        inboundRef.yield(envelope)
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
                        let envelope = try WireProtocol.makeDecoder().decode(MessageEnvelope.self, from: data)
                        loggerRef.info("Received message from control plane", metadata: [
                            "type": .string(envelope.type.rawValue)
                        ])

                        // Preserve arrival order: hand off to the agent's ordered inbound
                        // pipeline rather than spawning an unordered per-frame Task.
                        inboundRef.yield(envelope)
                    } catch {
                        loggerRef.error("Failed to decode message: \(error)")
                    }
                }

                ws.onClose.whenComplete { _ in
                    loggerRef.info("WebSocket connection closed")
                    wsHolderRef.set(nil)
                    // Bridge the event-loop callback back onto the actor to update
                    // connection state and trigger reconnection if this was unexpected.
                    Task { await clientRef?.handleConnectionClosed() }
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

        // Mark this close as intentional so the onClose handler does not reconnect.
        intentionalDisconnect = true

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
        let data = try WireProtocol.makeEncoder().encode(envelope)

        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw WebSocketClientError.encodingError("Failed to convert message to UTF-8")
        }

        logger.debug("Message payload", metadata: ["payload": .string(jsonString)])

        // Send as text frame
        try await ws.send(jsonString)

        logger.debug("WebSocket message sent successfully")
    }

    // MARK: - Private Methods

    /// Invoked when the underlying WebSocket closes. Tears down connection state and,
    /// unless the close was operator-initiated, asks the agent to begin reconnecting.
    private func handleConnectionClosed() async {
        isConnected = false
        heartbeatTask?.cancel()
        heartbeatTask = nil

        if intentionalDisconnect {
            logger.debug("WebSocket closed intentionally; not reconnecting")
            return
        }

        logger.warning("WebSocket closed unexpectedly; requesting reconnection")
        await agent?.handleConnectionLost()
    }

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
