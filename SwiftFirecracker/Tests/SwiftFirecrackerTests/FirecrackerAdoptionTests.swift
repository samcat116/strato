import Foundation
import Logging
import NIOConcurrencyHelpers
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
    }

    @Test("machine configuration readback uses the effective backend endpoint")
    func machineConfigurationReadback() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = FirecrackerClient.socketPath(socketDirectory: dir, vmId: "grant")
        let server = try FakeFirecrackerAPIServer(socketPath: path, state: "Paused")
        server.start()
        defer { server.stop() }
        let (manager, _) = try await makeClient(socketDirectory: dir).adoptVM(vmId: "grant")
        let config = try await manager.getMachineConfig()
        #expect(config.vcpuCount == 2 && config.memSizeMib == 512)
        #expect(server.requests.withLockedValue { $0 }.contains { $0.hasPrefix("GET /machine-config ") })
    }

    #if os(Linux)
    @Test("restore refuses an unowned spawned process before snapshot load and confirms rollback")
    func restoreValidatesBeforeSnapshotLoad() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let vmId = UUID().uuidString
        let binary = dir + "/fake-firecracker"
        let marker = dir + "/spawned"
        try "#!/bin/sh\necho $$ > '\(marker)'\nexec /bin/sleep 60\n".write(
            toFile: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary)
        let serverTask = Task {
            let deadline = ContinuousClock.now + .seconds(3)
            while !FileManager.default.fileExists(atPath: marker) {
                guard ContinuousClock.now < deadline else {
                    throw FakeFirecrackerAPIServer.FakeServerError.setupFailed("child did not spawn")
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            let server = try FakeFirecrackerAPIServer(
                socketPath: FirecrackerClient.socketPath(socketDirectory: dir, vmId: vmId), state: "Not started")
            server.start()
            return server
        }
        let client = FirecrackerClient(
            firecrackerBinaryPath: binary, socketDirectory: dir, logger: Logger(label: "test"))
        let callbackCalled = NIOLockedValueBox(false)
        do {
            _ = try await client.restoreVM(
                vmId: vmId, jail: nil,
                snapshot: SnapshotLoadConfig(snapshotPath: "/missing", memFilePath: "/missing", resumeVM: true),
                validateCgroup: { _, _ in callbackCalled.withLockedValue { $0 = true } })
            Issue.record("unowned restore was accepted")
        } catch FirecrackerError.processInspectionFailed {
            // Expected: the tracked child has no jailer ownership boundary.
        }
        let server = try await serverTask.value
        defer { server.stop() }
        #expect(!callbackCalled.withLockedValue { $0 })
        #expect(!server.requests.withLockedValue { $0 }.contains(where: { $0.contains("/snapshot/load") }))
        do {
            _ = try await client.waitForVMExit(vmId: vmId, timeout: .zero)
            Issue.record("unacknowledged spawned process was retained")
        } catch FirecrackerError.vmNotFound {
            // Removal is after confirmed process exit in destroyVM.
        }
    }
    #endif

    @Test("failed ownership validation preserves an adopted VM and its API connection")
    func failedValidationPreservesAdoptedVM() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let vmId = UUID().uuidString
        let jail = JailerOptions(jailerBinaryPath: "/missing", chrootBaseDir: dir, uid: 123456, gid: 123456)
        let socket = JailerOptions.socketPath(
            chrootBaseDir: dir, firecrackerBinaryPath: "/usr/bin/firecracker", vmId: vmId)
        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: socket).deletingLastPathComponent().path, withIntermediateDirectories: true)
        let server = try FakeFirecrackerAPIServer(socketPath: socket, state: "Running")
        server.start()
        defer { server.stop() }
        let client = makeClient(socketDirectory: dir)
        _ = try await client.adoptVM(vmId: vmId, jail: jail)
        await #expect(throws: FirecrackerError.self) {
            try await client.validateOwnedCgroup(vmId: vmId) { _, _ in
                Issue.record("unproven process reached validation")
            }
        }
        let (_, info) = try await client.adoptVM(vmId: vmId, jail: jail)
        #expect(info.state == .running)
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
    }

    @Test("exit confirmation fails closed without a tracked process identity")
    func untrackedAdoptionCannotClaimExit() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let vmId = "untracked"
        let socketPath = FirecrackerClient.socketPath(socketDirectory: dir, vmId: vmId)

        let server = try FakeFirecrackerAPIServer(socketPath: socketPath, state: "Running")
        server.start()
        defer { server.stop() }

        let client = makeClient(socketDirectory: dir)
        _ = try await client.adoptVM(vmId: vmId)

        let confirmed = try await client.waitForVMExit(vmId: vmId, timeout: .milliseconds(0))
        #expect(!confirmed)
    }

    #if !os(Linux)
    @Test("fallback cleanup retries a retained tracked teardown")
    func fallbackCleanupRetriesTrackedTeardown() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let vmId = "retry-tracked"
        let socketPath = FirecrackerClient.socketPath(socketDirectory: dir, vmId: vmId)

        let server = try FakeFirecrackerAPIServer(socketPath: socketPath, state: "Running")
        server.start()
        defer { server.stop() }

        let client = makeClient(socketDirectory: dir)
        _ = try await client.adoptVM(vmId: vmId)

        // Non-Linux process inspection fails after the manager disconnects,
        // leaving the tracked entry in place exactly like a transient Linux
        // inspection or signal failure would.
        do {
            try await client.destroyVM(vmId: vmId)
            Issue.record("expected tracked teardown to require Linux process inspection")
        } catch FirecrackerError.processInspectionFailed {
        } catch {
            Issue.record("unexpected first teardown error: \(error)")
        }

        do {
            try await client.destroyUntrackedVM(vmId: vmId)
            Issue.record("expected retry to reach the unavailable process inspection")
        } catch FirecrackerError.processInspectionFailed {
            // The fallback retried the retained tracked teardown.
        } catch FirecrackerError.vmAlreadyRunning {
            Issue.record("fallback rejected the retained tracked teardown instead of retrying it")
        } catch {
            Issue.record("unexpected fallback teardown error: \(error)")
        }
    }
    #endif
}

/// Minimal stand-in for Firecracker's HTTP-over-Unix-socket API. Serves a fixed
/// `GET /` instance-info response so adoption can be tested without the binary.
private final class FakeFirecrackerAPIServer: Sendable {
    private let socketPath: String
    private let responseBody: Data
    private let listenFD: Int32
    private let queue = DispatchQueue(label: "fake-firecracker-api")
    private let stopped = NIOLockedValueBox(false)
    let requests = NIOLockedValueBox<[String]>([])

    init(socketPath: String, state: String) throws {
        self.socketPath = socketPath
        let json = """
            {"state":"\(state)","vmm_version":"test"}
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
        stopped.withLockedValue { $0 = true }
        // Closing the listen socket unblocks accept().
        close(listenFD)
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func isStopped() -> Bool {
        stopped.withLockedValue { $0 }
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
                let headers = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                requests.withLockedValue { $0.append(String(headers.split(separator: "\n").first ?? "")) }
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                writeResponse(fd, machineConfig: headers.hasPrefix("GET /machine-config "))
            }
        }
    }

    private func writeResponse(_ fd: Int32, machineConfig: Bool) {
        let responseBody = machineConfig ? Data(#"{"vcpu_count":2,"mem_size_mib":512}"#.utf8) : self.responseBody
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
