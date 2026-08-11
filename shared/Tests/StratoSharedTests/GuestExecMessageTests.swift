import Foundation
import StratoShared
import Testing

@Suite("Guest exec messages")
struct GuestExecMessageTests {

    @Test("exec start round-trips both resource kinds with every field", arguments: GuestResourceKind.allCases)
    func execStartRoundTrips(resourceKind: GuestResourceKind) throws {
        let message = GuestExecStartMessage(
            requestId: Fixtures.requestId,
            timestamp: Fixtures.timestamp,
            resourceKind: resourceKind,
            resourceId: Fixtures.uuidA.uuidString,
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
        #expect(keys.contains("sandboxId") == false)
    }

    @Test("resource kinds use the resource-operation wire spelling")
    func resourceKindWireSpellings() throws {
        #expect(
            String(decoding: try encodeJSON(GuestResourceKind.virtualMachine), as: UTF8.self) == #""virtual_machine""#)
        #expect(String(decoding: try encodeJSON(GuestResourceKind.sandbox), as: UTF8.self) == #""sandbox""#)
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
        let message = GuestExecOutputMessage(sessionId: "s-1", rawData: payload)
        let decoded = try throughEnvelope(message)
        #expect(decoded.rawData == payload)
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

    @Test("wire v43 sandbox start translates to the new sandbox target")
    func legacySandboxStartTranslates() throws {
        let legacy = try throughEnvelope(
            LegacySandboxExecStartMessage(
                requestId: Fixtures.requestId,
                timestamp: Fixtures.timestamp,
                sandboxId: Fixtures.uuidA.uuidString,
                sessionId: Fixtures.uuidB.uuidString,
                command: ["/bin/true"]))
        let translated = legacy.guestMessage
        #expect(translated.resourceKind == .sandbox)
        #expect(translated.resourceId == legacy.sandboxId)
        #expect(translated.sessionId == legacy.sessionId)
        #expect(translated.command == legacy.command)
    }

    @Test("wire v43 responses retain sandbox-prefixed discriminators")
    func legacySandboxResponseDiscriminators() throws {
        let started = try MessageEnvelope(message: LegacySandboxExecStartedMessage(sessionId: "s-1"))
        #expect(started.type == .sandboxExecStarted)

        let output = try MessageEnvelope(
            message: LegacySandboxExecOutputMessage(sessionId: "s-1", rawData: Data("hello".utf8)))
        #expect(output.type == .sandboxExecOutput)

        let exit = try MessageEnvelope(message: LegacySandboxExecExitMessage(sessionId: "s-1", exitCode: 0))
        #expect(exit.type == .sandboxExecExit)

        let closed = try MessageEnvelope(
            message: LegacySandboxExecClosedMessage(sessionId: "s-1", reason: "done"))
        #expect(closed.type == .sandboxExecClosed)
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
