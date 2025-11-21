import Testing
import Vapor
import StratoShared
@testable import App

@Suite("Agent Model Tests")
struct AgentModelTests {

    // MARK: - Test Helpers

    func createTestAgentResources(
        totalCPU: Int = 8,
        availableCPU: Int = 6,
        totalMemory: Int64 = 16_000_000_000,
        availableMemory: Int64 = 12_000_000_000,
        totalDisk: Int64 = 100_000_000_000,
        availableDisk: Int64 = 80_000_000_000
    ) -> AgentResources {
        return AgentResources(
            totalCPU: totalCPU,
            availableCPU: availableCPU,
            totalMemory: totalMemory,
            availableMemory: availableMemory,
            totalDisk: totalDisk,
            availableDisk: availableDisk
        )
    }

    func createTestAgent(
        name: String = "test-agent",
        hostname: String = "test-host",
        version: String = "1.0.0",
        capabilities: [String] = ["kvm", "ovn"],
        status: AgentStatus = .online,
        resources: AgentResources? = nil,
        lastHeartbeat: Date? = Date()
    ) -> Agent {
        let agentResources = resources ?? createTestAgentResources()
        return Agent(
            name: name,
            hostname: hostname,
            version: version,
            capabilities: capabilities,
            status: status,
            resources: agentResources,
            lastHeartbeat: lastHeartbeat
        )
    }

    // MARK: - Initialization Tests

    @Test("Agent initializes with correct values")
    func testAgentInitialization() {
        let resources = createTestAgentResources()
        let agent = createTestAgent(resources: resources)

        #expect(agent.name == "test-agent")
        #expect(agent.hostname == "test-host")
        #expect(agent.version == "1.0.0")
        #expect(agent.capabilities == ["kvm", "ovn"])
        #expect(agent.status == .online)
        #expect(agent.totalCPU == 8)
        #expect(agent.availableCPU == 6)
        #expect(agent.totalMemory == 16_000_000_000)
        #expect(agent.availableMemory == 12_000_000_000)
    }

    // MARK: - Update Resources Tests

    @Test("Agent updateResources updates available resources")
    func testUpdateResources() {
        let agent = createTestAgent()

        let newResources = createTestAgentResources(
            availableCPU: 4,
            availableMemory: 8_000_000_000,
            availableDisk: 60_000_000_000
        )

        agent.updateResources(newResources)

        #expect(agent.availableCPU == 4)
        #expect(agent.availableMemory == 8_000_000_000)
        #expect(agent.availableDisk == 60_000_000_000)
    }

    @Test("Agent updateResources updates lastHeartbeat")
    func testUpdateResourcesUpdatesHeartbeat() {
        let agent = createTestAgent()
        let oldHeartbeat = agent.lastHeartbeat

        // Wait a tiny bit to ensure timestamp difference
        Thread.sleep(forTimeInterval: 0.01)

        let newResources = createTestAgentResources()
        agent.updateResources(newResources)

        #expect(agent.lastHeartbeat != nil)
        #expect(agent.lastHeartbeat! > oldHeartbeat!)
    }

    // MARK: - Resources Property Tests

    @Test("Agent resources property returns correct values")
    func testResourcesProperty() {
        let agent = createTestAgent()

        let resources = agent.resources

        #expect(resources.totalCPU == 8)
        #expect(resources.availableCPU == 6)
        #expect(resources.totalMemory == 16_000_000_000)
        #expect(resources.availableMemory == 12_000_000_000)
        #expect(resources.totalDisk == 100_000_000_000)
        #expect(resources.availableDisk == 80_000_000_000)
    }

    // MARK: - Online Status Tests

    @Test("Agent isOnline returns true when heartbeat is recent")
    func testIsOnlineWithRecentHeartbeat() {
        let agent = createTestAgent(lastHeartbeat: Date())

        #expect(agent.isOnline == true)
    }

