import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOWebSocket
import NIOHTTP1
import StratoShared

class WebSocketClient {
    private let url: String
    private weak var agent: Agent?
    private let logger: Logger
    private let eventLoopGroup: MultiThreadedEventLoopGroup
    
    private var channel: Channel?
    private var isConnected = false
    
    init(url: String, agent: Agent, logger: Logger) {
        self.url = url
        self.agent = agent
        self.logger = logger
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }
    
    func connect() async throws {
        guard !isConnected else {
            logger.warning("WebSocket client is already connected")
            return
        }
        
        logger.info("Connecting to WebSocket server", metadata: ["url": .string(url)])
        
        // Parse URL
        guard let parsedURL = URL(string: url),
              let scheme = parsedURL.scheme,
              let host = parsedURL.host else {
            throw WebSocketClientError.invalidURL(url)
        }
        
        let port = parsedURL.port ?? (scheme == "wss" ? 443 : 80)
        let path = parsedURL.path.isEmpty ? "/" : parsedURL.path
        
        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelInitializer { channel in
                let httpHandler = HTTPClientRequestHandler()
                let websocketUpgrader = NIOWebSocketClientUpgrader(
                    requestKey: WebSocketRequestKey(),
                    upgradePipelineHandler: { channel, _ in
                        let websocketHandler = WebSocketFrameHandler(client: self)
                        return channel.pipeline.addHandler(websocketHandler)
                    }
                )
                
                let config = NIOHTTPClientUpgradeConfiguration(
                    upgradeRequestHead: HTTPRequestHead(
                        version: .http1_1,
                        method: .GET,
                        uri: path,
                        headers: HTTPHeaders([
                            ("Host", host),
                            ("Connection", "Upgrade"),
                            ("Upgrade", "websocket"),
                            ("Sec-WebSocket-Version", "13"),
                            ("Sec-WebSocket-Key", websocketUpgrader.requestKey)
                        ])
                    ),
                    upgraders: [websocketUpgrader],
                    completionHandler: { _ in }
                )
                
                return channel.pipeline.addHTTPClientHandlers(withClientUpgrade: config).flatMap {
                    channel.pipeline.addHandler(httpHandler)
                }
            }
        
        do {
            channel = try await bootstrap.connect(host: host, port: port).get()
            isConnected = true
            logger.info("Connected to WebSocket server successfully")
        } catch {
            logger.error("Failed to connect to WebSocket server: \(error)")
            throw WebSocketClientError.connectionFailed(error.localizedDescription)
        }
    }
    
    func disconnect() async {
        guard isConnected, let channel = channel else {
            return
        }
        
        logger.info("Disconnecting from WebSocket server")
        
        do {
            try await channel.close().get()
            self.channel = nil
            isConnected = false
            logger.info("Disconnected from WebSocket server")
        } catch {
            logger.error("Error during disconnect: \(error)")
        }
    }
    
    func sendMessage<T: WebSocketMessage>(_ message: T) async throws {
        guard isConnected, let channel = channel else {
            throw WebSocketClientError.notConnected
        }
        
        do {
            let envelope = try MessageEnvelope(message: message)
            let data = try JSONEncoder().encode(envelope)
            
            let frame = WebSocketFrame(
                fin: true,
                opcode: .text,
                data: ByteBuffer(data: data)
            )
            
            try await channel.writeAndFlush(frame).get()
            logger.debug("Message sent", metadata: ["type": .string(message.type.rawValue)])
        } catch {
            logger.error("Failed to send message: \(error)")
            throw WebSocketClientError.sendFailed(error.localizedDescription)
        }
    }
    
    deinit {
        try? eventLoopGroup.syncShutdownGracefully()
    }
}

// MARK: - WebSocket Frame Handler

private class WebSocketFrameHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    
    private weak var client: WebSocketClient?
    
    init(client: WebSocketClient) {
        self.client = client
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        
        guard case .text = frame.opcode else {
            return
        }
        
        guard let data = frame.data.getData(at: 0, length: frame.data.readableBytes) else {
            client?.logger.error("Failed to extract data from WebSocket frame")
            return
        }
        
        Task {
            do {
                let envelope = try JSONDecoder().decode(MessageEnvelope.self, from: data)
                await client?.agent?.handleMessage(envelope)
            } catch {
                client?.logger.error("Failed to decode WebSocket message: \(error)")
            }
        }
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        client?.logger.error("WebSocket error: \(error)")
        context.close(promise: nil)
    }
}

// MARK: - HTTP Client Request Handler

private class HTTPClientRequestHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart
}

// MARK: - WebSocket Request Key

private struct WebSocketRequestKey {
    let requestKey: String
    
    init() {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 {
            bytes[i] = UInt8.random(in: 0...255)
        }
        self.requestKey = Data(bytes).base64EncodedString()
    }
}

// MARK: - WebSocket Client Errors

enum WebSocketClientError: Error, LocalizedError {
    case invalidURL(String)
    case connectionFailed(String)
    case notConnected
    case sendFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid WebSocket URL: \(url)"
        case .connectionFailed(let reason):
            return "WebSocket connection failed: \(reason)"
        case .notConnected:
            return "WebSocket is not connected"
        case .sendFailed(let reason):
            return "Failed to send WebSocket message: \(reason)"
        }
    }
}