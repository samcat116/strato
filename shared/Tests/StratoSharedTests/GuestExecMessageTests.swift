import Foundation
import StratoShared
import Testing

@Suite("Guest exec messages")
struct GuestExecMessageTests {

    @Test(
        "exec start round-trips both resource kinds and session kinds with every field",
        arguments: GuestResourceKind.allCases)
    func execStartRoundTrips(resourceKind: GuestResourceKind) throws {
        for sessionKind in GuestExecSessionKind.allCases {
            let message = GuestExecStartMessage(
                requestId: Fixtures.requestId,
                timestamp: Fixtures.timestamp,
                resourceKind: resourceKind,
                resourceId: Fixtures.uuidA.uuidString,
                sessionKind: sessionKind,
                sessionId: Fixtures.uuidB.uuidString,
                command: ["/bin/sh", "-c", "echo hi"],
                env: ["TERM": "xterm-256color"],
                workingDir: "/app",
                tty: true,
                rows: 32,
                cols: 120
            )
            let decoded = try throughEnvelope(message)
            #expect(decoded.resourceKind == resourceKind)
            #expect(decoded.resourceId == message.resourceId)
            #expect(decoded.sessionKind == sessionKind)
            #expect(decoded.sessionId == message.sessionId)
            #expect(decoded.command == ["/bin/sh", "-c", "echo hi"])
            #expect(decoded.env == ["TERM": "xterm-256color"])
            #expect(decoded.workingDir == "/app")
            #expect(decoded.tty)
            #expect(decoded.rows == 32)
            #expect(decoded.cols == 120)
            let keys = try encodedKeys(message)
            #expect(keys.contains("resourceKind"))
            #expect(keys.contains("resourceId"))
            #expect(keys.contains("sessionKind"))
            #expect(keys.contains("sandboxId") == false)
        }
    }

    @Test("resource kinds use the resource-operation wire spelling")
    func resourceKindWireSpellings() throws {
        #expect(
            String(decoding: try encodeJSON(GuestResourceKind.virtualMachine), as: UTF8.self) == #""virtual_machine""#)
        #expect(String(decoding: try encodeJSON(GuestResourceKind.sandbox), as: UTF8.self) == #""sandbox""#)
    }

    @Test("session kinds use explicit wire spellings")
    func sessionKindWireSpellings() throws {
        #expect(
            String(decoding: try encodeJSON(GuestExecSessionKind.interactive), as: UTF8.self)
                == #""interactive""#)
        #expect(
            String(decoding: try encodeJSON(GuestExecSessionKind.recorded), as: UTF8.self)
                == #""recorded""#)
    }

