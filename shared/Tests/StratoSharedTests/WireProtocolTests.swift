import Foundation
import Testing
import StratoShared

@Suite("Wire protocol versioning and date strategy")
struct WireProtocolTests {
    // MARK: - Envelope versioning

    @Test("envelope stamps the current wire version")
    func envelopeStampsVersion() throws {
        let envelope = try MessageEnvelope(message: VMInfoRequestMessage(vmId: "vm-1"))
        #expect(envelope.version == WireProtocol.currentVersion)
        #expect(envelope.senderVersion == WireProtocol.currentVersion)
    }

    @Test("version survives the envelope round trip")
    func versionRoundTrips() throws {
        let envelope = try MessageEnvelope(message: VMInfoRequestMessage(vmId: "vm-1"))
        let decoded = try decodeJSON(MessageEnvelope.self, from: encodeJSON(envelope))
        #expect(decoded.version == WireProtocol.currentVersion)
    }

    @Test("an envelope without a version field decodes as legacy version 0")
    func legacyEnvelopeDefaultsToZero() throws {
        // A peer that predates versioning sends only `type` + `payload`.
        let inner = try encodeJSON(VMInfoRequestMessage(
            requestId: Fixtures.requestId,
            timestamp: Fixtures.timestamp,
            vmId: "vm-1"
        ))
        let json = #"{"type":"vm_info","payload":"\#(inner.base64EncodedString())"}"#
        let envelope = try decodeJSON(MessageEnvelope.self, from: json)
        #expect(envelope.version == nil)
        #expect(envelope.senderVersion == 0)
        // The payload still decodes normally.
        #expect(try envelope.decode(as: VMInfoRequestMessage.self).vmId == "vm-1")
    }

    // MARK: - Registration version negotiation

    @Test("registration messages default to the current wire version")
    func registrationDefaultsVersion() throws {
        let register = AgentRegisterMessage(
            agentId: "a1",
            hostname: "host",
            version: "1.2.3",
            capabilities: [],
            resources: Fixtures.resources
        )
        #expect(register.protocolVersion == WireProtocol.currentVersion)

        let response = AgentRegisterResponseMessage(requestId: Fixtures.requestId, agentId: "a1", name: "agent")
        #expect(response.protocolVersion == WireProtocol.currentVersion)
    }

    @Test("registration protocol version survives the wire, absent decodes as nil")
    func registrationVersionOnWire() throws {
        let register = AgentRegisterMessage(
            agentId: "a1",
            hostname: "host",
            version: "1.2.3",
            capabilities: [],
            resources: Fixtures.resources
        )
        #expect(try throughEnvelope(register).protocolVersion == WireProtocol.currentVersion)

        // A registration from an agent that predates negotiation omits the field.
        let legacy = #"{"requestId":"r","timestamp":"2023-11-14T22:13:20Z","agentId":"a1","hostname":"h","version":"0.9","capabilities":[],"resources":{"totalCPU":1,"availableCPU":1,"totalMemory":1,"availableMemory":1,"totalDisk":1,"availableDisk":1},"hypervisorType":"qemu"}"#
        let decoded = try decodeJSON(AgentRegisterMessage.self, from: legacy)
        #expect(decoded.protocolVersion == nil)
    }

    // MARK: - Date strategy

    @Test("timestamps encode as ISO-8601 strings on the wire")
    func timestampsAreISO8601() throws {
        let message = VMInfoRequestMessage(
            requestId: Fixtures.requestId,
            timestamp: Fixtures.timestamp,
            vmId: "vm-1"
        )
        let object = try JSONSerialization.jsonObject(with: encodeJSON(message)) as? [String: Any]
        let json = try #require(object)
        // 1_700_000_000 seconds since 1970 == 2023-11-14T22:13:20Z.
        #expect(json["timestamp"] as? String == "2023-11-14T22:13:20Z")
    }

    @Test("decoder tolerates legacy numeric (deferredToDate) timestamps")
    func decoderToleratesLegacyNumericDates() throws {
        // Foundation's default `deferredToDate` encodes a Date as seconds since
        // the 2001 reference date. A peer that predates the ISO-8601 switch still
        // sends that form; the shared decoder must accept it.
        let legacyEncoder = JSONEncoder()  // default deferredToDate strategy
        let message = VMInfoRequestMessage(
            requestId: Fixtures.requestId,
            timestamp: Fixtures.timestamp,
            vmId: "vm-1"
        )
        let legacyData = try legacyEncoder.encode(message)

        // Sanity check: the legacy form really is a bare number, not a string.
        let object = try JSONSerialization.jsonObject(with: legacyData) as? [String: Any]
        #expect(object?["timestamp"] is NSNumber)

        let decoded = try decodeJSON(VMInfoRequestMessage.self, from: legacyData)
        #expect(decoded.timestamp == Fixtures.timestamp)
        #expect(decoded.vmId == "vm-1")
    }

    @Test("a malformed date string is a decode error, not a silent zero date")
    func malformedDateStringThrows() {
        let json = #"{"requestId":"r","timestamp":"not-a-date","vmId":"vm-1"}"#
        #expect(throws: DecodingError.self) {
            try decodeJSON(VMInfoRequestMessage.self, from: json)
        }
    }
}
