import Foundation
import WebSocketKit
import NIOCore
import NIOPosix
import NIOSSL
import NIOHTTP1
import Logging
import StratoAgentCore
import StratoAgentSPIFFE
import StratoShared
import Synchronization

struct ControlPlaneInboundFrame: Sendable {
    let envelope: MessageEnvelope
    let generation: ControlPlaneWebSocketState.Generation
    let byteCount: Int
}

// Thread-safe boolean wrapper for continuation resume tracking
final class AtomicBool: Sendable {
    private let value: Mutex<Bool>

    init(_ initialValue: Bool) {
        self.value = Mutex(initialValue)
    }

    func testAndSet(_ newValue: Bool) -> Bool {
        value.withLock { value in
            let oldValue = value
            value = newValue
            return oldValue
        }
    }
}

// Thread-safe WebSocket wrapper to avoid EventLoop affinity issues
final class LockedWebSocket: Sendable {
    private struct Entry {
        let generation: ControlPlaneWebSocketState.Generation
        let websocket: WebSocket
    }

    private let websocket: Mutex<Entry?>

    init() {
        self.websocket = Mutex(nil)
    }

    func set(
        _ newValue: WebSocket,
        generation: ControlPlaneWebSocketState.Generation
    ) {
        websocket.withLock { current in
            if let current, current.generation.rawValue > generation.rawValue {
                return
            }
            current = Entry(generation: generation, websocket: newValue)
        }
    }

    func get(generation: ControlPlaneWebSocketState.Generation) -> WebSocket? {
        websocket.withLock { current in
            guard current?.generation == generation else { return nil }
            return current?.websocket
        }
    }

    func clear(generation: ControlPlaneWebSocketState.Generation) {
        websocket.withLock { current in
            guard current?.generation == generation else { return }
            current = nil
        }
    }
}

