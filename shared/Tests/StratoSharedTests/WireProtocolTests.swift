import Foundation
import Testing
import StratoShared

@Suite("Wire protocol versioning and date strategy")
struct WireProtocolTests {
    // MARK: - Envelope schema

    @Test("envelope carries routing and payload without a duplicate version")
    func envelopeHasNoVersion() throws {
        let envelope = try MessageEnvelope(message: Fixtures.consoleConnect(vmId: "vm-1"))
        let data = try WireProtocol.makeEncoder().encode(envelope)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["version"] == nil)
        #expect(Set(object.keys) == ["type", "payload"])
    }

    @Test("the current wire contract is exact")
    func currentContractVersion() {
        #expect(WireProtocol.currentVersion == 42)
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
        #expect(try throughEnvelope(register).protocolVersion == WireProtocol.currentVersion)

        let missing =
            #"{"requestId":"r","timestamp":"2023-11-14T22:13:20Z","agentId":"a1","hostname":"h","version":"0.9","resources":{"totalCPU":1,"availableCPU":1,"totalMemory":1,"availableMemory":1,"totalDisk":1,"availableDisk":1}}"#
        #expect(throws: DecodingError.self) {
            try decodeJSON(AgentRegisterMessage.self, from: missing)
        }
    }

    // MARK: - Date strategy

    @Test("timestamps still encode as the legacy numeric form for backward compat")
    func timestampsEncodeAsLegacyNumeric() throws {
        // Phase 1 keeps emitting `deferredToDate` numbers so a peer that predates
        // this work — which decodes with a bare JSONDecoder — can still read our
        // timestamps. The encoder flips to ISO-8601 only once every peer is known
        // to read both forms (see WireProtocol's migration note).
        let message = Fixtures.consoleConnect(vmId: "vm-1")
        let object = try JSONSerialization.jsonObject(with: encodeJSON(message)) as? [String: Any]
        let json = try #require(object)
        #expect(json["timestamp"] is NSNumber)
        // A bare JSONDecoder (what an un-upgraded peer uses) must still read it.
        let decodedByLegacyPeer = try JSONDecoder().decode(
            ConsoleConnectMessage.self, from: encodeJSON(message))
        #expect(decodedByLegacyPeer.timestamp == Fixtures.timestamp)
    }

    @Test("decoder accepts the legacy numeric (deferredToDate) form")
    func decoderAcceptsLegacyNumericDates() throws {
        // Foundation's default `deferredToDate` encodes a Date as seconds since
        // the 2001 reference date — the current wire form. The shared decoder
        // must accept it.
        let legacyEncoder = JSONEncoder()  // default deferredToDate strategy
        let legacyData = try legacyEncoder.encode(Fixtures.consoleConnect(vmId: "vm-1"))

        // Sanity check: the form really is a bare number, not a string.
        let object = try JSONSerialization.jsonObject(with: legacyData) as? [String: Any]
        #expect(object?["timestamp"] is NSNumber)

        let decoded = try decodeJSON(ConsoleConnectMessage.self, from: legacyData)
        #expect(decoded.timestamp == Fixtures.timestamp)
        #expect(decoded.vmId == "vm-1")
    }

    @Test("decoder also accepts ISO-8601 strings, so a future encoder flip is safe")
    func decoderAcceptsISO8601Dates() throws {
        // Forward compatibility: nothing emits ISO-8601 yet, but the decoder must
        // already read it so the eventual encoder flip needs no rollout window.
        // 2023-11-14T22:13:20Z == Fixtures.timestamp (1_700_000_000 since 1970).
        let json =
            #"{"requestId":"r","timestamp":"2023-11-14T22:13:20Z","vmId":"vm-1","sessionId":"s"}"#
        let decoded = try decodeJSON(ConsoleConnectMessage.self, from: json)
        #expect(decoded.timestamp == Fixtures.timestamp)
        #expect(decoded.vmId == "vm-1")
    }

    @Test("a malformed date string is a decode error, not a silent zero date")
    func malformedDateStringThrows() {
        let json = #"{"requestId":"r","timestamp":"not-a-date","vmId":"vm-1","sessionId":"s"}"#
        #expect(throws: DecodingError.self) {
            try decodeJSON(ConsoleConnectMessage.self, from: json)
        }
    }
}
