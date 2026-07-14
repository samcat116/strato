import Foundation
import StratoShared
import Testing

@Suite("Sandbox exec messages")
struct SandboxExecMessageTests {

    @Test("exec start round-trips through the envelope with every field")
    func execStartRoundTrips() throws {
        let message = SandboxExecStartMessage(
            requestId: Fixtures.requestId,
            timestamp: Fixtures.timestamp,
            sandboxId: Fixtures.uuidA.uuidString,
            sessionId: Fixtures.uuidB.uuidString,
            command: ["/bin/sh", "-c", "echo hi"],
            env: ["TERM": "xterm-256color"],
            workingDir: "/app",
            tty: true,
            rows: 32,
            cols: 120
        )
        let decoded = try throughEnvelope(message)
        #expect(decoded.sandboxId == message.sandboxId)
        #expect(decoded.sessionId == message.sessionId)
        #expect(decoded.command == ["/bin/sh", "-c", "echo hi"])
        #expect(decoded.env == ["TERM": "xterm-256color"])
        #expect(decoded.workingDir == "/app")
        #expect(decoded.tty)
        #expect(decoded.rows == 32)
        #expect(decoded.cols == 120)
    }

    @Test("input carries raw bytes through base64")
    func inputCarriesRawBytes() throws {
        let payload = Data([0x03, 0x0D, 0xFF])
        let message = SandboxExecInputMessage(sessionId: "s-1", rawData: payload)
        let decoded = try throughEnvelope(message)
        #expect(decoded.rawData == payload)
        #expect(!decoded.eof)
    }

    @Test("an EOF-only input has no data")
    func eofOnlyInput() throws {
        let decoded = try throughEnvelope(SandboxExecInputMessage(sessionId: "s-1", eof: true))
        #expect(decoded.data == nil)
        #expect(decoded.rawData == nil)
        #expect(decoded.eof)
    }

    @Test("output carries raw bytes and its stream")
    func outputCarriesRawBytes() throws {
        let payload = Data("hello\r\n".utf8)
        let message = SandboxExecOutputMessage(sessionId: "s-1", stream: "stderr", rawData: payload)
        let decoded = try throughEnvelope(message)
        #expect(decoded.stream == "stderr")
        #expect(decoded.rawData == payload)
    }

    @Test("resize, exit, close, closed, started round-trip")
    func controlMessagesRoundTrip() throws {
        let resize = try throughEnvelope(SandboxExecResizeMessage(sessionId: "s-1", rows: 40, cols: 132))
        #expect(resize.rows == 40)
        #expect(resize.cols == 132)

        let exit = try throughEnvelope(SandboxExecExitMessage(sessionId: "s-1", exitCode: 137))
        #expect(exit.exitCode == 137)

        let close = try throughEnvelope(SandboxExecCloseMessage(sessionId: "s-1", reason: "browser gone"))
        #expect(close.reason == "browser gone")

        let closed = try throughEnvelope(SandboxExecClosedMessage(sessionId: "s-1", reason: "vsock died"))
        #expect(closed.reason == "vsock died")

        let started = try throughEnvelope(
            SandboxExecStartedMessage(sandboxId: Fixtures.uuidA.uuidString, sessionId: "s-1"))
        #expect(started.sandboxId == Fixtures.uuidA.uuidString)
        #expect(started.sessionId == "s-1")
    }

    @Test("sandbox log round-trips")
    func sandboxLogRoundTrips() throws {
        let message = SandboxLogMessage(
            sandboxId: Fixtures.uuidA.uuidString, stream: "stdout", message: "listening on :8080")
        let decoded = try throughEnvelope(message)
        #expect(decoded.sandboxId == Fixtures.uuidA.uuidString)
        #expect(decoded.stream == "stdout")
        #expect(decoded.message == "listening on :8080")
    }

    @Test("exec gate refuses pre-v8 agents and admits v8")
    func execVersionGate() {
        #expect(!WireProtocol.supportsSandboxExec(WireProtocol.sandboxExecMinimumVersion - 1))
        #expect(WireProtocol.supportsSandboxExec(WireProtocol.sandboxExecMinimumVersion))
        #expect(WireProtocol.supportsSandboxExec(WireProtocol.currentVersion))
    }
}
