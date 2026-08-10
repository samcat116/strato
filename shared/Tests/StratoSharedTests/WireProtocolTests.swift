import Foundation
import Testing
import StratoShared

@Suite("Wire protocol versioning and date strategy")
struct WireProtocolTests {
    // MARK: - Envelope versioning

    @Test("envelope stamps the current wire version")
    func envelopeStampsVersion() throws {
        let envelope = try MessageEnvelope(message: Fixtures.consoleConnect(vmId: "vm-1"))
        #expect(envelope.version == WireProtocol.currentVersion)
        #expect(envelope.senderVersion == WireProtocol.currentVersion)
    }

    @Test("an envelope without a version field decodes as legacy version 0")
    func legacyEnvelopeDefaultsToZero() throws {
        // A peer that predates versioning sends only `type` + `payload`.
        let inner = try encodeJSON(Fixtures.consoleConnect(vmId: "vm-1"))
        let json = #"{"type":"console_connect","payload":"\#(inner.base64EncodedString())"}"#
        let envelope = try decodeJSON(MessageEnvelope.self, from: json)
        #expect(envelope.version == nil)
        #expect(envelope.senderVersion == 0)
        // The payload still decodes normally.
        #expect(try envelope.decode(as: ConsoleConnectMessage.self).vmId == "vm-1")
    }

    @Test("VM network hot-plug starts at wire protocol v40")
    func vmNetworkHotplugGate() {
        #expect(!WireProtocol.supportsVMNetworkHotplug(38))
        #expect(!WireProtocol.supportsVMNetworkHotplug(39))
        #expect(WireProtocol.supportsVMNetworkHotplug(40))
        #expect(WireProtocol.currentVersion == 41)
        #expect(WireProtocol.minimumSupportedVersion == 41)
    }
    @Test("sandbox fork guest gate rejects legacy and unknown checkpoints")
    func sandboxForkGuestGate() {
        #expect(!SandboxGuestControlProtocol.supportsReidentify(nil))
        #expect(!SandboxGuestControlProtocol.supportsReidentify(2))
        #expect(SandboxGuestControlProtocol.supportsReidentify(3))
        #expect(
            SandboxGuestControlProtocol.supportsReidentify(
                SandboxGuestControlProtocol.currentVersion))
    }

    /// A networked fork needs one version more than a network-free one: v3
    /// rotates identity but drops `reidentify`'s `network` block, which would
    /// leave the fork holding the source sandbox's address (STR-104).
    @Test("sandbox NIC re-addressing gate is stricter than the fork gate")
    func sandboxNetworkReconfigureGate() {
        #expect(!SandboxGuestControlProtocol.supportsNetworkReconfigure(nil))
        #expect(!SandboxGuestControlProtocol.supportsNetworkReconfigure(3))
        #expect(SandboxGuestControlProtocol.supportsNetworkReconfigure(4))
        #expect(
            SandboxGuestControlProtocol.supportsNetworkReconfigure(
                SandboxGuestControlProtocol.currentVersion))
        #expect(
            SandboxGuestControlProtocol.networkReconfigureMinimumVersion
                > SandboxGuestControlProtocol.reidentifyMinimumVersion)
    }

    // MARK: - Registration version negotiation

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