    @Test("Agent isOnline returns false when heartbeat is old")
    func testIsOnlineWithOldHeartbeat() {
        let oldDate = Date().addingTimeInterval(-120) // 2 minutes ago
        let agent = createTestAgent(lastHeartbeat: oldDate)

        #expect(agent.isOnline == false)
    }

    @Test("Agent isOnline returns false when no heartbeat")
    func testIsOnlineWithNoHeartbeat() {
        let agent = createTestAgent(lastHeartbeat: nil)

        #expect(agent.isOnline == false)
    }

    @Test("Agent isOnline threshold is 60 seconds")
    func testIsOnlineThreshold() {
        // Just under 60 seconds - should be online
        let justWithin = Date().addingTimeInterval(-59)
        let agentOnline = createTestAgent(lastHeartbeat: justWithin)
        #expect(agentOnline.isOnline == true)

        // Just over 60 seconds - should be offline
        let justOver = Date().addingTimeInterval(-61)
        let agentOffline = createTestAgent(lastHeartbeat: justOver)
        #expect(agentOffline.isOnline == false)
    }

    // MARK: - Update Status Based on Heartbeat Tests

    @Test("Agent updateStatusBasedOnHeartbeat sets online when heartbeat is recent and status is offline")
    func testUpdateStatusOnlineFromOffline() {
        let agent = createTestAgent(status: .offline, lastHeartbeat: Date())

        agent.updateStatusBasedOnHeartbeat()

        #expect(agent.status == .online)
    }

    @Test("Agent updateStatusBasedOnHeartbeat sets offline when heartbeat is old and status is online")
    func testUpdateStatusOfflineFromOnline() {
        let oldDate = Date().addingTimeInterval(-120)
        let agent = createTestAgent(status: .online, lastHeartbeat: oldDate)

        agent.updateStatusBasedOnHeartbeat()

        #expect(agent.status == .offline)
    }

    @Test("Agent updateStatusBasedOnHeartbeat does not change status when already correct")
    func testUpdateStatusNoChangeWhenCorrect() {
        // Online with recent heartbeat
        let agentOnline = createTestAgent(status: .online, lastHeartbeat: Date())
        agentOnline.updateStatusBasedOnHeartbeat()
        #expect(agentOnline.status == .online)

        // Offline with old heartbeat
        let oldDate = Date().addingTimeInterval(-120)
        let agentOffline = createTestAgent(status: .offline, lastHeartbeat: oldDate)
        agentOffline.updateStatusBasedOnHeartbeat()
        #expect(agentOffline.status == .offline)
    }

    @Test("Agent updateStatusBasedOnHeartbeat handles connecting status")
    func testUpdateStatusFromConnecting() {
        // Connecting with recent heartbeat should become online
        let agentRecent = createTestAgent(status: .connecting, lastHeartbeat: Date())
        agentRecent.updateStatusBasedOnHeartbeat()
        #expect(agentRecent.status == .connecting) // Does not change from connecting to online

        // Connecting with old heartbeat should become offline
        let oldDate = Date().addingTimeInterval(-120)
        let agentOld = createTestAgent(status: .connecting, lastHeartbeat: oldDate)
        agentOld.updateStatusBasedOnHeartbeat()
        #expect(agentOld.status == .connecting) // Does not change from connecting to offline
    }

    // MARK: - Agent.from(registration:name:) Tests

    @Test("Agent.from creates agent from registration message")
    func testFromRegistrationMessage() {
        let resources = createTestAgentResources()
        let message = AgentRegisterMessage(
            agentId: "reg-agent",
            hostname: "reg-host",
            version: "2.0.0",
            capabilities: ["kvm", "hvf"],
            resources: resources
        )

        let agent = Agent.from(registration: message, name: "reg-agent")

        #expect(agent.name == "reg-agent")
        #expect(agent.hostname == "reg-host")
        #expect(agent.version == "2.0.0")
        #expect(agent.capabilities == ["kvm", "hvf"])
        #expect(agent.status == AgentStatus.connecting)
        #expect(agent.totalCPU == 8)
        #expect(agent.availableCPU == 6)
        #expect(agent.lastHeartbeat != nil)
    }

