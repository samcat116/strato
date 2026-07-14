import Foundation
import Logging
import Testing

#if os(Linux)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

@testable import SwiftFirecracker

/// Coverage for the host side of the Firecracker vsock channel
/// (``VsockConnection``): the `CONNECT <port>` / `OK <host_port>` handshake and
/// its retry-until-timeout behaviour. A `FakeVsockUDSServer` stands in for
/// Firecracker's vsock multiplexing UDS so the handshake can be exercised on any
/// platform with AF_UNIX (real guest traffic remains Linux-only).
@Suite("Vsock host connection")
struct VsockConnectionTests {
    /// A short socket directory under /tmp — the AF_UNIX `sun_path` limit
    /// (104 bytes on macOS) rules out the default long temp directory.
    private func makeSocketDir() throws -> String {
        let dir = "/tmp/fc-vsock-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("connect performs the handshake and parses the assigned host port")
    func connectHandshakeSucceeds() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let udsPath = "\(dir)/vm.vsock"

        let server = try FakeVsockUDSServer(socketPath: udsPath, behavior: .accept(hostPort: 1024))
        server.start()
        defer { server.stop() }

        let conn = try await VsockConnection.connect(
            udsPath: udsPath, port: 5000, timeout: 5.0, logger: Logger(label: "test"))
        defer { Task { await conn.close() } }

        #expect(conn.assignedHostPort == 1024)
        // The server records the CONNECT line it received.
        #expect(server.lastConnectPort() == 5000)
    }

    @Test("connect echoes data over the established stream")
    func connectStreamsData() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let udsPath = "\(dir)/vm.vsock"

        let server = try FakeVsockUDSServer(socketPath: udsPath, behavior: .echo(hostPort: 2048))
        server.start()
        defer { server.stop() }

        let conn = try await VsockConnection.connect(
            udsPath: udsPath, port: 52, timeout: 5.0, logger: Logger(label: "test"))
        defer { Task { await conn.close() } }

        try await conn.write(Data("ping".utf8))
        let echoed = try await conn.read(maxLength: 16)
        #expect(String(decoding: echoed, as: UTF8.self) == "ping")
    }

    @Test("connect throws when the guest rejects the port")
    func connectRejectedPortThrows() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let udsPath = "\(dir)/vm.vsock"

        let server = try FakeVsockUDSServer(socketPath: udsPath, behavior: .reject)
        server.start()
        defer { server.stop() }

        // A rejecting server never yields an OK line, so connect() exhausts its
        // short budget and times out (wrapping the handshake failure).
        await #expect(throws: FirecrackerError.self) {
            _ = try await VsockConnection.connect(
                udsPath: udsPath, port: 5000, timeout: 0.5, retryInterval: 0.05,
                logger: Logger(label: "test"))
        }
    }

    @Test("close() unblocks a read parked on the connection")
    func closeUnblocksParkedRead() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let udsPath = "\(dir)/vm.vsock"

        // .echo keeps the connection open after the handshake (the server
        // blocks reading the client's next payload), so a client read with no
        // inbound data parks in the blocking read(2).
        let server = try FakeVsockUDSServer(socketPath: udsPath, behavior: .echo(hostPort: 4096))
        server.start()
        defer { server.stop() }

        let conn = try await VsockConnection.connect(
            udsPath: udsPath, port: 77, timeout: 5.0, logger: Logger(label: "test"))

        let readTask = Task { try await conn.read(maxLength: 16) }
        // Give the read time to actually park in read(2) before closing.
        try await Task.sleep(nanoseconds: 200_000_000)
        await conn.close()

        // close() must wake the parked read (shutdown ⇒ EOF ⇒ empty Data). A
        // bare close(2) would leave it parked forever, so race a generous
        // deadline and fail rather than hang if the wakeup regresses.
        enum Outcome: Sendable { case read(Data?), timedOut }
        let outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask { .read(try? await readTask.value) }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return .timedOut
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
        guard case .read(let data) = outcome else {
            Issue.record("read stayed parked after close(); shutdown-before-close regressed")
            return
        }
        // EOF (empty Data) is the expected wakeup; an error is also an
        // acceptable unblock if the close raced the read's entry.
        let unblockedWithEOF = data?.isEmpty ?? true
        #expect(unblockedWithEOF)
    }

    @Test("connect retries a missing UDS until it appears, then times out")
    func connectMissingUDSTimesOut() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let udsPath = "\(dir)/never.vsock"

        // No server is ever started: connect() must retry and ultimately throw
        // a timeout rather than hang or crash on the missing socket.
        await #expect(throws: FirecrackerError.self) {
            _ = try await VsockConnection.connect(
                udsPath: udsPath, port: 5000, timeout: 0.4, retryInterval: 0.05,
                logger: Logger(label: "test"))
        }
    }
}

