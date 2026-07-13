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
        let inner = try encodeJSON(
            VMInfoRequestMessage(
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

    @Test("agent update gate: only v6+ agents can be sent the update command")
    func agentUpdateGate() {
        // A pre-v6 agent has no `agent_update` MessageType case: it fails the
        // envelope decode silently and never replies, so the control plane
        // must refuse rather than send and time out.
        #expect(!WireProtocol.supportsAgentUpdate(0))
        #expect(!WireProtocol.supportsAgentUpdate(5))
        #expect(WireProtocol.supportsAgentUpdate(6))
        #expect(WireProtocol.supportsAgentUpdate(WireProtocol.currentVersion))
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
        let legacy =
            #"{"requestId":"r","timestamp":"2023-11-14T22:13:20Z","agentId":"a1","hostname":"h","version":"0.9","capabilities":[],"resources":{"totalCPU":1,"availableCPU":1,"totalMemory":1,"availableMemory":1,"totalDisk":1,"availableDisk":1},"hypervisorType":"qemu"}"#
        let decoded = try decodeJSON(AgentRegisterMessage.self, from: legacy)
        #expect(decoded.protocolVersion == nil)
    }

    // MARK: - Date strategy

    @Test("timestamps still encode as the legacy numeric form for backward compat")
    func timestampsEncodeAsLegacyNumeric() throws {
        // Phase 1 keeps emitting `deferredToDate` numbers so a peer that predates
        // this work — which decodes with a bare JSONDecoder — can still read our
        // timestamps. The encoder flips to ISO-8601 only once every peer is known
        // to read both forms (see WireProtocol's migration note).
        let message = VMInfoRequestMessage(
            requestId: Fixtures.requestId,
            timestamp: Fixtures.timestamp,
            vmId: "vm-1"
        )
        let object = try JSONSerialization.jsonObject(with: encodeJSON(message)) as? [String: Any]
        let json = try #require(object)
        #expect(json["timestamp"] is NSNumber)
        // A bare JSONDecoder (what an un-upgraded peer uses) must still read it.
        let decodedByLegacyPeer = try JSONDecoder().decode(VMInfoRequestMessage.self, from: encodeJSON(message))
        #expect(decodedByLegacyPeer.timestamp == Fixtures.timestamp)
    }

    @Test("decoder accepts the legacy numeric (deferredToDate) form")
    func decoderAcceptsLegacyNumericDates() throws {
        // Foundation's default `deferredToDate` encodes a Date as seconds since
        // the 2001 reference date — the current wire form. The shared decoder
        // must accept it.
        let legacyEncoder = JSONEncoder()  // default deferredToDate strategy
        let message = VMInfoRequestMessage(
            requestId: Fixtures.requestId,
            timestamp: Fixtures.timestamp,
            vmId: "vm-1"
        )
        let legacyData = try legacyEncoder.encode(message)

        // Sanity check: the form really is a bare number, not a string.
        let object = try JSONSerialization.jsonObject(with: legacyData) as? [String: Any]
        #expect(object?["timestamp"] is NSNumber)

        let decoded = try decodeJSON(VMInfoRequestMessage.self, from: legacyData)
        #expect(decoded.timestamp == Fixtures.timestamp)
        #expect(decoded.vmId == "vm-1")
    }

    @Test("decoder also accepts ISO-8601 strings, so a future encoder flip is safe")
    func decoderAcceptsISO8601Dates() throws {
        // Forward compatibility: nothing emits ISO-8601 yet, but the decoder must
        // already read it so the eventual encoder flip needs no rollout window.
        // 2023-11-14T22:13:20Z == Fixtures.timestamp (1_700_000_000 since 1970).
        let json = #"{"requestId":"r","timestamp":"2023-11-14T22:13:20Z","vmId":"vm-1"}"#
        let decoded = try decodeJSON(VMInfoRequestMessage.self, from: json)
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
