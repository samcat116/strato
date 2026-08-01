import Foundation
import Logging
import NIOCore
import NIOPosix
import StratoAgentCore
import StratoShared

/// Manages Unix socket connections to a VM's console devices — the serial /
/// virtio-console pair, and (issue #566) the VNC server that carries its
/// framebuffer. Every stream is relayed as opaque bytes, so this type needs no
/// knowledge of RFB.
actor ConsoleSocketManager {
    private let logger: Logger
    private let eventLoopGroup: EventLoopGroup

    /// Active console connections keyed by sessionId
    private var connections: [String: ConsoleConnection] = [:]

    /// Maps vmId to active sessionIds (multiple sessions can view same console)
    private var vmSessions: [String: Set<String>] = [:]

    /// Callback for sending console data to control plane
    private var onConsoleData: ((String, String, Data) async -> Void)?

    /// Callback for reporting a console socket that closed on its own — the
    /// guest powered off, or QEMU exited underneath a live session. Without it
    /// the browser holds an open WebSocket onto a console that is gone.
    private var onConsoleClosed: ((String, String, String) async -> Void)?

    /// Track first data receipt per session to avoid noisy logs
    private var firstDataLogged: Set<String> = []

    struct ConsoleConnection {
        let vmId: String
        /// Which of the VM's consoles this session attached to. Sessions on
        /// different streams of one VM are independent and must not evict each
        /// other.
        let stream: ConsoleStream
        let socketPath: String
        let channel: Channel
        /// Serializes socket reads on their way to the control plane. Reads
        /// used to be forwarded from a detached task each, which can transpose
        /// them — survivable for a text console, fatal for RFB.
        let relay: OrderedByteRelay
    }

    init(logger: Logger, eventLoopGroup: EventLoopGroup) {
        self.logger = logger
        self.eventLoopGroup = eventLoopGroup
    }

    /// Sets the callback for console data output
    func setOnConsoleData(_ callback: @escaping (String, String, Data) async -> Void) {
        self.onConsoleData = callback
    }

    /// Sets the callback for a console socket closing by itself, as
    /// `(vmId, sessionId, reason)`.
    func setOnConsoleClosed(_ callback: @escaping (String, String, String) async -> Void) {
        self.onConsoleClosed = callback
    }

    /// Connect to one of a VM's console sockets
    func connect(vmId: String, sessionId: String, stream: ConsoleStream, socketPath: String) async throws {
        logger.info(
            "Connecting to console socket",
            metadata: [
                "vmId": .string(vmId),
                "sessionId": .string(sessionId),
                "stream": .string(stream.rawValue),
                "socketPath": .string(socketPath),
            ])

        // Check if socket file exists
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw ConsoleError.socketNotFound(socketPath)
        }

        // One relay per session: the channel handler yields into it
        // synchronously on its event loop, and the relay's single consumer
        // hands chunks to the control plane one at a time, in arrival order.
        let relay = OrderedByteRelay { [weak self] data in
            guard let self = self else { return }
            await self.handleIncomingData(sessionId: sessionId, vmId: vmId, data: data)
        }

        // Create channel handler for reading data
        let handler = ConsoleChannelHandler(
            sessionId: sessionId,
            vmId: vmId,
            relay: relay,
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

            let connection = ConsoleConnection(
                vmId: vmId,
                stream: stream,
                socketPath: socketPath,
                channel: channel,
                relay: relay
            )

            connections[sessionId] = connection

            // Track session for this VM
            if vmSessions[vmId] == nil {
                vmSessions[vmId] = []
            }
            vmSessions[vmId]?.insert(sessionId)

            logger.info(
                "Console socket connected",
                metadata: [
                    "vmId": .string(vmId),
                    "sessionId": .string(sessionId),
                    "stream": .string(stream.rawValue),
                ])
        } catch {
            relay.cancel()
            logger.error(
                "Failed to connect to console socket",
                metadata: [
                    "vmId": .string(vmId),
                    "sessionId": .string(sessionId),
                    "error": .string(error.localizedDescription),
                ])
            throw ConsoleError.connectionFailed(error.localizedDescription)
        }
    }

    /// Disconnect a console session
    func disconnect(sessionId: String) async {
        guard let connection = connections.removeValue(forKey: sessionId) else {
            logger.warning(
                "Attempted to disconnect unknown session",
                metadata: [
                    "sessionId": .string(sessionId)
                ])
            return
        }

        // Remove from VM sessions tracking
        vmSessions[connection.vmId]?.remove(sessionId)
        if vmSessions[connection.vmId]?.isEmpty == true {
            vmSessions.removeValue(forKey: connection.vmId)
        }

        // Stop the relay and close the channel. Cancel rather than finish: the
        // browser side is already gone, so queued bytes have nowhere to go.
        connection.relay.cancel()
        do {
            try await connection.channel.close().get()
        } catch {
            logger.debug(
                "Error closing channel (may already be closed)",
                metadata: [
                    "sessionId": .string(sessionId),
                    "error": .string(error.localizedDescription),
                ])
        }

        logger.info(
            "Console session disconnected",
            metadata: [
                "vmId": .string(connection.vmId),
                "sessionId": .string(sessionId),
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
            logger.error(
                "Failed to write to console",
                metadata: [
                    "sessionId": .string(sessionId),
                    "error": .string(error.localizedDescription),
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

    /// Disconnect only the sessions attached to one of a VM's consoles.
    ///
    /// Stale-session cleanup has to be scoped this way: a VM's text and
    /// graphics consoles are independent surfaces, and a user opening the
    /// Display tab must not knock out the serial console they already have open
    /// on the same VM (issue #566).
    func disconnectAllForVM(vmId: String, stream: ConsoleStream) async {
        guard let sessionIds = vmSessions[vmId] else { return }

        for sessionId in sessionIds where connections[sessionId]?.stream == stream {
            await disconnect(sessionId: sessionId)
        }
    }

    /// The active sessions for a VM on one of its consoles.
    func getSessionsForVM(vmId: String, stream: ConsoleStream) -> Set<String> {
        Set((vmSessions[vmId] ?? []).filter { connections[$0]?.stream == stream })
    }

    /// Disconnect every active console session. Used when the control-plane
    /// connection drops: the control plane tears down this agent's console
    /// sessions on socket loss (browsers must re-establish after we reconnect),
    /// so these pty channels would otherwise leak, streaming output to session
    /// IDs the control plane has already deleted.
    func disconnectAll() async {
        for sessionId in Array(connections.keys) {
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
            logger.info(
                "Received first console data",
                metadata: [
                    "sessionId": .string(sessionId),
                    "vmId": .string(vmId),
                    "bytes": .stringConvertible(data.count),
                ])
        } else {
            logger.debug(
                "Received console data",
                metadata: [
                    "sessionId": .string(sessionId),
                    "vmId": .string(vmId),
                    "bytes": .stringConvertible(data.count),
                ])
        }
        if let callback = onConsoleData {
            await callback(vmId, sessionId, data)
        }
    }

    private func handleConnectionClosed(sessionId: String) async {
        logger.info(
            "Console connection closed by remote",
            metadata: [
                "sessionId": .string(sessionId)
            ])

        // Clean up the connection. `finish` rather than `cancel`: the socket
        // went away but the browser is still attached, so whatever the guest
        // wrote before the close still has somewhere to go.
        //
        // An entry still being here means the socket closed on its own rather
        // than being torn down by `disconnect`, which removes it first — so
        // this is the guest going away underneath a live session, and the
        // browser has to be told. Otherwise its WebSocket stays open onto a
        // console that no longer exists.
        guard let connection = connections.removeValue(forKey: sessionId) else {
            firstDataLogged.remove(sessionId)
            return
        }
        connection.relay.finish()
        vmSessions[connection.vmId]?.remove(sessionId)
        if vmSessions[connection.vmId]?.isEmpty == true {
            vmSessions.removeValue(forKey: connection.vmId)
        }
        firstDataLogged.remove(sessionId)

        await onConsoleClosed?(connection.vmId, sessionId, "The VM's console closed")
    }
}

// MARK: - Console Channel Handler

/// NIO channel handler for console socket I/O
private final class ConsoleChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let sessionId: String
    private let vmId: String
    private let relay: OrderedByteRelay
    private let onClose: @Sendable () async -> Void

    init(
        sessionId: String,
        vmId: String,
        relay: OrderedByteRelay,
        onClose: @escaping @Sendable () async -> Void
    ) {
        self.sessionId = sessionId
        self.vmId = vmId
        self.relay = relay
        self.onClose = onClose
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let bytes = buffer.readBytes(length: buffer.readableBytes) {
            // Synchronous hand-off on the event loop, so enqueue order is
            // arrival order. Spawning a Task here instead would let two reads
            // reach the control plane transposed — invisible on a text console,
            // and unrecoverable for an RFB stream.
            relay.send(Data(bytes))
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
