import Foundation
import SwiftProtobuf
import Testing
import StratoShared

@Suite("Binary wire protocol")
struct WireProtocolTests {
    // MARK: - Envelope schema

    @Test("envelope carries routing and payload without a duplicate version")
    func envelopeHasNoVersion() throws {
        let envelope = try MessageEnvelope(message: Fixtures.consoleConnect(vmId: "vm-1"))
        let decoded = try WireProtocol.decodeEnvelope(WireProtocol.encodeEnvelope(envelope))
        #expect(decoded.body == envelope.body)
        #expect(decoded.requiredCapabilities.isEmpty)
    }

    @Test("the current wire contract is exact")
    func currentContractVersion() {
        #expect(Int(AgentProtocolCompatibility.major) == 1)
    }
    @Test("the sandbox guest control contract is exact")
    func sandboxGuestControlContract() {
        #expect(SandboxGuestControlProtocol.currentVersion == 4)
    }

    // MARK: - Registration version negotiation

    @Test("registration protocol version survives the wire and is required")
    func registrationVersionOnWire() throws {
        let register = AgentRegisterMessage(
            agentId: "a1",
            hostname: "host",
            version: "1.2.3",
            resources: Fixtures.resources
        )
        #expect(try throughEnvelope(register).protocolOffer.major == AgentProtocolCompatibility.major)

        var missing = register
        missing.clearProtocolOffer()
        #expect(throws: (any Error).self) { try WireProtocol.encodeEnvelope(missing) }
        let malformed = try MessageEnvelope(message: missing).serializedData()
        #expect(throws: AgentProtocolDecodeError.self) { try WireProtocol.decodeEnvelope(malformed) }
    }

    @Test("Binary timestamps preserve nanoseconds without a JSON date strategy")
    func timestampPrecision() throws {
        var message = Fixtures.consoleConnect(vmId: "vm-1")
        message.timestamp.seconds = 1_700_000_000
        message.timestamp.nanos = 123_456_789
        let decoded = try throughEnvelope(message)
        #expect(decoded.timestamp.seconds == 1_700_000_000)
        #expect(decoded.timestamp.nanos == 123_456_789)
    }
}
