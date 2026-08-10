import Foundation
import Logging
import NIOPosix
import Testing

@testable import SwiftFirecracker

#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Concurrency guarantees of the API socket client.
///
/// These exercise the failure that motivated moving the transport to NIO: the
/// previous implementation released its actor at each `await`, so two
/// overlapping `request(...)` calls could both write and then race to read the
/// same socket. A response could be delivered to the wrong caller, or discarded
/// entirely when one read consumed both responses and kept only the first.
@Suite("API socket concurrency")
struct HTTPConcurrencyTests {

    /// Deliberately `/tmp` rather than `FileManager.default.temporaryDirectory`:
    /// these paths are *bound* as Unix domain sockets, and macOS's per-user
    /// temporary directory is a ~50-character `/var/folders/...` path that eats
    /// half of `sun_path`'s 104-byte budget before the socket name is appended.
    /// Short paths keep the fixtures clear of the very limit `UnixSocketPath`
    /// exists to work around.
    private func makeSocketDir() throws -> String {
        let dir = "/tmp/fc-http-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Runs `body` against a connected client and always disconnects before
    /// returning. A `defer { Task { await client.disconnect() } }` would be
    /// fire-and-forget — the channel could outlive the test and the fake server
    /// it is talking to.
    private func withClient<T>(
        socketPath: String,
        requestTimeout: TimeInterval = UnixSocketHTTPClient.defaultRequestTimeout,
        _ body: (UnixSocketHTTPClient) async throws -> T
    ) async throws -> T {
        let client = UnixSocketHTTPClient(
            socketPath: socketPath, logger: Logger(label: "test"), requestTimeout: requestTimeout)
        try await client.connect()
        do {
            let result = try await body(client)
            await client.disconnect()
            return result
        } catch {
            await client.disconnect()
            throw error
        }
    }

    @Test("concurrent requests each receive their own response")
    func concurrentRequestsArePairedCorrectly() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let socketPath = "\(dir)/api.sock"

        // Echoes each request's path back in the body, so a crossed response is
        // detectable rather than silently plausible.
        let server = try EchoingAPIServer(socketPath: socketPath)
        server.start()
        defer { server.stop() }

        let requestCount = 25
        let results = try await withClient(socketPath: socketPath) { client in
            try await withThrowingTaskGroup(of: (Int, String).self) { group in
                for i in 0..<requestCount {
                    group.addTask {
                        let response = try await client.request(method: .GET, path: "/probe/\(i)")
                        let body = response.body.map { String(decoding: $0, as: UTF8.self) } ?? ""
                        return (i, body)
                    }
                }
                var collected: [(Int, String)] = []
                for try await result in group {
                    collected.append(result)
                }
                return collected
            }
        }

        #expect(results.count == requestCount)
        for (index, body) in results {
            #expect(
                body == "{\"path\":\"/probe/\(index)\"}",
                "request \(index) received another request's response: \(body)")
        }
    }

    @Test("a response larger than one read chunk is not truncated")
    func largeResponseIsComplete() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let socketPath = "\(dir)/api.sock"

        // Comfortably past the 4096-byte chunk the old hand-rolled reader used.
        let payloadSize = 200_000
        let server = try EchoingAPIServer(socketPath: socketPath, padBodyTo: payloadSize)
        server.start()
        defer { server.stop() }

        let response = try await withClient(socketPath: socketPath) { client in
            try await client.request(method: .GET, path: "/big")
        }
        #expect(response.statusCode == 200)
        #expect(response.body?.count == payloadSize)
    }

    @Test("requests after the peer disappears fail instead of hanging")
    func requestAfterPeerCloseFails() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let socketPath = "\(dir)/api.sock"

        let server = try EchoingAPIServer(socketPath: socketPath)
        server.start()

        try await withClient(socketPath: socketPath) { client in
            // One good round trip proves the channel is live, then the VMM
            // vanishes.
            _ = try await client.request(method: .GET, path: "/alive")
            server.stop()

            // Give the close a moment to propagate to the channel.
            try await Task.sleep(for: .milliseconds(200))

            await #expect(throws: FirecrackerError.self) {
                _ = try await client.request(method: .GET, path: "/after-close")
            }
        }
    }

    @Test("a request that is never answered fails on its deadline")
    func unansweredRequestTimesOut() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let socketPath = "\(dir)/api.sock"

        // Accepts the connection and then says nothing at all — the VMM-wedged
        // case that used to park the caller forever and grow the waiter queue.
        let server = try EchoingAPIServer(socketPath: socketPath, silent: true)
        server.start()
        defer { server.stop() }

        // Cleanup goes through `withClient` rather than a `defer` firing an
        // unstructured `Task`: that task can outlive the test body — and the
        // `defer` that removes the socket directory — which is harmless only for
        // as long as teardown touches no filesystem.
        try await withClient(socketPath: socketPath, requestTimeout: 0.5) { client in
            await #expect(throws: FirecrackerError.self) {
                _ = try await client.request(method: .GET, path: "/never-answered")
            }
        }
    }

    /// A timed-out round trip takes the channel down with it — necessarily, since
    /// responses are paired in order. What it must not take down is the client:
    /// before STR-194 the failure latched and nothing anywhere reconnected, so
    /// one unanswered `PATCH /vm` left the agent unable to reach that microVM's
    /// API for the rest of its life, and a still-running sandbox could only be
    /// deleted.
    @Test("a client survives a timed-out request and reconnects for the next one")
    func clientReconnectsAfterATimedOutRequest() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let socketPath = "\(dir)/api.sock"

        // Swallows the first request — the wedged-VMM case — and answers every
        // one after it, which is what a VMM that was merely slow looks like.
        let server = try EchoingAPIServer(socketPath: socketPath, silentRequests: 1)
        server.start()
        defer { server.stop() }

        let response = try await withClient(socketPath: socketPath, requestTimeout: 0.5) { client in
            await #expect(throws: FirecrackerError.self) {
                _ = try await client.request(method: .PATCH, path: "/vm", body: Data("{}".utf8))
            }
            return try await client.request(method: .GET, path: "/after-timeout")
        }

        #expect(response.statusCode == 200)
        #expect(
            response.body.map { String(decoding: $0, as: UTF8.self) } == "{\"path\":\"/after-timeout\"}")
    }

    /// `disconnect()` must win against a redial that is already in flight. It
    /// cannot close a channel that does not exist yet, so the redial has to be
    /// the one that notices the teardown and undoes itself — otherwise the
    /// client comes back up after a deliberate teardown, pointed at a socket
    /// path that by then may belong to a different microVM.
    ///
    /// The window is opened deterministically rather than raced for: the client
    /// runs on a single-threaded loop group, and occupying that one loop parks
    /// the redial inside NIO's channel registration while leaving the actor free
    /// for the `disconnect()` to land. Without the epoch check this ends with a
    /// connected client and the final request *succeeding*, which is why the
    /// server answers after the first swallowed request — a silent server would
    /// make the wrong outcome throw a timeout and look like a pass.
    @Test("a disconnect racing an in-flight redial still leaves the client down")
    func disconnectBeatsAnInFlightRedial() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let socketPath = "\(dir)/api.sock"

        let server = try EchoingAPIServer(socketPath: socketPath, silentRequests: 1)
        server.start()
        defer { server.stop() }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = UnixSocketHTTPClient(
            socketPath: socketPath, logger: Logger(label: "test"), group: group,
            requestTimeout: 0.3)
        try await client.connect()

        // Kills the channel, leaving the client redial-eligible. The loop must
        // be free here — the request's deadline is scheduled on it.
        _ = try? await client.request(method: .GET, path: "/wedged")

        // Occupy the loop so the redial below parks in `withConnectedSocket`.
        group.next().execute { Thread.sleep(forTimeInterval: 1.0) }

        async let redialing: Void = {
            _ = try? await client.request(method: .GET, path: "/racing-the-teardown")
        }()
        // Long enough for the redial to be created and suspended, short enough
        // to stay well inside the loop's occupancy.
        try await Task.sleep(for: .milliseconds(200))
        await client.disconnect()
        await redialing

        var refused = false
        do {
            _ = try await client.request(method: .GET, path: "/after-teardown")
        } catch FirecrackerError.notConnected {
            refused = true
        }
        #expect(refused, "the client reconnected across an explicit disconnect")
        try await group.shutdownGracefully()
    }

    /// The redial is for a channel that died under a request, not for one the
    /// caller deliberately put down: after `disconnect()` the socket path may
    /// already belong to a different microVM.
    @Test("an explicit disconnect is not undone by the next request")
    func explicitDisconnectIsNotUndone() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let socketPath = "\(dir)/api.sock"

        let server = try EchoingAPIServer(socketPath: socketPath)
        server.start()
        defer { server.stop() }

        let client = UnixSocketHTTPClient(socketPath: socketPath, logger: Logger(label: "test"))
        try await client.connect()
        _ = try await client.request(method: .GET, path: "/alive")
        await client.disconnect()

        await #expect(throws: FirecrackerError.self) {
            _ = try await client.request(method: .GET, path: "/after-disconnect")
        }
    }

    /// Firecracker broadcasts Pause before collecting per-vCPU replies, but
    /// keeps its instance state at Running unless every reply arrives. Recovery
    /// must therefore send Resumed even when the manager's mirror is not
    /// Paused; the ordinary `resume()` state guard would reject this call
    /// before it reached the VMM (STR-205).
    @Test("failed-pause recovery bypasses the coarse VM state guard")
    func failedPauseRecoveryAlwaysSendsResume() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let socketPath = "\(dir)/api.sock"

        let server = try EchoingAPIServer(socketPath: socketPath)
        server.start()
        defer { server.stop() }

        let manager = FirecrackerManager(socketPath: socketPath, logger: Logger(label: "test"))
        try await manager.connect()
        // A fresh manager is NotStarted, an even stricter proof than the
        // Running state Firecracker exposes after a partial pause.
        #expect(await manager.vmState == .notStarted)
        try await manager.recoverFromFailedPause()
        #expect(await manager.vmState == .running)
        await manager.disconnect()
    }
}

