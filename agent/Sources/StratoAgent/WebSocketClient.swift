import Foundation
import WebSocketKit
import NIOCore
import NIOPosix
import Logging
import StratoShared

class WebSocketClient {
    private let url: String
    weak var agent: Agent?
    let logger: Logger
    private let eventLoopGroup: MultiThreadedEventLoopGroup

    private var ws: WebSocket?
    private var isConnected = false
    private var heartbeatTask: Task<Void, Never>?

    init(url: String, agent: Agent, logger: Logger) {
        self.url = url
        self.agent = agent
        self.logger = logger
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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

        logger.debug("Connecting with WebSocketKit")

        // Create connection and wait for it to be established
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false

            // Create connection - this returns immediately, callback fires when connected
            _ = WebSocket.connect(
                to: url,
                on: eventLoopGroup.next()
            ) { [weak self] ws in
                guard let self = self else {
                    if !resumed {
                        resumed = true
                        continuation.resume(throwing: WebSocketClientError.connectionFailed("Client deallocated"))
                    }
                    return
                }

                // Connection established - store reference and set up handlers
                self.ws = ws
                self.isConnected = true

                ws.onText { [weak self] ws, text in
                    self?.logger.debug("Received WebSocket text message", metadata: ["text": .string(text)])
                }

                ws.onBinary { [weak self] ws, buffer in
                    guard let self = self else { return }

                    self.logger.debug("Received WebSocket binary message")

                    // Convert binary buffer to string
                    guard let text = buffer.getString(at: 0, length: buffer.readableBytes) else {
                        self.logger.error("Failed to convert binary buffer to string")
                        return
                    }

                    // Parse JSON to MessageEnvelope
                    guard let data = text.data(using: .utf8) else {
                        self.logger.error("Failed to convert string to UTF-8 data")
                        return
                    }

                    do {
                        let envelope = try JSONDecoder().decode(MessageEnvelope.self, from: data)
                        self.logger.info("Received message from control plane", metadata: [
                            "type": .string(envelope.type.rawValue)
                        ])

                        // Handle message asynchronously
                        Task {
                            await self.agent?.handleMessage(envelope)
                        }
                    } catch {
                        self.logger.error("Failed to decode message: \(error)")
                    }
                }

                ws.onClose.whenComplete { [weak self] result in
                    self?.logger.info("WebSocket connection closed")
                    self?.isConnected = false
                }

                self.logger.info("WebSocket connection established and ready")
                self.startHeartbeat()

                // Resume to indicate successful connection
                if !resumed {
                    resumed = true
                    continuation.resume()
                }
            }.whenFailure { error in
                if !resumed {
                    resumed = true
                    continuation.resume(throwing: WebSocketClientError.connectionFailed("Failed to connect: \(error.localizedDescription)"))
                }
            }
        }

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
        if let ws = ws {
            try? await ws.close().get()
        }

        ws = nil
        isConnected = false
        logger.info("Disconnected from WebSocket server")
    }

    func sendMessage<T: WebSocketMessage>(_ message: T) async throws {
        guard isConnected, let ws = ws else {
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

enum WebSocketClientError: Error, LocalizedError {
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