    @Test("exec start requires a session kind")
    func execStartRequiresSessionKind() throws {
        let message = GuestExecStartMessage(
            resourceKind: .virtualMachine,
            resourceId: Fixtures.uuidA.uuidString,
            sessionKind: .interactive,
            sessionId: Fixtures.uuidB.uuidString,
            command: ["true"]
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: encodeJSON(message)) as? [String: Any])
        object.removeValue(forKey: "sessionKind")
        let missingSessionKind = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: DecodingError.self) {
            try decodeJSON(GuestExecStartMessage.self, from: missingSessionKind)
        }
    }

    @Test("recorded states carry authoritative bounded output and terminal outcomes")
    func recordedStatesRoundTrip() throws {
        let stdout = Data([0x00, 0x68, 0x69, 0xFF])
        let stderr = Data("warning\n".utf8)

        let running = try throughEnvelope(
            GuestExecRecordedStateMessage(
                sessionId: "s-running",
                revision: 4,
                status: .running,
                rawStdout: stdout,
                rawStderr: stderr,
                truncated: false
            ))
        #expect(running.status == .running)
        #expect(running.revision == 4)
        #expect(running.status.isTerminal == false)
        #expect(running.rawStdout == stdout)
        #expect(running.rawStderr == stderr)
        #expect(running.exitCode == nil)
        #expect(running.reason == nil)
        #expect(running.truncated == false)

        let exited = try throughEnvelope(
            GuestExecRecordedStateMessage(
                sessionId: "s-exited",
                revision: 5,
                status: .exited,
                rawStdout: stdout,
                rawStderr: stderr,
                exitCode: 17,
                truncated: true
            ))
        #expect(exited.status.isTerminal)
        #expect(exited.exitCode == 17)
        #expect(exited.reason == nil)
        #expect(exited.truncated)

        let closed = try throughEnvelope(
            GuestExecRecordedStateMessage(
                sessionId: "s-closed",
                revision: 6,
                status: .closed,
                rawStdout: stdout,
                rawStderr: stderr,
                reason: "guest channel closed",
                truncated: true
            ))
        #expect(closed.status.isTerminal)
        #expect(closed.exitCode == nil)
        #expect(closed.reason == "guest channel closed")
        #expect(closed.truncated)

        #expect(GuestExecRecordedStateMessage.outputLimitBytes == 1_048_576)
        let keys = try encodedKeys(closed)
        #expect(keys.contains("stdout"))
        #expect(keys.contains("stderr"))
        #expect(keys.contains("revision"))
        #expect(keys.contains("truncated"))

        var object = try #require(
            JSONSerialization.jsonObject(with: encodeJSON(closed)) as? [String: Any])
        object.removeValue(forKey: "revision")
        let missingRevision = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try decodeJSON(GuestExecRecordedStateMessage.self, from: missingRevision)
        }
    }

    @Test("recorded acknowledgement is keyed by session, not request id")
    func recordedAckRoundTrips() throws {
        let state = GuestExecRecordedStateMessage(
            requestId: "state-log-id",
            sessionId: "s-1",
            revision: 1,
            status: .exited,
            rawStdout: Data(),
            rawStderr: Data(),
            exitCode: 0,
            truncated: false
        )
        let ack = try throughEnvelope(
            GuestExecRecordedAckMessage(requestId: "ack-log-id", sessionId: state.sessionId))

        #expect(ack.sessionId == state.sessionId)
        #expect(ack.requestId == "ack-log-id")
        #expect(ack.requestId != state.requestId)
    }

    @Test("input carries raw bytes through base64")
    func inputCarriesRawBytes() throws {
        let payload = Data([0x03, 0x0D, 0xFF])
        let message = GuestExecInputMessage(sessionId: "s-1", rawData: payload)
        let decoded = try throughEnvelope(message)
        #expect(decoded.rawData == payload)
        #expect(!decoded.eof)
    }

    @Test("an EOF-only input has no data")
    func eofOnlyInput() throws {
        let decoded = try throughEnvelope(GuestExecInputMessage(sessionId: "s-1", eof: true))
        #expect(decoded.data == nil)
        #expect(decoded.rawData == nil)
        #expect(decoded.eof)
    }

    @Test("output carries raw bytes")
    func outputCarriesRawBytes() throws {
        let payload = Data("hello\r\n".utf8)
        let message = GuestExecOutputMessage(sessionId: "s-1", stream: "stdout", rawData: payload)
        let decoded = try throughEnvelope(message)
        #expect(decoded.rawData == payload)
        #expect(decoded.stream == "stdout")
    }

    @Test("resize, exit, close, closed, started round-trip")
    func controlMessagesRoundTrip() throws {
        let resize = try throughEnvelope(GuestExecResizeMessage(sessionId: "s-1", rows: 40, cols: 132))
        #expect(resize.rows == 40)
        #expect(resize.cols == 132)

        let exit = try throughEnvelope(GuestExecExitMessage(sessionId: "s-1", exitCode: 137))
        #expect(exit.exitCode == 137)

        let close = try throughEnvelope(GuestExecCloseMessage(sessionId: "s-1", reason: "browser gone"))
        #expect(close.reason == "browser gone")

        let closed = try throughEnvelope(GuestExecClosedMessage(sessionId: "s-1", reason: "vsock died"))
        #expect(closed.reason == "vsock died")

        let started = try throughEnvelope(GuestExecStartedMessage(sessionId: "s-1"))
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
}