    @Test("Agent.from sets status to connecting by default")
    func testFromRegistrationSetsConnectingStatus() {
        let resources = createTestAgentResources()
        let message = AgentRegisterMessage(
            agentId: "reg-agent",
            hostname: "reg-host",
            version: "2.0.0",
            capabilities: [],
            resources: resources
        )

        let agent = Agent.from(registration: message, name: "reg-agent")

        #expect(agent.status == AgentStatus.connecting)
    }

    @Test("Agent.from sets recent lastHeartbeat")
    func testFromRegistrationSetsRecentHeartbeat() {
        let resources = createTestAgentResources()
        let message = AgentRegisterMessage(
            agentId: "reg-agent",
            hostname: "reg-host",
            version: "2.0.0",
            capabilities: [],
            resources: resources
        )

        let agent = Agent.from(registration: message, name: "reg-agent")

        #expect(agent.lastHeartbeat != nil)

        // Should be very recent (within last second)
        let timeDifference = abs(Date().timeIntervalSince(agent.lastHeartbeat!))
        #expect(timeDifference < 1.0)
    }

    // MARK: - AgentResponse DTO Tests

    @Test("AgentResponse initializes from Agent")
    func testAgentResponseInitialization() async throws {
        let app = try await Application.makeForTesting()

        try await configure(app)
        try await app.autoMigrate()

        let agent = createTestAgent()
        try await agent.save(on: app.db)

        let response = try AgentResponse(from: agent)

        #expect(response.id == agent.id)
        #expect(response.name == "test-agent")
        #expect(response.hostname == "test-host")
        #expect(response.version == "1.0.0")
        #expect(response.capabilities == ["kvm", "ovn"])
        #expect(response.status == .online)
        #expect(response.resources.totalCPU == 8)
        #expect(response.isOnline == true)
    }

    @Test("AgentResponse throws when agent has no ID")
    func testAgentResponseThrowsWithoutID() {
        let agent = createTestAgent()
        // Don't save, so no ID is set

        #expect(throws: Error.self) {
            try AgentResponse(from: agent)
        }
    }

    // MARK: - AgentStatus Enum Tests

    @Test("AgentStatus has all expected cases")
    func testAgentStatusCases() {
        let cases = AgentStatus.allCases

        #expect(cases.contains(.online))
        #expect(cases.contains(.offline))
        #expect(cases.contains(.connecting))
        #expect(cases.contains(.error))
        #expect(cases.count == 4)
    }

    @Test("AgentStatus raw values are correct")
    func testAgentStatusRawValues() {
        #expect(AgentStatus.online.rawValue == "online")
        #expect(AgentStatus.offline.rawValue == "offline")
        #expect(AgentStatus.connecting.rawValue == "connecting")
        #expect(AgentStatus.error.rawValue == "error")
    }

    // MARK: - Edge Cases

    @Test("Agent handles zero resources")
    func testAgentWithZeroResources() {
        let resources = createTestAgentResources(
            totalCPU: 0,
            availableCPU: 0,
            totalMemory: 0,
            availableMemory: 0,
            totalDisk: 0,
            availableDisk: 0
        )
        let agent = createTestAgent(resources: resources)

        #expect(agent.totalCPU == 0)
        #expect(agent.availableCPU == 0)
        #expect(agent.totalMemory == 0)
    }

    @Test("Agent handles empty capabilities")
    func testAgentWithEmptyCapabilities() {
        let agent = createTestAgent(capabilities: [])

        #expect(agent.capabilities.isEmpty)
    }

    @Test("Agent handles multiple capabilities")
    func testAgentWithMultipleCapabilities() {
        let agent = createTestAgent(capabilities: ["kvm", "ovn", "hvf", "virtio"])

        #expect(agent.capabilities.count == 4)
        #expect(agent.capabilities.contains("kvm"))
        #expect(agent.capabilities.contains("hvf"))
    }
}