/// Stand-in Firecracker API server that echoes each request's path, so
/// responses can be matched to the request that produced them. Handles
/// pipelined requests on one connection.
private final class EchoingAPIServer: @unchecked Sendable {
    private let socketPath: String
    private let padBodyTo: Int?
    private let silent: Bool
    private let listenFD: Int32
    private let queue = DispatchQueue(label: "echoing-api-server")
    private let lock = NSLock()
    private var stopped = false
    private var connections: [Int32] = []
    /// How many more requests to swallow before answering normally — a VMM that
    /// is wedged for a while and then comes back, counted across connections so
    /// a client that redials still sees the recovery.
    private var silentRequestsRemaining: Int

    init(socketPath: String, padBodyTo: Int? = nil, silent: Bool = false, silentRequests: Int = 0) throws {
        self.socketPath = socketPath
        self.padBodyTo = padBodyTo
        self.silent = silent
        self.silentRequestsRemaining = silentRequests

        if FileManager.default.fileExists(atPath: socketPath) {
            try FileManager.default.removeItem(atPath: socketPath)
        }

        #if os(Linux)
        let fd = Glibc.socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw ServerError.setupFailed("socket() failed: \(errno)") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < capacity else {
            close(fd)
            throw ServerError.setupFailed("socket path too long")
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
            throw ServerError.setupFailed("bind() failed: \(errno)")
        }
        guard listen(fd, 8) == 0 else {
            close(fd)
            throw ServerError.setupFailed("listen() failed: \(errno)")
        }
        self.listenFD = fd
    }

