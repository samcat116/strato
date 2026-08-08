import Foundation
import Testing
import StratoShared

@Suite("MessageEnvelope")
struct MessageEnvelopeTests {
    @Test("envelope type mirrors the wrapped message's type")
    func envelopeTypeMatchesMessage() throws {
        let message = Fixtures.consoleConnect(vmId: "vm-1")
        let envelope = try MessageEnvelope(message: message)
        #expect(envelope.type == .consoleConnect)
    }

    @Test("message survives the full envelope round trip")
    func fullRoundTrip() throws {
        let message = Fixtures.consoleConnect(vmId: "vm-42")
        let decoded = try throughEnvelope(message)
        #expect(decoded.requestId == message.requestId)
        #expect(decoded.timestamp == message.timestamp)
        #expect(decoded.vmId == message.vmId)
    }

    @Test("wire form is a type string plus base64 payload")
    func wireShape() throws {
        let message = Fixtures.consoleConnect(vmId: "vm-7")
        let envelopeData = try encodeJSON(MessageEnvelope(message: message))
        let object = try JSONSerialization.jsonObject(with: envelopeData) as? [String: Any]
        let json = try #require(object)

        #expect(json["type"] as? String == "console_connect")

        // Data encodes as base64 under default JSONEncoder settings; the
        // payload must decode back to the inner message's JSON.
        let base64 = try #require(json["payload"] as? String)
        let payload = try #require(Data(base64Encoded: base64))
        let inner = try decodeJSON(ConsoleConnectMessage.self, from: payload)
        #expect(inner.vmId == "vm-7")
    }

    @Test("payload that does not match the requested type throws")
    func mismatchedPayloadThrows() throws {
        let envelope = try MessageEnvelope(message: SuccessMessage(requestId: "r1"))
        #expect(throws: DecodingError.self) {
            // ConsoleDataMessage requires fields a success reply lacks.
            try envelope.decode(as: ConsoleDataMessage.self)
        }
    }
}
