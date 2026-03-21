import Foundation
import NIOCore
import NIOPosix
import Logging

/// QMP Client for communicating with QEMU Monitor Protocol
public final class QMPClient: @unchecked Sendable {
    private let logger: Logger
    private let eventLoopGroup: EventLoopGroup
    private var channel: Channel?
    private var handler: QMPChannelHandler?
    
    /// Connection state
    private var isConnected = false
    private var capabilities: [String] = []
    
    public init(logger: Logger = Logger(label: "SwiftQEMU.QMPClient")) {
        self.logger = logger
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }
    
    deinit {
        try? eventLoopGroup.syncShutdownGracefully()
    }
    
    // MARK: - Connection Management
    
    /// Connect to QEMU via Unix domain socket
    public func connectUnix(path: String) async throws {
        logger.info("Connecting to QEMU via Unix socket", metadata: ["path": .string(path)])

        let handler = QMPChannelHandler(logger: logger)
        self.handler = handler

        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                return channel.pipeline.addHandler(handler)
            }

        // Retry connection with exponential backoff
        var retries = 0
        let maxRetries = 10
        var lastError: Error?

        while retries < maxRetries {
            do {
                self.channel = try await bootstrap.connect(unixDomainSocketPath: path).get()
                self.isConnected = true

                // Wait for greeting and negotiate capabilities
                try await negotiateCapabilities()

                logger.info("Connected to QEMU successfully")
                return
            } catch {
                // Clean up connection state before retry to avoid using stale connections
                self.isConnected = false
                self.channel = nil
                
                lastError = error
                retries += 1

                if retries < maxRetries {
                    let delay = UInt64(min(100_000_000 * (1 << retries), 1_000_000_000)) // Exponential backoff, max 1 second
                    logger.debug("QMP connection attempt \(retries) failed, retrying in \(Double(delay) / 1_000_000_000)s: \(error)")
                    try await Task.sleep(nanoseconds: delay)
                }
            }
        }

        logger.error("Failed to connect to QMP after \(maxRetries) retries: \(lastError?.localizedDescription ?? "unknown error")")
        throw lastError ?? QMPError.notConnected
    }
    
    /// Connect to QEMU via TCP socket
    public func connectTCP(host: String, port: Int) async throws {
        logger.info("Connecting to QEMU via TCP", metadata: [
            "host": .string(host),
            "port": .stringConvertible(port)
        ])
        
        let handler = QMPChannelHandler(logger: logger)
        self.handler = handler
        
        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                return channel.pipeline.addHandler(handler)
            }
        
        self.channel = try await bootstrap.connect(host: host, port: port).get()
        self.isConnected = true
        
        // Wait for greeting and negotiate capabilities
        try await negotiateCapabilities()
        
        logger.info("Connected to QEMU successfully")
    }
    
    /// Disconnect from QEMU
    public func disconnect() async throws {
        guard isConnected else { return }
        
        logger.info("Disconnecting from QEMU")
        
        try await channel?.close()
        self.isConnected = false
        self.channel = nil
        self.handler = nil
        
        logger.info("Disconnected from QEMU")
    }
    
    // MARK: - QMP Commands
    
    /// Execute a QMP command
    public func execute(_ command: QMPCommand, arguments: [String: Any]? = nil) async throws -> Any? {
        guard isConnected else {
            throw QMPError.notConnected
        }
        
        let request = QMPRequest(
            execute: command.name,
            arguments: arguments?.mapValues { AnyCodable($0) }
        )
        
        guard let response = try await sendRequest(request) else {
            throw QMPError.invalidResponse
        }
        
        if let error = response.error {
            throw QMPError.qmpError(error.class, error.desc)
        }
        
        return response.return?.value
    }
    
    /// Query VM status
    public func queryStatus() async throws -> QMPStatusResponse {
        let result = try await execute(.queryStatus)
        
        guard let dict = result as? [String: Any],
              let status = dict["status"] as? String,
              let running = dict["running"] as? Bool,
              let singlestep = dict["singlestep"] as? Bool else {
            throw QMPError.invalidResponse
        }
        
        return QMPStatusResponse(
            status: status,
            singlestep: singlestep,
            running: running
        )
    }
    
    /// Continue VM execution
    public func cont() async throws {
        _ = try await execute(.cont)
    }
    
    /// Stop/pause VM execution
    public func stop() async throws {
        _ = try await execute(.stop)
    }
    
    /// Power down the VM
    public func systemPowerdown() async throws {
        _ = try await execute(.systemPowerdown)
    }
    
    /// Reset the VM
    public func systemReset() async throws {
        _ = try await execute(.systemReset)
    }
    
    /// Quit QEMU
    public func quit() async throws {
        _ = try await execute(.quit)
    }
    
    // MARK: - Private Methods
    
    private func negotiateCapabilities() async throws {
        guard let handler = handler else {
            throw QMPError.notConnected
        }
        
        // Wait for greeting
        try await handler.waitForGreeting()
        
        // Send capabilities command
        let request = QMPRequest(execute: "qmp_capabilities")
        _ = try await sendRequest(request)
        
        logger.debug("QMP capabilities negotiated")
    }
    
    private func sendRequest(_ request: QMPRequest) async throws -> QMPResponse? {
        guard let handler = handler else {
            throw QMPError.notConnected
        }
        
        return try await handler.sendRequest(request)
    }
}

