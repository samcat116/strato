import Foundation
import NIO
import NIOHTTP1
import NIOFoundationCompat
import Logging

/// Configuration for push-based event delivery server
public struct PushDeliveryConfiguration: Sendable {
    /// Port to listen on
    public let port: Int
    
    /// Host to bind to
    public let host: String
    
    /// Path for the webhook endpoint
    public let webhookPath: String
    
    /// Maximum request body size in bytes
    public let maxBodySize: Int
    
    /// Request timeout in seconds
    public let requestTimeout: TimeInterval
    
    /// Whether to validate Authorization header
    public let validateAuthorization: Bool
    
    /// Expected Authorization header value
    public let expectedAuthHeader: String?
    
    public init(
        port: Int = 8080,
        host: String = "0.0.0.0",
        webhookPath: String = "/ssf/events",
        maxBodySize: Int = 1024 * 1024, // 1MB
        requestTimeout: TimeInterval = 30.0,
        validateAuthorization: Bool = false,
        expectedAuthHeader: String? = nil
    ) {
        self.port = port
        self.host = host
        self.webhookPath = webhookPath
        self.maxBodySize = maxBodySize
        self.requestTimeout = requestTimeout
        self.validateAuthorization = validateAuthorization
        self.expectedAuthHeader = expectedAuthHeader
    }
}

/// Push-based event delivery server
public final class PushEventDelivery: Sendable {
    private let receiver: SSFReceiver
    private let configuration: PushDeliveryConfiguration
    private let eventHandler: SSFEventHandler
    private let logger = Logger(label: "SwiftSSF.PushEventDelivery")
    
    private let eventLoopGroup: EventLoopGroup
    private var serverBootstrap: ServerBootstrap?
    private var serverChannel: Channel?
    
    public init(
        receiver: SSFReceiver,
        configuration: PushDeliveryConfiguration = PushDeliveryConfiguration(),
        eventHandler: SSFEventHandler,
        eventLoopGroup: EventLoopGroup? = nil
    ) {
        self.receiver = receiver
        self.configuration = configuration
        self.eventHandler = eventHandler
        self.eventLoopGroup = eventLoopGroup ?? MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    }
    
    /// Start the push delivery server
    public func start() async throws {
        guard serverChannel == nil else {
            logger.warning("Push delivery server is already running")
            return
        }
        
        logger.info("Starting push delivery server on \(configuration.host):\(configuration.port)")
        
        serverBootstrap = ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        SSFWebhookHandler(
                            receiver: self.receiver,
                            configuration: self.configuration,
                            eventHandler: self.eventHandler
                        )
                    )
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
        
        do {
            serverChannel = try await serverBootstrap!.bind(host: configuration.host, port: configuration.port).get()
            logger.info("Push delivery server started successfully")
        } catch {
            logger.error("Failed to start push delivery server: \(error)")
            throw SSFError.serverError("Failed to start server: \(error.localizedDescription)")
        }
    }
    
    /// Stop the push delivery server
    public func stop() async throws {
        guard let channel = serverChannel else {
            logger.warning("Push delivery server is not running")
            return
        }
        
        logger.info("Stopping push delivery server")
        
        try await channel.close()
        serverChannel = nil
        serverBootstrap = nil
        
        logger.info("Push delivery server stopped")
    }
    
    /// Get the server's listening address
    public var localAddress: SocketAddress? {
        return serverChannel?.localAddress
    }
    
    /// Check if the server is running
    public var isRunning: Bool {
        return serverChannel != nil
    }
}

