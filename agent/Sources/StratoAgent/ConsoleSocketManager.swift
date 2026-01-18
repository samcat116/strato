import Foundation
import Logging
import NIOCore
import NIOPosix

/// Manages Unix socket connections to QEMU virtio-console devices
actor ConsoleSocketManager {
    private let logger: Logger
    private let eventLoopGroup: EventLoopGroup

    /// Active console connections keyed by sessionId
    private var connections: [String: ConsoleConnection] = [:]

    /// Maps vmId to active sessionIds (multiple sessions can view same console)
    private var vmSessions: [String: Set<String>] = [:]

    /// Callback for sending console data to control plane
    private var onConsoleData: ((String, String, Data) async -> Void)?

    /// Track first data receipt per session to avoid noisy logs
    private var firstDataLogged: Set<String> = []

    struct ConsoleConnection {
        let vmId: String
        let socketPath: String
        let channel: Channel
        let readTask: Task<Void, Never>
    }

    init(logger: Logger, eventLoopGroup: EventLoopGroup) {
        self.logger = logger
        self.eventLoopGroup = eventLoopGroup
    }

    /// Sets the callback for console data output
    func setOnConsoleData(_ callback: @escaping (String, String, Data) async -> Void) {
        self.onConsoleData = callback
    }

    /// Connect to a VM's console socket
    func connect(vmId: String, sessionId: String, socketPath: String) async throws {
        logger.info("Connecting to console socket", metadata: [
            "vmId": .string(vmId),
            "sessionId": .string(sessionId),
            "socketPath": .string(socketPath)
        ])

        // Check if socket file exists
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw ConsoleError.socketNotFound(socketPath)
        }

        // Create channel handler for reading data
        let handler = ConsoleChannelHandler(
            sessionId: sessionId,
            vmId: vmId,
            onData: { [weak self] data in
                guard let self = self else { return }
                await self.handleIncomingData(sessionId: sessionId, vmId: vmId, data: data)
            },
            onClose: { [weak self] in
                guard let self = self else { return }
                await self.handleConnectionClosed(sessionId: sessionId)
            }
        )

        // Connect to Unix socket
        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }

        do {
            let channel = try await bootstrap.connect(unixDomainSocketPath: socketPath).get()

            // Create read task (the handler will process incoming data)
            let readTask = Task<Void, Never> {
                // The channel handler does the actual reading
                // This task just keeps a reference
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    channel.closeFuture.whenComplete { _ in
                        continuation.resume()
                    }
                }
            }

            let connection = ConsoleConnection(
                vmId: vmId,
                socketPath: socketPath,
                channel: channel,
                readTask: readTask
            )

            connections[sessionId] = connection

            // Track session for this VM
            if vmSessions[vmId] == nil {
                vmSessions[vmId] = []
            }
            vmSessions[vmId]?.insert(sessionId)

            logger.info("Console socket connected", metadata: [
                "vmId": .string(vmId),
                "sessionId": .string(sessionId)
            ])
        } catch {
            logger.error("Failed to connect to console socket", metadata: [
                "vmId": .string(vmId),
                "sessionId": .string(sessionId),
                "error": .string(error.localizedDescription)
            ])
            throw ConsoleError.connectionFailed(error.localizedDescription)
        }
    }

    /// Disconnect a console session
    func disconnect(sessionId: String) async {
        guard let connection = connections.removeValue(forKey: sessionId) else {
            logger.warning("Attempted to disconnect unknown session", metadata: [
                "sessionId": .string(sessionId)
            ])
            return
        }

        // Remove from VM sessions tracking
        vmSessions[connection.vmId]?.remove(sessionId)
        if vmSessions[connection.vmId]?.isEmpty == true {
            vmSessions.removeValue(forKey: connection.vmId)
        }

        // Cancel read task and close channel
        connection.readTask.cancel()
        do {
            try await connection.channel.close().get()
        } catch {
            logger.debug("Error closing channel (may already be closed)", metadata: [
                "sessionId": .string(sessionId),
                "error": .string(error.localizedDescription)
            ])
        }

        logger.info("Console session disconnected", metadata: [
            "vmId": .string(connection.vmId),
            "sessionId": .string(sessionId)
        ])
    }

    /// Write data to console (user input)
    func write(sessionId: String, data: Data) async throws {
        guard let connection = connections[sessionId] else {
            throw ConsoleError.sessionNotFound(sessionId)
        }

        let buffer = connection.channel.allocator.buffer(bytes: data)
        do {
            try await connection.channel.writeAndFlush(buffer).get()
        } catch {
            logger.error("Failed to write to console", metadata: [
                "sessionId": .string(sessionId),
                "error": .string(error.localizedDescription)
            ])
            throw ConsoleError.writeFailed(error.localizedDescription)
        }
    }

    /// Disconnect all sessions for a VM (used when VM is deleted)
    func disconnectAllForVM(vmId: String) async {
        guard let sessionIds = vmSessions[vmId] else { return }

        for sessionId in sessionIds {
            await disconnect(sessionId: sessionId)
        }
    }

    /// Check if a session exists
    func hasSession(sessionId: String) -> Bool {
        return connections[sessionId] != nil
    }

    /// Get all active sessions for a VM
    func getSessionsForVM(vmId: String) -> Set<String> {
        return vmSessions[vmId] ?? []
    }

    // MARK: - Private Methods

    private func handleIncomingData(sessionId: String, vmId: String, data: Data) async {
        if !firstDataLogged.contains(sessionId) {
            firstDataLogged.insert(sessionId)
            logger.info("Received first console data", metadata: [
                "sessionId": .string(sessionId),
                "vmId": .string(vmId),
                "bytes": .stringConvertible(data.count)
            ])
        } else {
            logger.debug("Received console data", metadata: [
                "sessionId": .string(sessionId),
                "vmId": .string(vmId),
                "bytes": .stringConvertible(data.count)
            ])
        }
        if let callback = onConsoleData {
            await callback(vmId, sessionId, data)
        }
    }

    private func handleConnectionClosed(sessionId: String) async {
        logger.info("Console connection closed by remote", metadata: [
            "sessionId": .string(sessionId)
        ])

        // Clean up the connection
        if let connection = connections.removeValue(forKey: sessionId) {
            vmSessions[connection.vmId]?.remove(sessionId)
            if vmSessions[connection.vmId]?.isEmpty == true {
                vmSessions.removeValue(forKey: connection.vmId)
            }
        }
        firstDataLogged.remove(sessionId)
    }
}

// MARK: - Console Channel Handler

/// NIO channel handler for console socket I/O
private final class ConsoleChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let sessionId: String
    private let vmId: String
    private let onData: @Sendable (Data) async -> Void
    private let onClose: @Sendable () async -> Void

    init(
        sessionId: String,
        vmId: String,
        onData: @escaping @Sendable (Data) async -> Void,
        onClose: @escaping @Sendable () async -> Void
    ) {
        self.sessionId = sessionId
        self.vmId = vmId
        self.onData = onData
        self.onClose = onClose
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let bytes = buffer.readBytes(length: buffer.readableBytes) {
            let data = Data(bytes)
            Task {
                await onData(data)
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        Task {
            await onClose()
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Log error and close
        context.close(promise: nil)
    }
}

// MARK: - Console Errors

enum ConsoleError: Error, LocalizedError {
    case socketNotFound(String)
    case connectionFailed(String)
    case sessionNotFound(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .socketNotFound(let path):
            return "Console socket not found: \(path)"
        case .connectionFailed(let message):
            return "Failed to connect to console: \(message)"
        case .sessionNotFound(let sessionId):
            return "Console session not found: \(sessionId)"
        case .writeFailed(let message):
            return "Failed to write to console: \(message)"
        }
    }
}
