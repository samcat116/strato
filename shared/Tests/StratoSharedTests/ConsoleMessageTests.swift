import Foundation
import Testing
import StratoShared

@Suite("Console operation messages")
struct ConsoleMessageTests {
    @Test func consoleConnectRoundTrip() throws {
        let decoded = try throughEnvelope(
            ConsoleConnectMessage(
                requestId: Fixtures.requestId, timestamp: Fixtures.timestamp, vmId: "vm-1", sessionId: "sess-1")
        )
        #expect(decoded.type == .consoleConnect)
        #expect(decoded.vmId == "vm-1")
        #expect(decoded.sessionId == "sess-1")
    }

    @Test func consoleDisconnectRoundTrip() throws {
        let decoded = try throughEnvelope(
            ConsoleDisconnectMessage(
                requestId: Fixtures.requestId, timestamp: Fixtures.timestamp, vmId: "vm-1", sessionId: "sess-1")
        )
        #expect(decoded.type == .consoleDisconnect)
        #expect(decoded.sessionId == "sess-1")
    }

    @Test func consoleDataRoundTripPreservesBytes() throws {
        // Console traffic is arbitrary bytes (including non-UTF8) shipped as
        // base64; the rawData accessor must return exactly what went in.
        let bytes = Data([0x00, 0xff, 0x1b, 0x5b, 0x48, 0x07, 0x80])
        let message = ConsoleDataMessage(
            requestId: Fixtures.requestId,
            timestamp: Fixtures.timestamp,
            vmId: "vm-1",
            sessionId: "sess-1",
            rawData: bytes
        )
        let decoded = try throughEnvelope(message)
        #expect(decoded.type == .consoleData)
        #expect(decoded.data == bytes.base64EncodedString())
        #expect(decoded.rawData == bytes)
    }

    @Test func consoleDataInvalidBase64YieldsNilRawData() {
        let message = ConsoleDataMessage(vmId: "vm-1", sessionId: "sess-1", data: "not base64!!!")
        #expect(message.rawData == nil)
    }

    @Test func consoleConnectedRoundTrip() throws {
        let decoded = try throughEnvelope(
            ConsoleConnectedMessage(
                requestId: Fixtures.requestId, timestamp: Fixtures.timestamp, vmId: "vm-1", sessionId: "sess-1")
        )
        #expect(decoded.type == .consoleConnected)
        #expect(decoded.vmId == "vm-1")
    }

    @Test func consoleDisconnectedRoundTrip() throws {
        let decoded = try throughEnvelope(
            ConsoleDisconnectedMessage(
                requestId: Fixtures.requestId,
                timestamp: Fixtures.timestamp,
                vmId: "vm-1",
                sessionId: "sess-1",
                reason: "vm stopped"
            )
        )
        #expect(decoded.type == .consoleDisconnected)
        #expect(decoded.reason == "vm stopped")
    }
}