/// HTTP handler for SSF webhook requests
final class SSFWebhookHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    
    private let receiver: SSFReceiver
    private let configuration: PushDeliveryConfiguration
    private let eventHandler: SSFEventHandler
    private let logger = Logger(label: "SwiftSSF.WebhookHandler")
    
    private var requestHead: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer?
    
    init(
        receiver: SSFReceiver,
        configuration: PushDeliveryConfiguration,
        eventHandler: SSFEventHandler
    ) {
        self.receiver = receiver
        self.configuration = configuration
        self.eventHandler = eventHandler
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        
        switch part {
        case .head(let head):
            handleRequestHead(context: context, head: head)
            
        case .body(let buffer):
            handleRequestBody(context: context, buffer: buffer)
            
        case .end:
            handleRequestEnd(context: context)
        }
    }
    
    private func handleRequestHead(context: ChannelHandlerContext, head: HTTPRequestHead) {
        requestHead = head
        bodyBuffer = context.channel.allocator.buffer(capacity: 0)
        
        // Validate request path
        guard head.uri == configuration.webhookPath else {
            sendResponse(context: context, status: .notFound, body: "Not Found")
            return
        }
        
        // Validate HTTP method
        guard head.method == .POST else {
            sendResponse(context: context, status: .methodNotAllowed, body: "Method Not Allowed")
            return
        }
        
        // Validate Authorization header if required
        if configuration.validateAuthorization {
            guard let expectedAuth = configuration.expectedAuthHeader,
                  let authHeader = head.headers.first(name: "Authorization"),
                  authHeader == expectedAuth else {
                sendResponse(context: context, status: .unauthorized, body: "Unauthorized")
                return
            }
        }
        
        // Validate Content-Type
        guard let contentType = head.headers.first(name: "Content-Type"),
              contentType.contains("application/json") else {
            sendResponse(context: context, status: .badRequest, body: "Content-Type must be application/json")
            return
        }
    }
    
    private func handleRequestBody(context: ChannelHandlerContext, buffer: ByteBuffer) {
        guard var bodyBuffer = bodyBuffer else { return }
        
        // Check body size limit
        if bodyBuffer.readableBytes + buffer.readableBytes > configuration.maxBodySize {
            sendResponse(context: context, status: HTTPResponseStatus(statusCode: 413), body: "Request body too large")
            return
        }
        
        bodyBuffer.writeImmutableBuffer(buffer)
        self.bodyBuffer = bodyBuffer
    }
    
    private func handleRequestEnd(context: ChannelHandlerContext) {
        guard let head = requestHead,
              let bodyBuffer = bodyBuffer else {
            sendResponse(context: context, status: .badRequest, body: "Invalid request")
            return
        }
        
        Task {
            await processWebhookRequest(context: context, head: head, body: bodyBuffer)
        }
    }
    
    private func processWebhookRequest(
        context: ChannelHandlerContext,
        head: HTTPRequestHead,
        body: ByteBuffer
    ) async {
        do {
            let bodyData = Data(buffer: body)
            
            // Parse the request body as a SET token
            guard let jsonObject = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                  let setToken = jsonObject["SET"] as? String else {
                sendResponse(context: context, status: .badRequest, body: "Missing or invalid SET token")
                return
            }
            
            logger.debug("Received SET token via webhook")
            
            // Process the security event token
            await receiver.processSecurityEventToken(setToken, handler: eventHandler)
            
            // Send success response
            sendResponse(context: context, status: .accepted, body: "")
            
        } catch {
            logger.error("Failed to process webhook request: \(error)")
            sendResponse(context: context, status: .badRequest, body: "Failed to process event")
        }
    }
    
    private func sendResponse(
        context: ChannelHandlerContext,
        status: HTTPResponseStatus,
        body: String
    ) {
        let responseHead = HTTPResponseHead(
            version: .http1_1,
            status: status,
            headers: HTTPHeaders([
                ("Content-Length", String(body.utf8.count)),
                ("Content-Type", "text/plain"),
                ("Connection", "close")
            ])
        )
        
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        
        if !body.isEmpty {
            let bodyBuffer = context.channel.allocator.buffer(string: body)
            context.write(wrapOutboundOut(.body(.byteBuffer(bodyBuffer))), promise: nil)
        }
        
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("Webhook handler error: \(error)")
        context.close(promise: nil)
    }
}

// MARK: - Convenience Extensions

extension SSFReceiver {
    /// Start a push delivery server
    public func startPushServer(
        configuration: PushDeliveryConfiguration = PushDeliveryConfiguration(),
        eventHandler: SSFEventHandler,
        eventLoopGroup: EventLoopGroup? = nil
    ) async throws -> PushEventDelivery {
        let pushService = PushEventDelivery(
            receiver: self,
            configuration: configuration,
            eventHandler: eventHandler,
            eventLoopGroup: eventLoopGroup
        )
        
        try await pushService.start()
        return pushService
    }
}

/// Multi-endpoint push server for handling multiple streams
public actor MultiStreamPushServer {
    private let eventLoopGroup: EventLoopGroup
    private var pushServers: [String: PushEventDelivery] = [:]
    private let logger = Logger(label: "SwiftSSF.MultiStreamPushServer")
    
    public init(eventLoopGroup: EventLoopGroup? = nil) {
        self.eventLoopGroup = eventLoopGroup ?? MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    }
    
    /// Add a push server for a specific stream
    public func addStream(
        _ streamId: String,
        receiver: SSFReceiver,
        configuration: PushDeliveryConfiguration,
        eventHandler: SSFEventHandler
    ) async throws {
        if pushServers[streamId] != nil {
            logger.warning("Stream \(streamId) already has a push server")
            return
        }
        
        let pushService = PushEventDelivery(
            receiver: receiver,
            configuration: configuration,
            eventHandler: eventHandler,
            eventLoopGroup: eventLoopGroup
        )
        
        try await pushService.start()
        pushServers[streamId] = pushService
        
        logger.info("Added push server for stream \(streamId) on port \(configuration.port)")
    }
    
    /// Remove a push server for a stream
    public func removeStream(_ streamId: String) async throws {
        guard let pushService = pushServers[streamId] else {
            logger.warning("Stream \(streamId) does not have a push server")
            return
        }
        
        try await pushService.stop()
        pushServers.removeValue(forKey: streamId)
        
        logger.info("Removed push server for stream \(streamId)")
    }
    
    /// Stop all push servers
    public func stopAll() async throws {
        logger.info("Stopping all push servers")
        
        for (streamId, pushService) in pushServers {
            try await pushService.stop()
            logger.debug("Stopped push server for stream \(streamId)")
        }
        
        pushServers.removeAll()
    }
    
    /// Get status of all push servers
    public func getStatus() -> [String: Bool] {
        var status: [String: Bool] = [:]
        
        for (streamId, pushService) in pushServers {
            status[streamId] = pushService.isRunning
        }
        
        return status
    }
}