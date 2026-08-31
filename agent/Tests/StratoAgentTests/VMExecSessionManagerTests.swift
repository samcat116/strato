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

    private actor SuspensionGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var isWaiting = false

        func wait() async {
            isWaiting = true
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    private func request(tty: Bool = true) -> SandboxExecRequest {
        SandboxExecRequest(
            command: ["/bin/sh", "-lc", "echo hi"], env: ["A": "B"],
            workingDir: "/tmp", tty: tty, rows: 24, cols: 80)
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
                placement: placement(), sessionId: "s-1", sessionKind: .interactive,
                request: request(),
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
                placement: placement(), sessionId: "s-1", sessionKind: .interactive,
                request: request(),
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
            placement: placement(), sessionId: "s-1", sessionKind: .interactive,
            request: request(),
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
            placement: placement(), sessionId: "s-1", sessionKind: .interactive,
            request: request(),
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
            placement: placement(), sessionId: "s-1", sessionKind: .interactive,
            request: request(),
            placementIsCurrent: { true }, events: { events.append($0) })

        await manager.closeExec(sessionId: "s-1")
        #expect(await connection.isClosed)
        #expect(events.all == [.started])
        await #expect(throws: VMExecBridgeError.self) {
            try await manager.sendExecInput(sessionId: "s-1", data: Data(), eof: true)
        }
    }

    @Test("control-plane disconnect preserves recorded commands and closes interactive exec")
    func controlPlaneDisconnectPreservesRecordedCommand() async throws {
        let recordedConnection = FakeConnection(
            lines: [#"{"type":"exec_started","nonce":"boot-1"}"#])
        let interactiveConnection = FakeConnection(
            lines: [#"{"type":"exec_started","nonce":"boot-1"}"#])
        let manager = VMExecSessionManager(logger: Self.logger) { cid, port, _, _ in
            #expect(port == VMExecSessionManager.guestAgentPort)
            switch cid {
            case 42: return recordedConnection
            case 43: return interactiveConnection
            default:
                Issue.record("unexpected vsock CID: \(cid)")
                return FakeConnection()
            }
        }

        // Both sessions are non-TTY: interactivity is not a durability marker.
        try await manager.startExec(
            placement: placement("vm-recorded", cid: 42), sessionId: "recorded-command",
            sessionKind: .recorded, request: request(tty: false),
            placementIsCurrent: { true }, events: { _ in })
        try await manager.startExec(
            placement: placement("vm-interactive", cid: 43), sessionId: "interactive-exec",
            sessionKind: .interactive, request: request(tty: false),
            placementIsCurrent: { true }, events: { _ in })

        await manager.closeInteractive(reason: "control plane disconnected")

        #expect(await interactiveConnection.isClosed)
        let recordedWasClosed = await recordedConnection.isClosed
        #expect(
            recordedWasClosed == false,
            "a recorded command must keep its guest channel across a control-plane socket blip")

        await manager.closeExec(sessionId: "recorded-command")
    }

    @Test("recorded commands retain one bounded authoritative terminal snapshot")
    func recordedCommandRetainsTerminalSnapshotUntilAcknowledged() async throws {
        let connection = FakeConnection(lines: [#"{"type":"exec_started","nonce":"boot-1"}"#])
        let manager = manager(connection: connection)
        let events = Recorder<SandboxExecEvent>()

        try await manager.startExec(
            placement: placement(), sessionId: "recorded-command", sessionKind: .recorded,
            request: request(tty: false), placementIsCurrent: { true },
            events: { events.append($0) })

        var stdoutBytesRemaining = VMExecSessionManager.recordedOutputLimitBytes - 3
        let stderr = Data(repeating: 66, count: 6)
        while stdoutBytesRemaining > 0 {
            let chunk = Data(
                repeating: 65,
                count: min(stdoutBytesRemaining, GuestControlProtocol.Limits.maxPayloadBytes))
            await connection.enqueue(
                #"{"type":"output","nonce":"boot-1","stream":"stdout","data":"\#(chunk.base64EncodedString())"}"#)
            stdoutBytesRemaining -= chunk.count
        }
        await connection.enqueue(
            #"{"type":"output","nonce":"boot-1","stream":"stderr","data":"\#(stderr.base64EncodedString())"}"#)
        await connection.enqueue(
            #"{"type":"exec_exit","nonce":"boot-1","exit_code":19}"#)

        #expect(
            await eventually {
                await manager.recordedSessionSnapshot(sessionId: "recorded-command")?.status
                    == .exited
            })
        let snapshot = try #require(
            await manager.recordedSessionSnapshot(sessionId: "recorded-command"))
        #expect(snapshot.stdout.count == VMExecSessionManager.recordedOutputLimitBytes - 3)
        #expect(snapshot.stderr == Data(repeating: 66, count: 3))
        #expect(snapshot.exitCode == 19)
        #expect(snapshot.reason == nil)
        #expect(snapshot.truncated)
        #expect(events.all == [.started, .exited(code: 19)])

        let writes = try await connection.writes.map { data -> [String: Any] in
            try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(writes.map { $0["type"] as? String } == ["exec", "stdin_eof"])

        #expect(await manager.acknowledgeRecordedSession(sessionId: "recorded-command"))
        #expect(await manager.recordedSessionSnapshot(sessionId: "recorded-command") == nil)
        #expect(!(await manager.acknowledgeRecordedSession(sessionId: "recorded-command")))
    }

    @Test("closing a recorded command retains partial output as truncated")
    func recordedCloseRetainsPartialCapture() async throws {
        let connection = FakeConnection(lines: [#"{"type":"exec_started","nonce":"boot-1"}"#])
        let manager = manager(connection: connection)
        let events = Recorder<SandboxExecEvent>()
        try await manager.startExec(
            placement: placement(), sessionId: "recorded-command", sessionKind: .recorded,
            request: request(tty: false), placementIsCurrent: { true },
            events: { events.append($0) })

        await connection.enqueue(
            #"{"type":"output","nonce":"boot-1","stream":"stdout","data":"cGFydGlhbA=="}"#)
        #expect(
            await eventually {
                await manager.recordedSessionSnapshot(sessionId: "recorded-command")?.stdout
                    == Data("partial".utf8)
            })
        await manager.closeExec(sessionId: "recorded-command", reason: "command deadline passed")

        let snapshot = try #require(
            await manager.recordedSessionSnapshot(sessionId: "recorded-command"))
        #expect(snapshot.status == .closed)
        #expect(snapshot.stdout == Data("partial".utf8))
        #expect(snapshot.exitCode == nil)
        #expect(snapshot.reason == "command deadline passed")
        #expect(snapshot.truncated)
        #expect(events.all == [.started, .closed(reason: "command deadline passed")])
        #expect(await connection.isClosed)
    }

    @Test("an interactive disconnect does not invalidate a recorded handshake")
    func disconnectDuringRecordedHandshake() async throws {
        let connection = FakeConnection()
        let manager = manager(connection: connection)
        let start = Task {
            try await manager.startExec(
                placement: placement(), sessionId: "recorded-command", sessionKind: .recorded,
                request: request(tty: false), placementIsCurrent: { true }, events: { _ in })
        }

        #expect(await eventually { await connection.writes.count == 1 })
        await manager.closeInteractive(reason: "control plane disconnected")
        await connection.enqueue(#"{"type":"exec_started","nonce":"boot-1"}"#)
        try await start.value

        #expect(!(await connection.isClosed))
        #expect(
            await manager.recordedSessionSnapshot(sessionId: "recorded-command")?.status
                == .running)
        #expect(!(await manager.acknowledgeRecordedSession(sessionId: "recorded-command")))
        await manager.closeExec(sessionId: "recorded-command")
    }

    @Test("an interactive start stays quiesced after a control-plane disconnect")
    func interactiveStartWhileDisconnectedIsRejected() async {
        let connection = FakeConnection(lines: [#"{"type":"exec_started","nonce":"boot-1"}"#])
        let manager = manager(connection: connection)

        await manager.closeInteractive(reason: "control plane disconnected")

        let error = await #expect(throws: VMExecBridgeError.self) {
            try await manager.startExec(
                placement: placement(), sessionId: "late-interactive",
                sessionKind: .interactive, request: request(),
                placementIsCurrent: { true }, events: { _ in })
        }
        guard case .interactiveSessionsQuiesced = error else {
            Issue.record("expected the disconnected-session gate")
            return
        }
        await manager.closeAll(reason: "test cleanup")
    }

    @Test("a disconnect during final placement validation cannot resurrect an interactive exec")
    func disconnectDuringFinalPlacementValidation() async {
        let connection = FakeConnection(lines: [#"{"type":"exec_started","nonce":"boot-1"}"#])
        let manager = manager(connection: connection)
        let gate = SuspensionGate()
        let checks = Mutex(0)
        let start = Task {
            try await manager.startExec(
                placement: placement(), sessionId: "racing-interactive",
                sessionKind: .interactive, request: request(),
                placementIsCurrent: {
                    let check = checks.withLock {
                        $0 += 1
                        return $0
                    }
                    if check == 2 { await gate.wait() }
                    return true
                }, events: { _ in })
        }

        #expect(await eventually { await gate.isWaiting })
        await manager.closeInteractive(reason: "control plane disconnected")
        await gate.release()

        _ = await #expect(throws: VMExecBridgeError.self) {
            try await start.value
        }
        #expect(await connection.isClosed)
    }

    @Test("a disconnect while opening vsock cannot send an interactive exec afterward")
    func disconnectDuringConnectCannotSendExec() async {
        let connection = FakeConnection(lines: [#"{"type":"exec_started","nonce":"boot-1"}"#])
        let gate = SuspensionGate()
        let manager = VMExecSessionManager(logger: Self.logger) { _, _, _, _ in
            await gate.wait()
            return connection
        }
        let start = Task {
            try await manager.startExec(
                placement: placement(), sessionId: "racing-interactive",
                sessionKind: .interactive, request: request(),
                placementIsCurrent: { true }, events: { _ in })
        }

        #expect(await eventually { await gate.isWaiting })
        await manager.closeInteractive(reason: "control plane disconnected")
        await gate.release()

        _ = await #expect(throws: VMExecBridgeError.self) {
            try await start.value
        }
        #expect(await connection.writes.isEmpty)
        #expect(await connection.isClosed)
    }

    @Test("a recorded close always retains a replayable reason")
    func recordedCloseNormalizesMissingReason() async throws {
        let connection = FakeConnection(lines: [#"{"type":"exec_started","nonce":"boot-1"}"#])
        let manager = manager(connection: connection)
        try await manager.startExec(
            placement: placement(), sessionId: "recorded-command", sessionKind: .recorded,
            request: request(tty: false), placementIsCurrent: { true }, events: { _ in })

        await manager.closeExec(sessionId: "recorded-command")

        let snapshot = try #require(
            await manager.recordedSessionSnapshot(sessionId: "recorded-command"))
        #expect(snapshot.status == .closed)
        #expect(snapshot.reason == "guest command session closed without an exit code")
        #expect(snapshot.truncated)
    }

    @Test("agent shutdown rejects a recorded start queued after teardown")
    func recordedStartAfterShutdownIsRejected() async {
        let connection = FakeConnection(lines: [#"{"type":"exec_started","nonce":"boot-1"}"#])
        let manager = manager(connection: connection)

        await manager.closeAll(reason: "agent stopping")

        let error = await #expect(throws: VMExecBridgeError.self) {
            try await manager.startExec(
                placement: placement(), sessionId: "late-recorded", sessionKind: .recorded,
                request: request(tty: false), placementIsCurrent: { true }, events: { _ in })
        }
        #expect(error?.localizedDescription.contains("stopping") == true)
        #expect(await connection.writes.isEmpty)
    }

    @Test("a recorded failure before guest start remains retained until acknowledged")
    func recordedPreflightFailureIsRetained() async throws {
        let manager = manager(connection: FakeConnection())

        await manager.retainRecordedStartFailure(
            sessionId: "recorded-command", reason: "VM is no longer placed here")

        let snapshot = try #require(
            await manager.recordedSessionSnapshot(sessionId: "recorded-command"))
        #expect(snapshot.status == .closed)
        #expect(snapshot.reason == "VM is no longer placed here")
        #expect(snapshot.stdout.isEmpty)
        #expect(snapshot.stderr.isEmpty)
        #expect(snapshot.truncated)
        #expect(await manager.acknowledgeRecordedSession(sessionId: "recorded-command"))
    }

    @Test("terminal replay selection rotates past an unacknowledged result")
    func terminalReplaySelectionIsFair() async throws {
        let manager = manager(connection: FakeConnection())
        await manager.retainRecordedStartFailure(sessionId: "a", reason: "first")
        await manager.retainRecordedStartFailure(sessionId: "b", reason: "second")

        let first = try #require(await manager.recordedTerminalSnapshot(after: nil))
        #expect(first.sessionId == "a")
        let second = try #require(
            await manager.recordedTerminalSnapshot(after: first.sessionId))
        #expect(second.sessionId == "b")
        #expect(
            await manager.recordedTerminalSnapshot(after: second.sessionId)?.sessionId == "a")

        #expect(await manager.acknowledgeRecordedSession(sessionId: "a"))
        #expect(
            await manager.recordedTerminalSnapshot(after: second.sessionId)?.sessionId == "b")
    }

    @Test("placement is rechecked after the guest handshake")
    func placementRace() async {
        let connection = FakeConnection(lines: [#"{"type":"exec_started","nonce":"boot-1"}"#])
        let checks = Mutex(0)
        let manager = manager(connection: connection)
        let error = await #expect(throws: VMExecBridgeError.self) {
            try await manager.startExec(
                placement: placement(), sessionId: "s-1", sessionKind: .interactive,
                request: request(),
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
