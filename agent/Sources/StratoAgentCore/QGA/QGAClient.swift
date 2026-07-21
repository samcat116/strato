import Foundation
import Logging
import StratoShared

/// A raw bidirectional byte channel to a VM's qga unix socket. Abstracted so
/// the client's framing/resync/command logic is unit-testable against an
/// in-memory fake with no real socket (issue #563).
public protocol QGAByteChannel: Sendable {
    /// Write raw bytes to the guest agent socket.
    func write(_ bytes: [UInt8]) async throws
    /// Read the next available inbound bytes. Returns an empty array at EOF.
    /// May return fewer bytes than are ultimately available; callers loop.
    func readSome() async throws -> [UInt8]
    /// Close the channel. Idempotent.
    func close() async
}

/// Opens fresh channels to a VM's qga socket. One transport is bound to one
/// socket path; each probe opens (and closes) its own channel, which suits
/// qga's one-connection-at-a-time chardev and keeps every operation
/// self-contained.
public protocol QGATransport: Sendable {
    func openChannel() async throws -> any QGAByteChannel
}

/// Talks to a single VM's QEMU guest agent over a `QGATransport`.
///
/// Unlike QMP there is no greeting or capability handshake: every operation
/// opens a channel, resynchronizes the stream with `guest-sync-delimited`
/// (which also proves the agent is actually answering), issues its command(s),
/// and closes. qga is **unresponsive whenever the guest is not running the
/// agent**, so callers must bound every method with a `StageBudget` — a timeout
/// is the normal outcome for a qga-less or hung guest, not an exceptional one.
public actor QGAClient {
    public enum QGAError: Error, LocalizedError, Equatable {
        /// The channel reached EOF before a complete reply arrived.
        case connectionClosed
        /// The `guest-sync-delimited` reply carried a token that wasn't ours —
        /// the stream is unusable, so the whole operation is abandoned.
        case syncMismatch
        /// qga answered with an `{"error": ...}` object.
        case commandError(String)
        /// A reply decoded but lacked the expected `return` value.
        case malformedResponse

        public var errorDescription: String? {
            switch self {
            case .connectionClosed: return "qga channel closed before a complete reply"
            case .syncMismatch: return "qga sync token mismatch"
            case .commandError(let desc): return desc
            case .malformedResponse: return "qga reply missing its return value"
            }
        }
    }

    private let transport: any QGATransport
    private let logger: Logger
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    /// Monotonic token source for `guest-sync-delimited`; a fresh value per
    /// resync lets a reply be confirmed as answering *this* sync.
    private var syncCounter = 0

    public init(transport: any QGATransport, logger: Logger) {
        self.transport = transport
        self.logger = logger
    }

    // MARK: - High-level operations

    /// Confirms the guest agent is answering. Throws on any failure (including a
    /// timeout imposed by the caller's `StageBudget`), which the caller reads as
    /// "no usable qga".
    public func ping() async throws {
        try await withChannel { channel, framer in
            try await self.performSync(channel, framer)
            _ = try await self.commandNoArgs(channel, framer, execute: "guest-ping", as: QGA.Empty.self)
        }
    }

    /// Asks the guest to power itself down cleanly (`guest-shutdown`, mode
    /// `powerdown`). Returns normally once the command is on the wire against a
    /// responsive agent; the guest often powers off before replying, so a
    /// connection drop *after* a successful sync is treated as success, not
    /// failure.
    public func requestShutdown() async throws {
        try await withChannel { channel, framer in
            try await self.performSync(channel, framer)
            do {
                try await self.writeRequest(
                    channel, execute: "guest-shutdown", arguments: QGA.ShutdownArguments())
                let object = try await self.readNextObject(channel, framer)
                let response = try self.decoder.decode(QGA.Response<QGA.Empty>.self, from: Data(object))
                if let error = response.error { throw QGAError.commandError(error.description) }
            } catch QGAError.connectionClosed {
                // The guest went down before answering — exactly what we asked
                // for. The sync above already proved qga was alive.
            }
        }
    }

    /// Freezes the guest's filesystems (`guest-fsfreeze-freeze`) for an
    /// application-consistent snapshot. Returns the number of filesystems
    /// frozen. **The caller must guarantee a matching `thawFilesystems()`** — a
    /// frozen guest is worse than a crash-consistent snapshot.
    public func freezeFilesystems() async throws -> Int {
        try await withChannel { channel, framer in
            try await self.performSync(channel, framer)
            return try await self.commandNoArgs(
                channel, framer, execute: "guest-fsfreeze-freeze", as: Int.self)
        }
    }

    /// Thaws the guest's filesystems (`guest-fsfreeze-thaw`). Returns the number
    /// of filesystems thawed. Safe to call when nothing is frozen (qga returns
    /// 0), which is what makes it usable from an unconditional `defer`.
    public func thawFilesystems() async throws -> Int {
        try await withChannel { channel, framer in
            try await self.performSync(channel, framer)
            return try await self.commandNoArgs(
                channel, framer, execute: "guest-fsfreeze-thaw", as: Int.self)
        }
    }

    /// Collects the guest's hostname and configured network interfaces into the
    /// shared `GuestInfo`. The sync handshake proves `qgaAvailable`; the detail
    /// queries are best-effort, so a failure of one still yields a `GuestInfo`
    /// carrying the positive liveness signal and whatever else succeeded.
    public func collectGuestInfo() async throws -> GuestInfo {
        try await withChannel { channel, framer in
            try await self.performSync(channel, framer)

            var hostName: String?
            if let name = try? await self.commandNoArgs(
                channel, framer, execute: "guest-get-host-name", as: QGA.HostName.self)
            {
                hostName = name.hostName
            }

            var interfaces: [QGA.NetworkInterface] = []
            if let reported = try? await self.commandNoArgs(
                channel, framer, execute: "guest-network-get-interfaces",
                as: [QGA.NetworkInterface].self)
            {
                interfaces = reported
            }

            return GuestInfo.from(qgaAvailable: true, hostName: hostName, interfaces: interfaces)
        }
    }

    // MARK: - Channel lifecycle

    /// Opens a channel, runs `body`, and closes the channel whether or not
    /// `body` throws. `body` is non-escaping and runs within the actor, so it
    /// may call the actor's private helpers directly.
    private func withChannel<T>(
        _ body: (any QGAByteChannel, QGAObjectFramer) async throws -> T
    ) async throws -> T {
        let channel = try await transport.openChannel()
        let framer = QGAObjectFramer()
        do {
            let result = try await body(channel, framer)
            await channel.close()
            return result
        } catch {
            await channel.close()
            throw error
        }
    }

    // MARK: - Protocol primitives

    /// Resynchronizes the stream with `guest-sync-delimited`: reset the agent's
    /// parser with a leading `0xFF`, send a unique token, discard everything up
    /// to the reply's `0xFF` marker, then confirm the reply echoes the token.
    /// Succeeding here is the liveness proof every operation depends on.
    private func performSync(_ channel: any QGAByteChannel, _ framer: QGAObjectFramer) async throws {
        syncCounter += 1
        let token = syncCounter

        var payload: [UInt8] = [0xFF]  // reset the guest agent's JSON parser
        let request = QGA.Request(
            execute: "guest-sync-delimited", arguments: QGA.SyncArguments(id: token))
        payload.append(contentsOf: try encoder.encode(request))
        payload.append(0x0A)  // newline: harmless, and nudges line-buffered agents
        try await channel.write(payload)

        // Discard buffered bytes up to and including the reply's leading marker.
        while !framer.consumeThroughSyncMarker() {
            let chunk = try await channel.readSome()
            if chunk.isEmpty { throw QGAError.connectionClosed }
            framer.append(chunk)
            if framer.isOverBudget { throw QGAError.malformedResponse }
        }

        let object = try await readNextObject(channel, framer)
        let response = try decoder.decode(QGA.Response<Int>.self, from: Data(object))
        if let error = response.error { throw QGAError.commandError(error.description) }
        guard response.return == token else { throw QGAError.syncMismatch }
    }

    /// Sends a no-argument command and decodes its `return` value.
    private func commandNoArgs<Value: Decodable>(
        _ channel: any QGAByteChannel, _ framer: QGAObjectFramer,
        execute: String, as: Value.Type
    ) async throws -> Value {
        try await writeRequest(channel, execute: execute, arguments: QGA.NoArguments?.none)
        return try await readReturn(channel, framer, as: Value.self)
    }

    /// Encodes and writes a `{"execute": ...}` request (with `arguments` when
    /// present) followed by a newline.
    private func writeRequest<Arguments: Encodable>(
        _ channel: any QGAByteChannel, execute: String, arguments: Arguments?
    ) async throws {
        var payload = try Array(encoder.encode(QGA.Request(execute: execute, arguments: arguments)))
        payload.append(0x0A)
        try await channel.write(payload)
    }

    /// Reads the next reply object and returns its decoded `return` value,
    /// throwing on an `error` object or a missing `return`.
    private func readReturn<Value: Decodable>(
        _ channel: any QGAByteChannel, _ framer: QGAObjectFramer, as: Value.Type
    ) async throws -> Value {
        let object = try await readNextObject(channel, framer)
        let response = try decoder.decode(QGA.Response<Value>.self, from: Data(object))
        if let error = response.error { throw QGAError.commandError(error.description) }
        guard let value = response.return else { throw QGAError.malformedResponse }
        return value
    }

    /// Pulls chunks from the channel until the framer yields one complete JSON
    /// object. Throws `connectionClosed` at EOF.
    private func readNextObject(
        _ channel: any QGAByteChannel, _ framer: QGAObjectFramer
    ) async throws -> [UInt8] {
        while true {
            if let object = framer.nextObject() { return object }
            let chunk = try await channel.readSome()
            if chunk.isEmpty { throw QGAError.connectionClosed }
            framer.append(chunk)
            if framer.isOverBudget { throw QGAError.malformedResponse }
        }
    }
}

extension QGA {
    /// Decodable placeholder for commands whose `return` is an empty object.
    struct Empty: Decodable {}
}
