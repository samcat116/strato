import Foundation
import StratoShared
import SwiftProtobuf
import Testing

@Suite("Protobuf capability negotiation")
struct AgentProtocolCompatibilityTests {
    private func offer(_ capabilities: [String]) -> Strato_Agent_V1_ProtocolOffer {
        .with {
            $0.major = AgentProtocolCompatibility.major
            $0.capabilities = capabilities
        }
    }

    @Test("Independent feature branches negotiate only common behavior")
    func independentFeatures() throws {
        let local = offer(["exec.v1", "feature-a.v1"])
        let remote = offer(["exec.v1", "feature-b.v1"])
        let session = UUID()
        let agreement = try AgentProtocolCompatibility.negotiate(
            local: local, remote: remote, inventorySessionID: session)
        let decoded = try Strato_Agent_V1_ProtocolAgreement(serializedBytes: agreement.serializedData())
        #expect(decoded.capabilities == ["exec.v1"])
        #expect(decoded.inventorySessionID == session.uuidString)
        try AgentProtocolCompatibility.validate(decoded, offered: remote)
        try AgentProtocolCompatibility.require(
            .with { $0.capabilities = ["exec.v1"] }, agreement: decoded, offered: remote)
        #expect(throws: AgentProtocolCompatibility.Failure.unsupportedCapability) {
            try AgentProtocolCompatibility.require(
                .with { $0.capabilities = ["feature-b.v1"] }, agreement: decoded, offered: remote)
        }
    }

    @Test("Missing and incompatible majors fail before negotiation")
    func invalidMajor() throws {
        let absent = try Strato_Agent_V1_ProtocolOffer(serializedBytes: Data())
        #expect(!absent.hasMajor)
        #expect(throws: AgentProtocolCompatibility.Failure.missingMajor) {
            try AgentProtocolCompatibility.negotiate(local: offer([]), remote: absent, inventorySessionID: UUID())
        }
        var future = offer([])
        future.major = 2
        #expect(throws: AgentProtocolCompatibility.Failure.incompatibleMajor) {
            try AgentProtocolCompatibility.negotiate(local: offer([]), remote: future, inventorySessionID: UUID())
        }
    }

    @Test("A peer cannot enable an unoffered feature or omit session ownership")
    func invalidAgreement() throws {
        let local = offer(["exec.v1"])
        var agreement = try AgentProtocolCompatibility.negotiate(
            local: local, remote: local, inventorySessionID: UUID())
        agreement.capabilities.append("feature-a.v1")
        #expect(throws: AgentProtocolCompatibility.Failure.unofferedCapability) {
            try AgentProtocolCompatibility.validate(agreement, offered: local)
        }
        agreement.capabilities = []
        agreement.clearInventorySessionID()
        #expect(throws: AgentProtocolCompatibility.Failure.invalidSession) {
            try AgentProtocolCompatibility.validate(agreement, offered: local)
        }
    }

    @Test("Unknown additive fields survive a binary relay")
    func unknownFieldRelay() throws {
        var bytes = try offer(["exec.v1"]).serializedData()
        // A future field 100, varint value 7, encoded independently of this schema.
        bytes.append(contentsOf: [0xa0, 0x06, 0x07])
        let decoded = try Strato_Agent_V1_ProtocolOffer(serializedBytes: bytes)
        #expect(!decoded.unknownFields.data.isEmpty)
        let relayed = try Strato_Agent_V1_ProtocolOffer(serializedBytes: decoded.serializedData())
        #expect(relayed.unknownFields == decoded.unknownFields)
        _ = try AgentProtocolCompatibility.negotiate(
            local: offer(["exec.v1"]), remote: relayed, inventorySessionID: UUID())
    }

    @Test("Negotiation rejects unbounded and malformed capability identifiers")
    func invalidCapabilities() {
        for capabilities in [[""], ["line\nbreak"], Array(repeating: "exec.v1", count: 257)] {
            #expect(throws: AgentProtocolCompatibility.Failure.invalidCapability) {
                try AgentProtocolCompatibility.negotiate(
                    local: offer([]), remote: offer(capabilities), inventorySessionID: UUID())
            }
        }
    }
}
