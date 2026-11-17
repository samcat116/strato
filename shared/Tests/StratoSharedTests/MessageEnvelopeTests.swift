import Foundation
import Testing
import SwiftProtobuf
import StratoShared

@Suite("Binary Protobuf message envelope")
struct MessageEnvelopeTests {
    @Test("typed oneof routes binary messages without JSON or base64 payloads")
    func binaryRoundTrip() throws {
        let message = Fixtures.consoleConnect(vmId: "vm-7")
        let bytes = try WireProtocol.encodeEnvelope(message)
        let envelope = try WireProtocol.decodeEnvelope(bytes)
        #expect(envelope.type == .consoleConnect)
        let decoded = try envelope.decode(as: ConsoleConnectMessage.self)
        #expect(decoded == message)
        #expect(throws: (any Error).self) { try JSONSerialization.jsonObject(with: bytes) }
    }

    @Test("payload type mismatch fails without guessing a message shape")
    func mismatchedPayloadThrows() throws {
        let envelope = try MessageEnvelope(message: SuccessMessage(requestId: "r1"))
        #expect(throws: AgentProtocolDecodeError.self) {
            try envelope.decode(as: ConsoleDataMessage.self)
        }
    }

    @Test("missing or unknown envelope bodies fail closed")
    func missingBody() throws {
        #expect(throws: AgentProtocolDecodeError.self) { try WireProtocol.decodeEnvelope(Data()) }
        // field 100, length-delimited, empty: unknown future body is preserved
        // by Protobuf but cannot accidentally become an executable command.
        #expect(throws: AgentProtocolDecodeError.self) { try WireProtocol.decodeEnvelope(Data([0xa2, 0x06, 0])) }
    }
}