// MARK: - QMP Channel Handler

private final class QMPChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    
    private let logger: Logger
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    
    private var greetingContinuation: CheckedContinuation<Void, Error>?
    private var pendingRequests: [CheckedContinuation<QMPResponse?, Error>] = []
    private var buffer = ByteBuffer()
    
    init(logger: Logger) {
        self.logger = logger
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var input = self.unwrapInboundIn(data)
        buffer.writeBuffer(&input)
        
        // Process complete JSON messages
        while let message = extractJSONMessage() {
            processMessage(message)
        }
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        logger.debug("QMP channel became inactive")
        
        // Cancel pending operations
        for continuation in pendingRequests {
            continuation.resume(throwing: QMPError.connectionLost)
        }
        pendingRequests.removeAll()
        
        greetingContinuation?.resume(throwing: QMPError.connectionLost)
        greetingContinuation = nil
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("QMP channel error: \(error)")
        context.close(promise: nil)
    }
    
    func waitForGreeting() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.greetingContinuation = continuation
        }
    }
    
    func sendRequest(_ request: QMPRequest) async throws -> QMPResponse? {
        guard let channel = channel else {
            throw QMPError.notConnected
        }
        
        let data = try encoder.encode(request)
        var buffer = channel.allocator.buffer(capacity: data.count + 1)
        buffer.writeBytes(data)
        buffer.writeString("\n")
        
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests.append(continuation)
            channel.writeAndFlush(buffer, promise: nil)
        }
    }
    
    private weak var channel: Channel?
    
    func handlerAdded(context: ChannelHandlerContext) {
        self.channel = context.channel
    }
    
    private func extractJSONMessage() -> Data? {
        // Look for complete JSON objects ending with newline
        guard let newlineIndex = buffer.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) else {
            return nil
        }
        
        let messageLength = buffer.readableBytesView.startIndex.distance(to: newlineIndex) + 1
        guard let bytes = buffer.readBytes(length: messageLength) else {
            return nil
        }
        
        return Data(bytes.dropLast()) // Remove newline
    }
    
    private func processMessage(_ data: Data) {
        // Try to decode as greeting first
        if let greeting = try? decoder.decode(QMPGreeting.self, from: data) {
            logger.debug("Received QMP greeting", metadata: [
                "version": .stringConvertible("\(greeting.QMP.version.qemu.major).\(greeting.QMP.version.qemu.minor).\(greeting.QMP.version.qemu.micro)")
            ])
            greetingContinuation?.resume()
            greetingContinuation = nil
            return
        }

        // Try to decode as response
        if let response = try? decoder.decode(QMPResponse.self, from: data) {
            if !pendingRequests.isEmpty {
                let continuation = pendingRequests.removeFirst()
                continuation.resume(returning: response)
            }
            return
        }

        // Try to decode as event
        if let event = try? decoder.decode(QMPEvent.self, from: data) {
            logger.debug("Received QMP event", metadata: ["event": .string(event.event)])
            // Events are logged but not handled in this simple implementation
            return
        }

        logger.warning("Unknown QMP message format")
    }
}