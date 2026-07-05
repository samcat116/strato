import Foundation
import Testing
import StratoShared

@Suite("Agent registration and heartbeat messages")
struct AgentMessageTests {
    @Test func agentRegisterRoundTrip() throws {
        let message = AgentRegisterMessage(
            requestId: Fixtures.requestId,
            timestamp: Fixtures.timestamp,
            agentId: "agent-1",
            hostname: "hv-01.example",
            version: "1.2.3",
            capabilities: ["kvm", "ovn"],
            resources: Fixtures.resources,
            hypervisorType: .firecracker
        )
        let decoded = try throughEnvelope(message)
        #expect(decoded.type == .agentRegister)
        #expect(decoded.requestId == message.requestId)
        #expect(decoded.timestamp == message.timestamp)
        #expect(decoded.agentId == "agent-1")
        #expect(decoded.hostname == "hv-01.example")
        #expect(decoded.version == "1.2.3")
        #expect(decoded.capabilities == ["kvm", "ovn"])
        #expect(decoded.hypervisorType == .firecracker)
        #expect(decoded.resources.totalCPU == Fixtures.resources.totalCPU)
        #expect(decoded.resources.availableCPU == Fixtures.resources.availableCPU)
        #expect(decoded.resources.totalMemory == Fixtures.resources.totalMemory)
        #expect(decoded.resources.availableMemory == Fixtures.resources.availableMemory)
        #expect(decoded.resources.totalDisk == Fixtures.resources.totalDisk)
        #expect(decoded.resources.availableDisk == Fixtures.resources.availableDisk)
    }

    @Test func agentHeartbeatRoundTrip() throws {
        let message = AgentHeartbeatMessage(
            requestId: Fixtures.requestId,
            timestamp: Fixtures.timestamp,
            agentId: "agent-1",
            resources: Fixtures.resources,
            runningVMs: ["vm-a", "vm-b"]
        )
        let decoded = try throughEnvelope(message)
        #expect(decoded.type == .agentHeartbeat)
        #expect(decoded.agentId == "agent-1")
        #expect(decoded.runningVMs == ["vm-a", "vm-b"])
        #expect(decoded.resources.availableMemory == Fixtures.resources.availableMemory)
    }

    @Test func agentUnregisterRoundTrip() throws {
        let message = AgentUnregisterMessage(
            requestId: Fixtures.requestId,
            timestamp: Fixtures.timestamp,
            agentId: "agent-1",
            reason: "shutting down"
        )
        let decoded = try throughEnvelope(message)
        #expect(decoded.type == .agentUnregister)
        #expect(decoded.agentId == "agent-1")
        #expect(decoded.reason == "shutting down")
    }

    @Test func agentRegisterResponseRoundTrip() throws {
        let message = AgentRegisterResponseMessage(
            requestId: Fixtures.requestId,
            timestamp: Fixtures.timestamp,
            agentId: Fixtures.uuidA.uuidString,
            name: "hv-01",
            reconnectToken: "tok-secret"
        )
        let decoded = try throughEnvelope(message)
        #expect(decoded.type == .agentRegisterResponse)
        #expect(decoded.requestId == message.requestId)
        #expect(decoded.agentId == Fixtures.uuidA.uuidString)
        #expect(decoded.name == "hv-01")
        #expect(decoded.reconnectToken == "tok-secret")
    }

    /// `reconnectToken` is documented as optional so agents can talk to
    /// control planes that predate token rotation — a payload without the key
    /// must still decode.
    @Test func agentRegisterResponseDecodesWithoutReconnectToken() throws {
        let json = """
            {"type":"agent_register_response","requestId":"r","timestamp":0,
             "agentId":"a","name":"n"}
            """
        let decoded = try decodeJSON(AgentRegisterResponseMessage.self, from: json)
        #expect(decoded.reconnectToken == nil)
        #expect(decoded.name == "n")
    }
}
