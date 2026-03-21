import Foundation
import NIO
import NIOPosix
import Logging

public final class UnixSocketConnection {
    private let eventLoopGroup: EventLoopGroup
    private let logger: Logger
    private var channel: Channel?
    private let socketPath: String
    private var isConnected: Bool = false
    
    public init(socketPath: String, eventLoopGroup: EventLoopGroup? = nil, logger: Logger? = nil) {
        self.socketPath = socketPath
        self.eventLoopGroup = eventLoopGroup ?? MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.logger = logger ?? Logger(label: "ovn-manager.unix-socket")
    }
    
    deinit {
        try? disconnect().wait()
    }
    
    public func connect() -> EventLoopFuture<Void> {
        guard !isConnected else {
            return eventLoopGroup.next().makeSucceededFuture(())
        }
        
        logger.info("Connecting to Unix socket at: \(socketPath)")
        
        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
                    ByteToMessageHandler(LineDelimitedFrameDecoder()),
                    MessageToByteHandler(StringToByteEncoder()),
                    ByteToMessageHandler(ByteToStringDecoder())
                ])
            }
        
        return bootstrap.connect(unixDomainSocketPath: socketPath)
            .map { channel in
                self.channel = channel
                self.isConnected = true
                self.logger.info("Successfully connected to Unix socket")
            }
            .flatMapError { error in
                self.logger.error("Failed to connect to Unix socket: \(error)")
                return self.eventLoopGroup.next().makeFailedFuture(OVNManagerError.connectionFailed("Failed to connect to \(self.socketPath): \(error)"))
            }
    }
    
    public func disconnect() -> EventLoopFuture<Void> {
        guard let channel = channel, isConnected else {
            return eventLoopGroup.next().makeSucceededFuture(())
        }
        
        logger.info("Disconnecting from Unix socket")
        self.isConnected = false
        
        return channel.close().map {
            self.channel = nil
            self.logger.info("Successfully disconnected from Unix socket")
        }
    }
    
    public func send<T: Codable>(_ message: T) -> EventLoopFuture<Void> {
        guard let channel = channel, isConnected else {
            return eventLoopGroup.next().makeFailedFuture(
                OVNManagerError.connectionFailed("Not connected to socket")
            )
        }
        
        do {
            let encoder = Foundation.JSONEncoder()
            let data = try encoder.encode(message)
            guard let jsonString = String(data: data, encoding: .utf8) else {
                throw OVNManagerError.encodingError(
                    NSError(domain: "UnixSocketConnection", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert data to string"])
                )
            }
            
            logger.debug("Sending message: \(jsonString)")
            return channel.writeAndFlush(jsonString + "\n")
        } catch {
            logger.error("Failed to encode message: \(error)")
            return eventLoopGroup.next().makeFailedFuture(OVNManagerError.encodingError(error))
        }
    }
    
    public func receive<T: Codable>(as type: T.Type, timeout: TimeAmount = .seconds(30)) -> EventLoopFuture<T> {
        guard let channel = channel, isConnected else {
            return eventLoopGroup.next().makeFailedFuture(
                OVNManagerError.connectionFailed("Not connected to socket")
            )
        }
        
        let promise = eventLoopGroup.next().makePromise(of: T.self)
        
        let timeoutTask = eventLoopGroup.next().scheduleTask(in: timeout) {
            promise.fail(OVNManagerError.timeoutError)
        }
        
        // Set up a handler to capture the next message
        let responseHandler = UnixSocketResponseHandler<T> { result in
            timeoutTask.cancel()
            switch result {
            case .success(let response):
                promise.succeed(response)
            case .failure(let error):
                promise.fail(error)
            }
        }
        
        _ = channel.pipeline.addHandler(responseHandler)
        
        return promise.futureResult.always { _ in
            _ = channel.pipeline.removeHandler(responseHandler)
        }
    }
    
    public var isConnectionActive: Bool {
        return isConnected && channel?.isActive == true
    }
}

// MARK: - Response Handler

private final class UnixSocketResponseHandler<T: Codable>: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = String
    
    private let completion: (Result<T, Error>) -> Void
    private let decoder = Foundation.JSONDecoder()
    
    init(completion: @escaping (Result<T, Error>) -> Void) {
        self.completion = completion
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        
        do {
            guard let data = message.data(using: .utf8) else {
                throw OVNManagerError.decodingError(
                    NSError(domain: "UnixSocketResponseHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert string to data"])
                )
            }
            
            let response = try decoder.decode(T.self, from: data)
            completion(.success(response))
        } catch {
            completion(.failure(OVNManagerError.decodingError(error)))
        }
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        completion(.failure(error))
    }
}

// MARK: - Frame Handling

private final class LineDelimitedFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = String
    
    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        // Look for a newline in the buffer
        if let newlineIndex = buffer.withUnsafeReadableBytes({ bytes in
            bytes.firstIndex(of: UInt8(ascii: "\n"))
        }) {
            // Read up to and including the newline
            guard let line = buffer.readString(length: newlineIndex + 1) else {
                return .needMoreData
            }
            
            // Trim whitespace and newlines, then fire the message
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                context.fireChannelRead(wrapInboundOut(trimmed))
            }
            
            // Continue processing if there's more data
            return .continue
        }
        
        // No complete line yet, wait for more data
        return .needMoreData
    }
}

private final class StringToByteEncoder: MessageToByteEncoder {
    typealias OutboundIn = String
    
    func encode(data: String, out: inout ByteBuffer) throws {
        out.writeString(data)
    }
}

private final class ByteToStringDecoder: ByteToMessageDecoder {
    typealias InboundOut = String
    
    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let string = buffer.readString(length: buffer.readableBytes) else {
            return .needMoreData
        }
        
        context.fireChannelRead(wrapInboundOut(string.trimmingCharacters(in: .whitespacesAndNewlines)))
        return .continue
    }
}