    func start() {
        queue.async { [self] in
            while !isStopped() {
                let conn = accept(listenFD, nil, nil)
                if conn < 0 { break }
                lock.lock()
                connections.append(conn)
                lock.unlock()
                // Each connection gets its own queue so a pipelined client is
                // never serialised behind the accept loop.
                DispatchQueue.global().async { [self] in
                    serveConnection(conn)
                    close(conn)
                }
            }
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let open = connections
        connections = []
        lock.unlock()
        close(listenFD)
        // `Int32(...)` is load-bearing: Glibc imports SHUT_RDWR as `Int`,
        // Darwin as `Int32`, so the bare constant compiles only on Darwin.
        open.forEach { _ = shutdown($0, Int32(SHUT_RDWR)) }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func isStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// Consumes one of the leading requests that go unanswered.
    private func swallowRequest() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard silentRequestsRemaining > 0 else { return false }
        silentRequestsRemaining -= 1
        return true
    }

    private func serveConnection(_ fd: Int32) {
        var buffer = Data()
        while !isStopped() {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, 4096) }
            if n <= 0 { return }
            buffer.append(contentsOf: chunk.prefix(n))

            while let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer[buffer.startIndex..<range.lowerBound]
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)

                let header = String(decoding: headerData, as: UTF8.self)
                let path =
                    header
                    .components(separatedBy: "\r\n").first?
                    .components(separatedBy: " ").dropFirst().first ?? "/"

                // A small stagger makes the requests genuinely overlap on the
                // wire rather than completing one at a time.
                usleep(useconds_t.random(in: 200...2000))
                // `silent` models a VMM that accepts the connection and then
                // wedges without ever answering.
                if !silent && !swallowRequest() { writeResponse(fd, path: path) }
            }
        }
    }

    private func writeResponse(_ fd: Int32, path: String) {
        var body = Data("{\"path\":\"\(path)\"}".utf8)
        if let padBodyTo {
            body = Data(repeating: UInt8(ascii: "x"), count: padBodyTo)
        }
        let header =
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n"
        var out = Data(header.utf8)
        out.append(body)
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

    enum ServerError: Error { case setupFailed(String) }
}
