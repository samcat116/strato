import Foundation
import Testing
@testable import StratoShared

@Suite("Stable update-only bridge")
struct AgentUpdateBridgeTests {
    @Test("Frozen v1 decodes across both directions of workload skew", arguments: [68, 70])
    func skew(version: Int) throws {
        let json =
            #"{"exchangeVersion":1,"workloadWireVersion":69,"update":{"targetVersion":"bridge-target","artifactURL":"https://example.test/agent","sha256":"abc","artifactKind":"binary"}}"#
        let response = try JSONDecoder().decode(AgentUpdateBridgeResponse.self, from: Data(json.utf8))
        let update = try #require(try response.skewUpdate(agentWireVersion: version))
        #expect(update.targetVersion == "bridge-target")
        #expect(update.artifactKind == .binary)
    }

    @Test("Matching versions keep updates on ordinary desired state")
    func matching() throws {
        let update = DesiredAgentUpdate(
            targetVersion: "new", artifactURL: "https://example.test/agent",
            sha256: "abc", artifactKind: .binary)
        let response = AgentUpdateBridgeResponse(workloadWireVersion: 69, update: update)
        #expect(try response.skewUpdate(agentWireVersion: 69) == nil)
        let ordinary = DesiredStateMessage(syncId: "ordinary", vms: [], desiredAgentUpdate: update)
        let decoded = try WireProtocol.makeDecoder().decode(
            DesiredStateMessage.self,
            from: WireProtocol.makeEncoder().encode(ordinary))
        #expect(decoded.desiredAgentUpdate?.targetVersion == "new")
    }

    @Test("No assignment grants no update; unknown exchange fails closed")
    func noAssignmentAndUnknownExchange() throws {
        let response = AgentUpdateBridgeResponse(workloadWireVersion: 70, update: nil)
        #expect(try response.skewUpdate(agentWireVersion: 69) == nil)
        let unknown = try JSONDecoder().decode(
            AgentUpdateBridgeResponse.self,
            from: Data(#"{"exchangeVersion":2,"workloadWireVersion":70}"#.utf8))
        #expect(throws: AgentUpdateBridgeResponse.BridgeError.self) {
            try unknown.skewUpdate(agentWireVersion: 69)
        }
        let keys = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
        #expect(Set(keys.keys) == ["exchangeVersion", "workloadWireVersion"])
    }
}
