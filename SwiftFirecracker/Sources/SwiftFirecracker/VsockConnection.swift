import Foundation
import Logging

#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Closes a raw file descriptor via the platform C library, avoiding any clash
/// with ``VsockConnection/close()``.
private func closeFD(_ fd: Int32) {
    #if os(Linux)
    _ = Glibc.close(fd)
    #else
    _ = Darwin.close(fd)
    #endif
}

/// Shuts down both directions of a connected socket via the platform C
/// library. Unlike `close(2)`, `shutdown(2)` wakes any thread parked in a
/// blocking `read(2)` on the same fd (the read returns 0/EOF), which is what
/// lets ``VsockConnection/close()`` unblock an in-flight read.
private func shutdownFD(_ fd: Int32) {
    #if os(Linux)
    _ = Glibc.shutdown(fd, Int32(SHUT_RDWR))
    #else
    _ = Darwin.shutdown(fd, SHUT_RDWR)
    #endif
}

/// A host-initiated connection to a guest vsock port, established through a
/// Firecracker vsock device's Unix-domain socket.
///
/// Firecracker multiplexes host↔guest vsock traffic over a single UDS (the
/// `udsPath` of a ``VsockConfig``). To reach a port the guest is listening on,
/// the host opens that UDS and sends a `CONNECT <port>\n` line; Firecracker
/// replies `OK <host_port>\n` once the guest accepts, after which the socket is
/// a raw bidirectional byte stream to the guest application.
///
/// ``connect(udsPath:port:timeout:retryInterval:logger:)`` wraps that handshake
/// with retry/timeout, because at boot the UDS may not exist yet and the guest
/// application may not be listening yet — both surface as transient failures
/// that clear once the guest is up.
public actor VsockConnection {
    /// The connected socket file descriptor. Owned by this connection until
    /// ``close()``; do not close it directly.
    private var fd: Int32?
    private let logger: Logger

    /// The host-side port Firecracker assigned to this connection, parsed from
    /// the `OK <host_port>` handshake reply. Immutable, so readable without
    /// awaiting the actor.
    public nonisolated let assignedHostPort: UInt32

    private init(fd: Int32, assignedHostPort: UInt32, logger: Logger) {
        self.fd = fd
        self.assignedHostPort = assignedHostPort
        self.logger = logger
    }

    /// Opens a connection to `port` on the guest through the vsock UDS at
    /// `udsPath`, retrying until `timeout` elapses.
    ///
    /// - Parameters:
    ///   - udsPath: The vsock device's host Unix-domain socket path (the
    ///     `udsPath` passed to ``VsockConfig``).
    ///   - port: The vsock port the guest application is listening on.
    ///   - timeout: Total wall-clock budget for establishing the connection.
    ///     Boot-time races (missing UDS, guest not yet listening) are retried
    ///     within this budget.
    ///   - retryInterval: Delay between attempts.
    ///   - logger: Logger for diagnostics.
    /// - Throws: ``FirecrackerError/timeout`` if no attempt succeeds before the
    ///   budget elapses, wrapping the last underlying error.
    public static func connect(
        udsPath: String,
        port: UInt32,
        timeout: TimeInterval = 10.0,
        retryInterval: TimeInterval = 0.1,
        logger: Logger = Logger(label: "SwiftFirecracker.Vsock")
    ) async throws -> VsockConnection {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?

        while Date() < deadline {
            do {
                let (fd, hostPort) = try await attempt(udsPath: udsPath, port: port)
                logger.debug(
                    "Connected to guest vsock port",
                    metadata: ["uds": "\(udsPath)", "port": "\(port)", "host_port": "\(hostPort)"])
                return VsockConnection(fd: fd, assignedHostPort: hostPort, logger: logger)
            } catch {
                lastError = error
                try? await Task.sleep(nanoseconds: UInt64(retryInterval * 1_000_000_000))
            }
        }

        throw FirecrackerError.timeout(
            "Connecting to guest vsock port \(port) via \(udsPath): \(lastError?.localizedDescription ?? "no attempts")"
        )
    }

    /// Sends data to the guest, looping over short writes.
    public func write(_ data: Data) async throws {
        guard let fd else { throw FirecrackerError.notConnected }
        try await VsockSocketIO.writeAll(fd: fd, data: data)
    }

    /// Reads up to `maxLength` bytes from the guest; an empty result signals the
    /// guest closed the connection.
    public func read(maxLength: Int = 4096) async throws -> Data {
        guard let fd else { throw FirecrackerError.notConnected }
        return try await VsockSocketIO.read(fd: fd, maxLength: maxLength)
    }

    /// Closes the underlying socket. Idempotent.
    ///
    /// The socket is shut down (`SHUT_RDWR`) before it is closed: a bare
    /// `close(2)` does not wake a thread already parked in a blocking
    /// `read(2)` on the same fd (the in-flight syscall holds its own file
    /// reference), whereas `shutdown(2)` forces that read to return EOF.
    /// Callers therefore may rely on `close()` to unblock a concurrent
    /// ``read(maxLength:)``.
    public func close() {
        if let fd {
            shutdownFD(fd)
            closeFD(fd)
            self.fd = nil
        }
    }

    // MARK: - Handshake

    /// One connection attempt: open the UDS, perform the `CONNECT`/`OK`
    /// handshake, and return the live fd plus the assigned host port. Any
    /// failure closes the fd before throwing so a retry starts clean.
    private static func attempt(udsPath: String, port: UInt32) async throws -> (fd: Int32, hostPort: UInt32) {
        let fd = try openUnixStream(to: udsPath)
        do {
            try await VsockSocketIO.writeAll(fd: fd, data: Data("CONNECT \(port)\n".utf8))
            let hostPort = try await readHandshakeReply(fd: fd)
            return (fd, hostPort)
        } catch {
            closeFD(fd)
            throw error
        }
    }

    /// Reads the single `OK <host_port>\n` reply line and parses the assigned
    /// host port. Firecracker resets the connection (EOF, no line) when the
    /// guest is not listening on the requested port.
    private static func readHandshakeReply(fd: Int32) async throws -> UInt32 {
        var buffer = Data()
        // The reply is one short line; cap the read loop so a misbehaving peer
        // that never sends a newline can't spin forever within an attempt.
        while buffer.count < 64 {
            let chunk = try await VsockSocketIO.read(fd: fd, maxLength: 64)
            if chunk.isEmpty {
                throw FirecrackerError.connectionFailed("vsock handshake closed before reply")
            }
            buffer.append(chunk)
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                // Firecracker replies "OK <assigned_host_port>" on success and
                // resets the socket on failure, so any non-OK line is an error.
                guard line.hasPrefix("OK ") else {
                    throw FirecrackerError.connectionFailed("vsock handshake rejected: \(line)")
                }
                guard let hostPort = UInt32(line.dropFirst(3).trimmingCharacters(in: .whitespaces)) else {
                    throw FirecrackerError.deserializationError("Unparseable vsock handshake reply: \(line)")
                }
                return hostPort
            }
        }
        throw FirecrackerError.connectionFailed("vsock handshake reply exceeded 64 bytes without a newline")
    }

    /// Opens a blocking AF_UNIX stream socket connected to `path`. Shares the
    /// `sun_path` overflow guard used by the API HTTP client.
    private static func openUnixStream(to path: String) throws -> Int32 {
        #if os(Linux)
        let sock = Glibc.socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let sock = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard sock >= 0 else {
            throw FirecrackerError.connectionFailed("Failed to create vsock UDS socket: \(errno)")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        // A jailed VM's vsock UDS can exceed sun_path under a long storage
        // directory; UnixSocketPath falls back to a /proc/self/fd alias.
        let connectable: UnixSocketPath.Connectable
        do {
            connectable = try UnixSocketPath.connectable(path: path, capacity: capacity)
        } catch {
            closeFD(sock)
            throw error
        }
        defer { connectable.closeDirFD() }
        connectable.path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                sunPath.withMemoryRebound(to: CChar.self, capacity: capacity) { dest in
                    strncpy(dest, ptr, capacity - 1)
                    dest[capacity - 1] = 0
                }
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                #if os(Linux)
                Glibc.connect(sock, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                #else
                Darwin.connect(sock, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                #endif
            }
        }
        guard result == 0 else {
            closeFD(sock)
            throw FirecrackerError.connectionFailed("Failed to connect to vsock UDS \(path): \(errno)")
        }
        return sock
    }
}

/// Blocking socket reads/writes for vsock streams, dispatched off the Swift
/// concurrency cooperative pool. Mirrors the `SocketIO` helper the API HTTP
/// client uses (kept separate so neither file has to expose its internals).
private enum VsockSocketIO {
    static func writeAll(fd: Int32, data: Data) async throws {
        try await runBlocking {
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, base + offset, raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw FirecrackerError.connectionFailed("vsock write failed: \(errno)")
                    }
                    if written == 0 {
                        throw FirecrackerError.connectionFailed("vsock write returned 0 (connection closed)")
                    }
                    offset += written
                }
            }
        }
    }

    static func read(fd: Int32, maxLength: Int) async throws -> Data {
        try await runBlocking {
            var buffer = [UInt8](repeating: 0, count: maxLength)
            while true {
                let count = buffer.withUnsafeMutableBytes { ptr in
                    #if os(Linux)
                    Glibc.read(fd, ptr.baseAddress, maxLength)
                    #else
                    Darwin.read(fd, ptr.baseAddress, maxLength)
                    #endif
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw FirecrackerError.connectionFailed("vsock read failed: \(errno)")
                }
                return Data(buffer.prefix(count))
            }
        }
    }

    private static func runBlocking<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
