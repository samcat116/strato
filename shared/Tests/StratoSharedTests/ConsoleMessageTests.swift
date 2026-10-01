import Foundation
import Testing
import StratoShared

@Suite("Console operation messages")
struct ConsoleMessageTests {
    @Test func consoleConnectDefaultsToSerial() throws {
        let message = ConsoleConnectMessage(vmId: "vm-1", sessionId: "sess-1")
        #expect(message.stream == .serial)
        let json = String(decoding: try encodeJSON(message), as: UTF8.self)
        #expect(json.contains("\"stream\":\"Serial\""))
    }

    @Test func consoleConnectCarriesTheVNCStream() throws {
        let decoded = try throughEnvelope(
            ConsoleConnectMessage(
                requestId: Fixtures.requestId, timestamp: Fixtures.timestamp, vmId: "vm-1", sessionId: "sess-1",
                stream: .vnc)
        )
        #expect(decoded.stream == .vnc)
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
}