actor WebSocketClient {
    private var url: String
    private weak var agent: Agent?
    private let logger: Logger
    private let eventLoopGroup: MultiThreadedEventLoopGroup

    // TLS configuration for mTLS (optional, nil for unencrypted connections)
    private var tlsConfiguration: TLSConfiguration?

    // Pinned control-plane SPIFFE identity, verified on every wss:// TLS
    // handshake. Required whenever TLS is configured: chaining to the trust
    // bundle alone would accept any workload in the trust domain as the
    // control plane (issue #552).
    private var spiffePinning: SPIFFEPeerPinning?

    // WebSocket state managed via thread-safe wrapper to avoid EventLoop affinity issues
    private let wsHolder: LockedWebSocket
    // Readable so callers can skip work whose only possible outcome is a
    // `notConnected` throw. Advisory, never a correctness gate: the socket can
    // drop between the check and the send, which is why `sendMessage` still
    // guards on it.
    var isConnected: Bool {
        guard let generation = connectionState.connectedGeneration else { return false }
        return wsHolder.get(generation: generation) != nil
    }
    private var connectionState = ControlPlaneWebSocketState()
    private var heartbeatTask: Task<Void, Never>?

    // Ordered hand-off for inbound frames. `onText`/`onBinary` fire sequentially on the
    // single connection EventLoop, so yielding here preserves arrival order; the agent
    // drains this stream and dispatches each frame onto a per-resource serial lane. This
    // replaces the previous "one detached Task per frame" model, which gave no FIFO
    // guarantee and could reorder operations for the same VM (see issue #179).
    private let inboundContinuation: AsyncStream<ControlPlaneInboundFrame>.Continuation

    init(
        url: String, agent: Agent, logger: Logger, tlsConfiguration: TLSConfiguration? = nil,
        spiffePinning: SPIFFEPeerPinning? = nil,
        inboundContinuation: AsyncStream<ControlPlaneInboundFrame>.Continuation
    ) {
        self.url = url
        self.agent = agent
        self.logger = logger
        self.tlsConfiguration = tlsConfiguration
        self.spiffePinning = spiffePinning
        self.inboundContinuation = inboundContinuation
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.wsHolder = LockedWebSocket()
    }

    /// Update TLS configuration and the pinned control-plane identity (for
    /// SVID rotation — the trust bundle can rotate along with the SVID).
    func updateTLSConfiguration(_ tlsConfig: TLSConfiguration?, spiffePinning: SPIFFEPeerPinning?) {
        self.tlsConfiguration = tlsConfig
        self.spiffePinning = spiffePinning
        logger.info("TLS configuration updated")
    }

    func connect() async throws -> ControlPlaneWebSocketState.Generation {
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
            logger.info(
                "Connecting with mTLS enabled",
                metadata: [
                    "scheme": .string(scheme),
                    "certificateVerification": .string(String(describing: tlsConfig.certificateVerification)),
                ])
        } else {
            logger.debug("Connecting without TLS (plain WebSocket)")
        }

        // Create connection and wait for it to be established
        let eventLoop = eventLoopGroup.next()

        // The control plane's desired-state sync is a single frame carrying every
        // VM placed on this agent, so it grows with placement count; the 16 KiB
        // websocket-kit default is crossed at roughly 7 VMs, and an oversized
        // frame kills the connection — permanently, since the full sync is
        // re-pushed on every reconnect. Must match the control plane's limit on
        // /agent/ws.
        let maxFrameSize = 1 << 24

        // The agent authenticates with its SPIFFE X.509 SVID over mTLS; the
        // upgrade request carries no credential headers.
        let headers = HTTPHeaders()
        let generation = connectionState.beginConnection()
        var connectionBecameCurrent = false
        defer {
            if !connectionBecameCurrent {
                connectionState.markConnectionFailed(generation)
            }
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let resumed = AtomicBool(false)
            let wsHolderRef = self.wsHolder
            let loggerRef = self.logger
            let inboundRef = self.inboundContinuation

            // Fires once the connection is established (and, for wss://, the
            // control plane's pinned SPIFFE identity verified). Capture self
            // weakly so the onClose handler can hop back to the actor without
            // forming a self -> wsHolder -> ws -> onClose -> self retain cycle.
            let onWebSocketReady: @Sendable (WebSocket) -> Void = { [weak self] ws in
                // Immutable, Sendable weak reference to this actor for use in the
                // nested close handler (avoids capturing the mutable `self` binding).
                let clientRef = self

                // Store WebSocket in thread-safe box (still on EventLoop)
                wsHolderRef.set(ws, generation: generation)

                // Text and binary frames carry the same JSON envelope, so both
                // decode through here. Only the outer envelope is decoded on
                // the event loop; typed handling and debug metadata happen on
                // the agent actor so logging never adds payload parsing here.
                let decodeAndYield: @Sendable (String) -> Void = { text in
                    guard let data = text.data(using: .utf8) else {
                        loggerRef.error("Failed to convert message to UTF-8 data")
                        return
                    }

                    do {
                        let envelope = try WireProtocol.makeDecoder().decode(MessageEnvelope.self, from: data)

                        // Preserve arrival order: hand off to the agent's ordered inbound
                        // pipeline rather than spawning an unordered per-frame Task.
                        inboundRef.yield(
                            ControlPlaneInboundFrame(
                                envelope: envelope,
                                generation: generation,
                                byteCount: data.count))
                    } catch {
                        WireMessageLogger.logEnvelopeDecodingFailure(
                            direction: .inbound,
                            byteCount: data.count,
                            logger: loggerRef)
                    }
                }

                // Set up handlers directly on the EventLoop (no Task hop)
                ws.onText { _, text in
                    decodeAndYield(text)
                }

                ws.onBinary { _, buffer in
                    guard let text = buffer.getString(at: 0, length: buffer.readableBytes) else {
                        loggerRef.error("Failed to convert binary buffer to string")
                        return
                    }
                    decodeAndYield(text)
                }

                ws.onClose.whenComplete { _ in
                    loggerRef.info("WebSocket connection closed")
                    wsHolderRef.clear(generation: generation)
                    // Bridge the event-loop callback back onto the actor to update
                    // connection state and trigger reconnection if this was unexpected.
                    Task {
                        await clientRef?.handleConnectionClosed(generation: generation)
                    }
                }

                loggerRef.info("WebSocket connection established and ready")

                // Resume to indicate successful connection
                if !resumed.testAndSet(true) {
                    continuation.resume()
                }
            }

            // Establish the connection — this returns immediately; the ready
            // callback fires when connected.
            let connectFuture: EventLoopFuture<Void>
            if scheme == "wss" {
                // The pinned-identity connector is the only wss:// path: TLS
                // without the SPIFFE ID check would accept any workload in
                // the trust domain as the control plane (issue #552).
                guard let tlsConfig = tlsConfiguration, let pinning = spiffePinning else {
                    if !resumed.testAndSet(true) {
                        continuation.resume(
                            throwing: WebSocketClientError.connectionFailed(
                                "wss:// requires SPIFFE mTLS with a pinned control-plane identity"))
                    }
                    return
                }
                connectFuture = SPIFFEWebSocketConnector.connect(
                    to: url,
                    headers: headers,
                    tlsConfiguration: tlsConfig,
                    pinning: pinning,
                    maxFrameSize: maxFrameSize,
                    on: eventLoop,
                    logger: loggerRef,
                    onUpgrade: onWebSocketReady
                )
            } else {
                var wsConfig = WebSocketKit.WebSocketClient.Configuration()
                wsConfig.maxFrameSize = maxFrameSize
                connectFuture = WebSocket.connect(
                    to: url,
                    headers: headers,
                    configuration: wsConfig,
                    on: eventLoop,
                    onUpgrade: onWebSocketReady
                )
            }
            connectFuture.whenFailure { error in
                if !resumed.testAndSet(true) {
                    continuation.resume(
                        throwing: WebSocketClientError.connectionFailed(
                            "Failed to connect: \(error)"))
                }
            }
        }

        // Mark as connected and start heartbeat after successful connection
        guard connectionState.markConnected(generation),
            wsHolder.get(generation: generation) != nil
        else {
            connectionState.markConnectionFailed(generation)
            if let ws = wsHolder.get(generation: generation) {
                try? await ws.close().get()
            }
            wsHolder.clear(generation: generation)
            throw WebSocketClientError.connectionFailed(
                "Connection was superseded before it became current")
        }
        startHeartbeat(generation: generation)
        connectionBecameCurrent = true

        logger.info("WebSocket connect() returned - connection should stay alive")
        return generation
    }

    func isCurrentConnection(
        _ generation: ControlPlaneWebSocketState.Generation
    ) -> Bool {
        connectionState.connectedGeneration == generation
            && wsHolder.get(generation: generation) != nil
    }

    func disconnect() async {
        guard let generation = connectionState.beginIntentionalDisconnect() else { return }

        logger.info("Disconnecting from WebSocket server")

        // Stop heartbeat
        heartbeatTask?.cancel()
        heartbeatTask = nil

        // Close WebSocket
        if let ws = wsHolder.get(generation: generation) {
            try? await ws.close().get()
        }

        wsHolder.clear(generation: generation)
        _ = connectionState.markClosed(generation)
        logger.info("Disconnected from WebSocket server")
    }

    /// Releases the connection's event loop. Call once, after `disconnect()`,
    /// when this client will not be reused — the agent does so during shutdown.
    ///
    /// The group used to be torn down in `deinit` with `syncShutdownGracefully()`,
    /// a `DispatchSemaphore.wait()` that blocks whichever thread happens to
    /// release the last reference. That is usually a cooperative-pool thread (the
    /// heartbeat task holds the client strongly), so a shutdown step stalls the
    /// pool it is running on; and if the last release ever lands on one of this
    /// group's own event loops, NIO turns it into a `preconditionFailure`. Neither
    /// belongs in a deinit. Shutting the group down explicitly and asynchronously
    /// blocks nothing. See issue #522.
    func shutdown() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        do {
            try await eventLoopGroup.shutdownGracefully()
        } catch {
            logger.debug("Error shutting down WebSocket event loop group: \(error)")
        }
    }

    func sendMessage<T: WebSocketMessage>(_ message: T) async throws {
        guard let generation = connectionState.connectedGeneration,
            let ws = wsHolder.get(generation: generation)
        else {
            throw WebSocketClientError.notConnected
        }

        // Encode message to JSON. Do not propagate an encoder description: a
        // custom encoder can quote the value it rejected, including wire body
        // content, and callers log this error.
        let envelope: MessageEnvelope
        let data: Data
        do {
            envelope = try MessageEnvelope(message: message)
            data = try WireProtocol.makeEncoder().encode(envelope)
        } catch {
            throw WebSocketClientError.encodingError("message type \(message.type.rawValue)")
        }

        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw WebSocketClientError.encodingError("Failed to convert message to UTF-8")
        }

        // Send as text frame
        try await ws.send(jsonString)
        WireMessageLogger.log(
            message: message,
            direction: .outbound,
            byteCount: data.count,
            logger: logger)
    }

    // MARK: - Private Methods

    /// Invoked when the underlying WebSocket closes. Tears down connection state and,
    /// unless the close was operator-initiated, asks the agent to begin reconnecting.
    private func handleConnectionClosed(
        generation: ControlPlaneWebSocketState.Generation
    ) async {
        switch connectionState.markClosed(generation) {
        case .stale:
            logger.debug("Ignoring close callback from a superseded WebSocket connection")
            return
        case .intentional:
            heartbeatTask?.cancel()
            heartbeatTask = nil
            logger.debug("WebSocket closed intentionally; not reconnecting")
            return
        case .unexpected:
            heartbeatTask?.cancel()
            heartbeatTask = nil
        }

        logger.warning("WebSocket closed unexpectedly; requesting reconnection")
        await agent?.handleConnectionLost()
    }

    private func startHeartbeat(generation: ControlPlaneWebSocketState.Generation) {
        heartbeatTask?.cancel()
        heartbeatTask = Task {
            while !Task.isCancelled && isConnected
                && connectionState.connectedGeneration == generation
            {
                do {
                    // Send heartbeat every 20 seconds
                    try await Task.sleep(for: .seconds(20))
                    guard isConnected, connectionState.connectedGeneration == generation else {
                        return
                    }

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
        // Deliberately no `syncShutdownGracefully()` here: see `shutdown()`.
        // A blocking shutdown in deinit runs on whatever thread drops the last
        // reference, which may be one of this group's own event loops.
        heartbeatTask?.cancel()
    }
}

// MARK: - Errors

enum WebSocketClientError: Error, LocalizedError, Sendable {
    case invalidURL(String)
    case connectionFailed(String)
    case notConnected
    case encodingError(String)

    /// Whether this is the "the socket is down" refusal, which callers whose
    /// work the reconnect loop will re-drive report at `debug` rather than
    /// `error`.
    var isNotConnected: Bool {
        if case .notConnected = self { return true }
        return false
    }

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
