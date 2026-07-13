import Foundation
import Logging
import Testing

#if os(Linux)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

@testable import SwiftFirecracker

/// Coverage for orphan re-adoption (issue #433): `FirecrackerClient.adoptVM`
/// reconnects to an already-running Firecracker's API socket without spawning a
/// new process. A `FakeFirecrackerAPIServer` stands in for a live Firecracker so
/// the happy path can be exercised without the (Linux-only) binary.
@Suite("Firecracker adoption")
struct FirecrackerAdoptionTests {
    private func makeClient(socketDirectory: String) -> FirecrackerClient {
        FirecrackerClient(
            firecrackerBinaryPath: "/usr/bin/firecracker",
            socketDirectory: socketDirectory,
            logger: Logger(label: "test")
        )
    }

    /// A short socket directory under /tmp — the AF_UNIX `sun_path` limit
    /// (104 bytes on macOS) rules out the default long temp directory.
    private func makeSocketDir() throws -> String {
        let dir = "/tmp/fc-adopt-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("socketPath is deterministic per VM")
    func socketPathDeterministic() {
        let a = FirecrackerClient.socketPath(socketDirectory: "/run/fc", vmId: "vm-1")
        let b = FirecrackerClient.socketPath(socketDirectory: "/run/fc", vmId: "vm-1")
        #expect(a == b)
        #expect(a == "/run/fc/vm-1.sock")
        #expect(FirecrackerClient.socketPath(socketDirectory: "/run/fc", vmId: "vm-2") == "/run/fc/vm-2.sock")
    }

    @Test("adoptVM throws when the API socket is missing")
    func adoptMissingSocketThrows() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let client = makeClient(socketDirectory: dir)

        await #expect(throws: FirecrackerError.self) {
            _ = try await client.adoptVM(vmId: "ghost")
        }
    }

    @Test("adoptVM throws when the socket is stale (no live Firecracker)")
    func adoptStaleSocketThrows() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // A plain file at the socket path stands in for a socket left behind by
        // a dead process: it exists, but nothing is listening.
        let socketPath = FirecrackerClient.socketPath(socketDirectory: dir, vmId: "stale")
        FileManager.default.createFile(atPath: socketPath, contents: Data())
        let client = makeClient(socketDirectory: dir)

        await #expect(throws: FirecrackerError.self) {
            _ = try await client.adoptVM(vmId: "stale")
        }
    }

    @Test("adoptVM reconnects to a live socket and reports state")
    func adoptLiveSocketReportsState() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let vmId = "adopt-me"
        let socketPath = FirecrackerClient.socketPath(socketDirectory: dir, vmId: vmId)

        let server = try FakeFirecrackerAPIServer(socketPath: socketPath, state: "Running")
        server.start()
        defer { server.stop() }

        let client = makeClient(socketDirectory: dir)
        let (_, info) = try await client.adoptVM(vmId: vmId)

        #expect(info.state == .running)
        #expect(info.id == vmId)
        // The adopted VM is now tracked as running by the client.
        let tracked = await client.listVMs()
        #expect(tracked.contains(vmId))
    }

    @Test("adoptVM is idempotent for an already-managed VM")
    func adoptAlreadyManagedIsIdempotent() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let vmId = "adopt-twice"
        let socketPath = FirecrackerClient.socketPath(socketDirectory: dir, vmId: vmId)

        let server = try FakeFirecrackerAPIServer(socketPath: socketPath, state: "Paused")
        server.start()
        defer { server.stop() }

        let client = makeClient(socketDirectory: dir)
        _ = try await client.adoptVM(vmId: vmId)
        // Second adopt of the same VM returns the existing manager's status
        // rather than opening a fresh connection (replayed-sync race).
        let (_, info) = try await client.adoptVM(vmId: vmId)
        #expect(info.state == .paused)
        let tracked = await client.listVMs()
        #expect(tracked == [vmId])
    }
}

/// Minimal stand-in for Firecracker's HTTP-over-Unix-socket API. Serves a fixed
/// `GET /` instance-info response so adoption can be tested without the binary.
private final class FakeFirecrackerAPIServer: @unchecked Sendable {
    private let socketPath: String
    private let responseBody: Data
    private let listenFD: Int32
    private let queue = DispatchQueue(label: "fake-firecracker-api")
    private var stopped = false
    private let lock = NSLock()

    init(socketPath: String, state: String, appName: String = "Firecracker") throws {
        self.socketPath = socketPath
        // id is filled from the socket file name so the adopt assertions can
        // check it round-trips; keeps the fixture in one place.
        let vmId = (socketPath as NSString).lastPathComponent.replacingOccurrences(of: ".sock", with: "")
        let json = """
            {"app_name":"\(appName)","id":"\(vmId)","state":"\(state)","vmm_version":"test"}
            """
        self.responseBody = Data(json.utf8)

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
        // Closing the listen socket unblocks accept().
        close(listenFD)
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func isStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// Answers each `GET /`-style request on the persistent connection with the
    /// fixed instance-info body until the client closes the connection.
    private func serveConnection(_ fd: Int32) {
        var buffer = Data()
        while !isStopped() {
            var chunk = [UInt8](repeating: 0, count: 1024)
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, 1024) }
            if n <= 0 { return }
            buffer.append(contentsOf: chunk.prefix(n))
            // Respond once we have a full request (headers terminated).
            while let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                writeResponse(fd)
            }
        }
    }

    private func writeResponse(_ fd: Int32) {
        let header =
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(responseBody.count)\r\n\r\n"
        var out = Data(header.utf8)
        out.append(responseBody)
        out.withUnsafeBytes { raw in
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