/// Minimal stand-in for Firecracker's vsock multiplexing UDS. Accepts a
/// connection, reads the `CONNECT <port>` line, and responds per `behavior`.
private final class FakeVsockUDSServer: @unchecked Sendable {
    enum Behavior {
        /// Reply `OK <hostPort>` and then ignore further traffic.
        case accept(hostPort: UInt32)
        /// Reply `OK <hostPort>` and echo back everything the client writes.
        case echo(hostPort: UInt32)
        /// Close the connection without replying (guest not listening).
        case reject
    }

    private let socketPath: String
    private let behavior: Behavior
    private let listenFD: Int32
    private let queue = DispatchQueue(label: "fake-vsock-uds")
    private let lock = NSLock()
    private var stopped = false
    private var connectPort: UInt32?

    init(socketPath: String, behavior: Behavior) throws {
        self.socketPath = socketPath
        self.behavior = behavior

        if FileManager.default.fileExists(atPath: socketPath) {
            try FileManager.default.removeItem(atPath: socketPath)
        }

        #if os(Linux)
        let fd = Glibc.socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw FakeServerError.setupFailed("socket() failed: \(errno)") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < capacity else {
            close(fd)
            throw FakeServerError.setupFailed("socket path too long")
        }
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                sunPath.withMemoryRebound(to: CChar.self, capacity: capacity) { dest in
                    strncpy(dest, ptr, capacity - 1)
                    dest[capacity - 1] = 0
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw FakeServerError.setupFailed("bind() failed: \(errno)")
        }
        guard listen(fd, 4) == 0 else {
            close(fd)
            throw FakeServerError.setupFailed("listen() failed: \(errno)")
        }
        self.listenFD = fd
    }

    func start() {
        queue.async { [self] in
            while !isStopped() {
                let conn = accept(listenFD, nil, nil)
                if conn < 0 { break }  // listen socket closed by stop()
                serveConnection(conn)
                close(conn)
            }
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        close(listenFD)
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    func lastConnectPort() -> UInt32? {
        lock.lock()
        defer { lock.unlock() }
        return connectPort
    }

    private func isStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func serveConnection(_ fd: Int32) {
        // Read the CONNECT <port>\n handshake line.
        var buffer = Data()
        while !buffer.contains(0x0A) {
            var chunk = [UInt8](repeating: 0, count: 64)
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, 64) }
            if n <= 0 { return }
            buffer.append(contentsOf: chunk.prefix(n))
        }
        let line = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("CONNECT ") {
            lock.lock()
            connectPort = UInt32(line.dropFirst("CONNECT ".count).trimmingCharacters(in: .whitespaces))
            lock.unlock()
        }

        switch behavior {
        case .reject:
            return  // close without replying
        case .accept(let hostPort), .echo(let hostPort):
            writeAll(fd, Data("OK \(hostPort)\n".utf8))
            if case .echo = behavior {
                // Echo one round of traffic back to the client.
                var chunk = [UInt8](repeating: 0, count: 64)
                let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, 64) }
                if n > 0 { writeAll(fd, Data(chunk.prefix(n))) }
            }
        }
    }

    private func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let w = write(fd, base + offset, raw.count - offset)
                if w <= 0 { break }
                offset += w
            }
        }
    }

    enum FakeServerError: Error { case setupFailed(String) }
}
