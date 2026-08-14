import Foundation
import Logging
import StratoShared
import Synchronization
import Testing

@testable import StratoAgentCore

@Suite("VM Exec Session Manager")
struct VMExecSessionManagerTests {
    private static let logger = Logger(label: "vm-exec-session-manager-tests")

    private final class Recorder<T: Sendable>: Sendable {
        private let items = Mutex<[T]>([])
        func append(_ item: T) { items.withLock { $0.append(item) } }
        var all: [T] { items.withLock { $0 } }
    }

    private actor FakeConnection: GuestLineConnection {
        private var lines: [String?]
        private var waiters: [CheckedContinuation<String?, any Error>] = []
        private(set) var writes: [Data] = []
        private(set) var isClosed = false

        init(lines: [String?] = []) { self.lines = lines }

        func write(_ data: Data) async throws {
            guard !isClosed else { throw HostVsockConnectionError.notConnected }
            writes.append(data)
        }

        func nextLine(timeout: TimeInterval?) async throws -> String? {
            if !lines.isEmpty { return lines.removeFirst() }
            if isClosed { return nil }
            return try await withCheckedThrowingContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func enqueue(_ line: String?) {
            if waiters.isEmpty {
                lines.append(line)
            } else {
                waiters.removeFirst().resume(returning: line)
            }
        }

        func close() async {
            guard !isClosed else { return }
            isClosed = true
            let current = waiters
            waiters.removeAll()
            current.forEach { $0.resume(returning: nil) }
        }
    }

    private func request() -> SandboxExecRequest {
        SandboxExecRequest(
            command: ["/bin/sh", "-lc", "echo hi"], env: ["A": "B"],
            workingDir: "/tmp", tty: true, rows: 24, cols: 80)
    }

    private func placement(_ vmId: String = "vm-1", cid: UInt32 = 42) -> VMGuestExecPlacement {
        VMGuestExecPlacement(vmId: vmId, vsockCID: cid)
    }

    private func manager(connection: FakeConnection) -> VMExecSessionManager {
        VMExecSessionManager(logger: Self.logger) { cid, port, _, _ in
            #expect(cid == 42)
            #expect(port == VMExecSessionManager.guestAgentPort)
            return connection
        }
    }

    private func eventually(
        within deadline: Duration = .seconds(2),
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    @Test("placement resolution refuses unknown and guest-agent-free VMs distinctly")
    func placementResolution() throws {
        let absent = #expect(throws: VMExecBridgeError.self) {
            try VMGuestExecPlacement.resolve(vmId: "vm-1", managedVMs: [:])
        }
        #expect(absent?.localizedDescription.contains("not placed on this agent") == true)

        let withoutAgent = VMManifestEntry(
            hypervisorType: .qemu,
            spec: VMSpec(
                cpus: 1, memoryBytes: 512 * 1024 * 1024,
                boot: .disk(firmware: nil), guestAgentEnabled: false))
        let noAgent = #expect(throws: VMExecBridgeError.self) {
            try VMGuestExecPlacement.resolve(
                vmId: "vm-1", managedVMs: ["vm-1": withoutAgent])
        }
        #expect(noAgent?.localizedDescription == "VM vm-1 has no guest agent")

        let enabled = VMManifestEntry(
            hypervisorType: .qemu,
            spec: VMSpec(
                cpus: 1, memoryBytes: 512 * 1024 * 1024,
                boot: .disk(firmware: nil), guestAgentEnabled: true),
            vsockCID: 42)
        #expect(
            try VMGuestExecPlacement.resolve(
                vmId: "vm-1", managedVMs: ["vm-1": enabled]) == placement())
    }

    @Test("placement is checked before any vsock connection is opened")
    func placementCheckedBeforeConnect() async {
        let connects = Mutex(0)
        let manager = VMExecSessionManager(logger: Self.logger) { _, _, _, _ in
            connects.withLock { $0 += 1 }
            return FakeConnection()
        }
        let error = await #expect(throws: VMExecBridgeError.self) {
            try await manager.startExec(
                placement: placement(), sessionId: "s-1", request: request(),
                placementIsCurrent: { false }, events: { _ in })
        }
        #expect(error?.localizedDescription.contains("not placed on this agent") == true)
        #expect(connects.withLock { $0 } == 0)
    }

    @Test("connection failure is reported as guest agent not responding")
    func unresponsiveGuestAgentIsDistinct() async {
        struct Refused: Error {}
        let manager = VMExecSessionManager(logger: Self.logger) { _, _, _, _ in throw Refused() }
        let error = await #expect(throws: VMExecBridgeError.self) {
            try await manager.startExec(
                placement: placement(), sessionId: "s-1", request: request(),
                placementIsCurrent: { true }, events: { _ in })
        }
        #expect(error?.localizedDescription.contains("guest agent not responding") == true)
        #expect(error?.localizedDescription != "VM vm-1 has no guest agent")
    }

    @Test("exec, stdin, EOF, resize, output, and exit bridge in order")
    func fullBridge() async throws {
        let connection = FakeConnection(lines: [#"{"type":"exec_started","nonce":"boot-1"}"#])
        let manager = manager(connection: connection)
        let events = Recorder<SandboxExecEvent>()

        try await manager.startExec(
            placement: placement(), sessionId: "s-1", request: request(),
            placementIsCurrent: { true }, events: { events.append($0) })
        #expect(events.all == [.started])

        try await manager.sendExecInput(
            sessionId: "s-1", data: Data("hello\n".utf8), eof: true)
        try await manager.resizeExec(sessionId: "s-1", rows: 50, cols: 120)

        let writes = await connection.writes
        #expect(writes.count == 4)
        let objects = try writes.map { data -> [String: Any] in
            try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(objects.map { $0["type"] as? String } == ["exec", "stdin", "stdin_eof", "resize"])
        #expect(objects[1]["data"] as? String == Data("hello\n".utf8).base64EncodedString())
        #expect(objects[3]["rows"] as? Int == 50)
        #expect(objects[3]["cols"] as? Int == 120)

        await connection.enqueue(#"{"type":"output","nonce":"boot-1","stream":"stdout","data":"aGkK"}"#)
        await connection.enqueue(#"{"type":"exec_exit","nonce":"boot-1","exit_code":0}"#)
        #expect(await eventually { events.all.last == .exited(code: 0) })
        #expect(
            events.all == [
                .started, .output(stream: "stdout", data: Data("hi\n".utf8)), .exited(code: 0),
            ])
        #expect(await connection.isClosed)
    }

    @Test("a response from another boot nonce terminates the session")
    func nonceMismatch() async throws {
        let connection = FakeConnection(lines: [#"{"type":"exec_started","nonce":"boot-1"}"#])
        let manager = manager(connection: connection)
        let events = Recorder<SandboxExecEvent>()
        try await manager.startExec(
            placement: placement(), sessionId: "s-1", request: request(),
            placementIsCurrent: { true }, events: { events.append($0) })

        await connection.enqueue(
            #"{"type":"output","nonce":"boot-2","stream":"stdout","data":"aGk="}"#)
        #expect(
            await eventually {
                guard case .closed = events.all.last else { return false }
                return true
            })
        guard case .closed(let reason) = events.all.last else {
            Issue.record("expected nonce mismatch to close the session")
            return
        }
        #expect(reason?.contains("expected boot-1, got boot-2") == true)
        #expect(await connection.isClosed)
    }

    @Test("closing before exec_exit closes the vsock channel without a second terminal event")
    func earlyClose() async throws {
        let connection = FakeConnection(lines: [#"{"type":"exec_started","nonce":"boot-1"}"#])
        let manager = manager(connection: connection)
        let events = Recorder<SandboxExecEvent>()
        try await manager.startExec(
            placement: placement(), sessionId: "s-1", request: request(),
            placementIsCurrent: { true }, events: { events.append($0) })

        await manager.closeExec(sessionId: "s-1")
        #expect(await connection.isClosed)
        #expect(events.all == [.started])
        await #expect(throws: VMExecBridgeError.self) {
            try await manager.sendExecInput(sessionId: "s-1", data: Data(), eof: true)
        }
    }

    @Test("placement is rechecked after the guest handshake")
    func placementRace() async {
        let connection = FakeConnection(lines: [#"{"type":"exec_started","nonce":"boot-1"}"#])
        let checks = Mutex(0)
        let manager = manager(connection: connection)
        let error = await #expect(throws: VMExecBridgeError.self) {
            try await manager.startExec(
                placement: placement(), sessionId: "s-1", request: request(),
                placementIsCurrent: {
                    checks.withLock {
                        $0 += 1
                        return $0 == 1
                    }
                }, events: { _ in })
        }
        #expect(error?.localizedDescription.contains("not placed on this agent") == true)
        #expect(checks.withLock { $0 } == 2)
        #expect(await connection.isClosed)
    }
}
