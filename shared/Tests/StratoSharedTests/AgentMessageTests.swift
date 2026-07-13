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

    @Test("Sandbox capability is opt-in: absent unless the runtime advertises it")
    func agentRegisterSandboxCapability() throws {
        // Default: a build that merely links protocol v5 does not claim the
        // capability — placement eligibility requires the explicit flag, so
        // agents without the sandbox runtime stay out of sandbox scheduling.
        let implicit = AgentRegisterMessage(
            agentId: "agent-1",
            hostname: "hv-01.example",
            version: "1.2.3",
            capabilities: ["kvm"],
            resources: Fixtures.resources
        )
        let decodedImplicit = try throughEnvelope(implicit)
        #expect(decodedImplicit.sandboxCapable == nil)

        let capable = AgentRegisterMessage(
            agentId: "agent-2",
            hostname: "hv-02.example",
            version: "1.2.3",
            capabilities: ["kvm"],
            resources: Fixtures.resources,
            sandboxCapable: true
        )
        let decodedCapable = try throughEnvelope(capable)
        #expect(decodedCapable.sandboxCapable == true)
    }

    @Test("Operating system reporting: absent for old builds, carried when reported")
    func agentRegisterOperatingSystem() throws {
        let implicit = AgentRegisterMessage(
            agentId: "agent-1",
            hostname: "hv-01.example",
            version: "1.2.3",
            capabilities: ["kvm"],
            resources: Fixtures.resources
        )
        let decodedImplicit = try throughEnvelope(implicit)
        #expect(decodedImplicit.operatingSystem == nil)

        let reporting = AgentRegisterMessage(
            agentId: "agent-2",
            hostname: "hv-02.example",
            version: "1.2.3",
            capabilities: ["kvm"],
            resources: Fixtures.resources,
            operatingSystem: .linux
        )
        let decodedReporting = try throughEnvelope(reporting)
        #expect(decodedReporting.operatingSystem == .linux)
    }

    @Test("Host info: absent for old builds, carried field-by-field when reported")
    func agentRegisterHostInfo() throws {
        let implicit = AgentRegisterMessage(
            agentId: "agent-1",
            hostname: "hv-01.example",
            version: "1.2.3",
            capabilities: ["kvm"],
            resources: Fixtures.resources
        )
        let decodedImplicit = try throughEnvelope(implicit)
        #expect(decodedImplicit.hostInfo == nil)

        let bootTime = Date(timeIntervalSince1970: 1_700_000_000)
        let hostInfo = HostInfo(
            osName: "Ubuntu 24.04.1 LTS",
            kernelVersion: "6.8.0-45-generic",
            cpuModel: "Intel(R) Xeon(R) Platinum 8375C CPU @ 2.90GHz",
            cpuVendor: "GenuineIntel",
            physicalCoreCount: 8,
            logicalCoreCount: 16,
            totalMemoryBytes: 68_719_476_736,
            machineModel: "PowerEdge R650",
            bootTime: bootTime
        )
        let reporting = AgentRegisterMessage(
            agentId: "agent-2",
            hostname: "hv-02.example",
            version: "1.2.3",
            capabilities: ["kvm"],
            resources: Fixtures.resources,
            hostInfo: hostInfo
        )
        let decoded = try throughEnvelope(reporting)
        #expect(decoded.hostInfo == hostInfo)
        #expect(decoded.hostInfo?.cpuModel == "Intel(R) Xeon(R) Platinum 8375C CPU @ 2.90GHz")
        #expect(decoded.hostInfo?.physicalCoreCount == 8)
        #expect(decoded.hostInfo?.bootTime == bootTime)
    }

    @Test func agentUpdateRoundTrip() throws {
        let message = AgentUpdateMessage(
            requestId: Fixtures.requestId,
            timestamp: Fixtures.timestamp,
            targetVersion: "1.3.0",
            artifactURL:
                "https://github.com/samcat116/strato/releases/download/v1.3.0/strato-linux-x86_64.tar.gz",
            sha256: String(repeating: "ab", count: 32)
        )
        let decoded = try throughEnvelope(message)
        #expect(decoded.type == .agentUpdate)
        #expect(decoded.requestId == message.requestId)
        #expect(decoded.targetVersion == "1.3.0")
        #expect(decoded.artifactURL == message.artifactURL)
        #expect(decoded.sha256 == message.sha256)
        #expect(decoded.artifactKind == .tarball)
        #expect(decoded.tarballMember == "strato-agent")
    }

    @Test("Bare-binary artifact kind survives the wire")
    func agentUpdateBinaryKind() throws {
        let message = AgentUpdateMessage(
            targetVersion: "1.3.0",
            artifactURL: "https://mirror.internal/strato-agent",
            sha256: String(repeating: "0f", count: 32),
            artifactKind: .binary,
            tarballMember: nil
        )
        let decoded = try throughEnvelope(message)
        #expect(decoded.artifactKind == .binary)
        #expect(decoded.tarballMember == nil)
    }

    @Test("Artifact URL redaction strips credentials but keeps the shape")
    func agentUpdateURLRedaction() {
        // Presigned query tokens are credentials.
        #expect(
            AgentUpdateMessage.redactURL(
                "https://cdn.example.com/strato.tar.gz?X-Amz-Signature=secret&X-Amz-Credential=key")
                == "https://cdn.example.com/strato.tar.gz?[redacted]")
        // Userinfo is a credential.
        #expect(
            AgentUpdateMessage.redactURL("https://user:pass@mirror.internal/strato.tar.gz")
                == "https://mirror.internal/strato.tar.gz")
        // Plain URLs pass through unchanged.
        let plain = "https://github.com/samcat116/strato/releases/download/v1.2.3/strato-linux-x86_64.tar.gz"
        #expect(AgentUpdateMessage.redactURL(plain) == plain)
        // Modern Foundation percent-encodes rather than failing to parse, so
        // garbage comes back encoded — the guarantee is only that credentials
        // (query/userinfo) never survive, not that garbage is flagged.
        #expect(!AgentUpdateMessage.redactURL("://tok en@x?secret=1").contains("secret"))
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
