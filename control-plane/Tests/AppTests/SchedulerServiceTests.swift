import Testing
import Vapor
@testable import App

@Suite("SchedulerService Tests", .serialized)
struct SchedulerServiceTests {

    // MARK: - Test Data Helpers

    func createTestVM(cpu: Int = 2, memory: Int64 = 2048, disk: Int64 = 20000) -> VM {
        return VM(
            name: "test-vm",
            description: "Test VM",
            image: "test-image",
            projectID: UUID(),
            environment: "test",
            cpu: cpu,
            memory: memory,
            disk: disk
        )
    }

    func createTestAgent(
        id: String = "test-agent",
        name: String = "test-agent",
        totalCPU: Int = 8,
        availableCPU: Int = 6,
        totalMemory: Int64 = 16000,
        availableMemory: Int64 = 12000,
        totalDisk: Int64 = 100000,
        availableDisk: Int64 = 80000,
        status: AgentStatus = .online,
        runningVMCount: Int = 0
    ) -> SchedulableAgent {
        return SchedulableAgent(
            id: id,
            name: name,
            totalCPU: totalCPU,
            availableCPU: availableCPU,
            totalMemory: totalMemory,
            availableMemory: availableMemory,
            totalDisk: totalDisk,
            availableDisk: availableDisk,
            status: status,
            runningVMCount: runningVMCount
        )
    }

    // MARK: - Resource Utilization Tests

    @Test("SchedulableAgent calculates CPU utilization correctly")
    func testCPUUtilization() throws {
        let agent = createTestAgent(totalCPU: 8, availableCPU: 6)
        #expect(agent.cpuUtilization == 0.25) // (8-6)/8 = 0.25

        let fullyUtilized = createTestAgent(totalCPU: 8, availableCPU: 0)
        #expect(fullyUtilized.cpuUtilization == 1.0)

        let unused = createTestAgent(totalCPU: 8, availableCPU: 8)
        #expect(unused.cpuUtilization == 0.0)
    }

    @Test("SchedulableAgent calculates memory utilization correctly")
    func testMemoryUtilization() throws {
        let agent = createTestAgent(totalMemory: 16000, availableMemory: 12000)
        #expect(agent.memoryUtilization == 0.25) // (16000-12000)/16000 = 0.25

        let fullyUtilized = createTestAgent(totalMemory: 16000, availableMemory: 0)
        #expect(fullyUtilized.memoryUtilization == 1.0)
    }

    @Test("SchedulableAgent calculates disk utilization correctly")
    func testDiskUtilization() throws {
        let agent = createTestAgent(totalDisk: 100000, availableDisk: 80000)
        #expect(agent.diskUtilization == 0.2) // (100000-80000)/100000 = 0.2
    }

    @Test("SchedulableAgent calculates overall utilization correctly")
    func testOverallUtilization() throws {
        let agent = createTestAgent(
            totalCPU: 8, availableCPU: 6,        // 25% utilization
            totalMemory: 16000, availableMemory: 12000,  // 25% utilization
            totalDisk: 100000, availableDisk: 80000      // 20% utilization
        )
        // Overall = (0.25 * 0.4) + (0.25 * 0.4) + (0.2 * 0.2) = 0.1 + 0.1 + 0.04 = 0.24
        let expected = 0.24
        #expect(abs(agent.overallUtilization - expected) < 0.001)
    }

    // MARK: - Least Loaded Strategy Tests

    @Test("Least loaded strategy selects agent with lowest utilization")
    func testLeastLoadedStrategy() throws {
        let logger = Logger(label: "test")
        let scheduler = SchedulerService(logger: logger, defaultStrategy: .leastLoaded)

        let agents = [
            createTestAgent(id: "agent1", name: "agent1", availableCPU: 2), // 75% CPU util
            createTestAgent(id: "agent2", name: "agent2", availableCPU: 6), // 25% CPU util - should be selected
            createTestAgent(id: "agent3", name: "agent3", availableCPU: 4)  // 50% CPU util
        ]

        let vm = createTestVM(cpu: 2, memory: 2000, disk: 10000)
        let selectedId = try scheduler.selectAgent(for: vm, from: agents)

        #expect(selectedId == "agent2")
    }

    @Test("Least loaded strategy with default strategy")
    func testLeastLoadedDefaultStrategy() throws {
        let logger = Logger(label: "test")
        let scheduler = SchedulerService(logger: logger) // defaults to leastLoaded

        let agents = [
            createTestAgent(id: "agent1", name: "agent1", totalMemory: 16000, availableMemory: 4000),  // 75% mem
            createTestAgent(id: "agent2", name: "agent2", totalMemory: 16000, availableMemory: 14000)  // 12.5% mem
        ]

        let vm = createTestVM(cpu: 1, memory: 2000, disk: 10000)
        let selectedId = try scheduler.selectAgent(for: vm, from: agents)

        #expect(selectedId == "agent2")
    }

    // MARK: - Best Fit Strategy Tests

    @Test("Best fit strategy selects agent with least remaining capacity")
    func testBestFitStrategy() throws {
        let logger = Logger(label: "test")
        let scheduler = SchedulerService(logger: logger, defaultStrategy: .bestFit)

        let agents = [
            createTestAgent(id: "agent1", name: "agent1", availableCPU: 6, availableMemory: 12000, availableDisk: 80000),
            createTestAgent(id: "agent2", name: "agent2", availableCPU: 2, availableMemory: 4000, availableDisk: 20000), // Least capacity - should be selected
            createTestAgent(id: "agent3", name: "agent3", availableCPU: 4, availableMemory: 8000, availableDisk: 50000)
        ]

        let vm = createTestVM(cpu: 1, memory: 2000, disk: 10000)
        let selectedId = try scheduler.selectAgent(for: vm, from: agents, strategy: .bestFit)

        #expect(selectedId == "agent2")
    }

    // MARK: - Round Robin Strategy Tests

    @Test("Round robin strategy distributes VMs evenly")
    func testRoundRobinStrategy() throws {
        let logger = Logger(label: "test")
        let scheduler = SchedulerService(logger: logger, defaultStrategy: .roundRobin)

        let agents = [
            createTestAgent(id: "agent1", name: "agent1"),
            createTestAgent(id: "agent2", name: "agent2"),
            createTestAgent(id: "agent3", name: "agent3")
        ]

        let vm = createTestVM(cpu: 1, memory: 1000, disk: 10000)

        // Should cycle through agents
        let first = try scheduler.selectAgent(for: vm, from: agents)
        let second = try scheduler.selectAgent(for: vm, from: agents)
        let third = try scheduler.selectAgent(for: vm, from: agents)
        let fourth = try scheduler.selectAgent(for: vm, from: agents)

        #expect(first == "agent1")
        #expect(second == "agent2")
        #expect(third == "agent3")
        #expect(fourth == "agent1") // Wraps around
    }

    // MARK: - Random Strategy Tests

    @Test("Random strategy selects from eligible agents")
    func testRandomStrategy() throws {
        let logger = Logger(label: "test")
        let scheduler = SchedulerService(logger: logger, defaultStrategy: .random)

        let agents = [
            createTestAgent(id: "agent1", name: "agent1"),
            createTestAgent(id: "agent2", name: "agent2")
        ]

        let vm = createTestVM(cpu: 1, memory: 1000, disk: 10000)
        let selectedId = try scheduler.selectAgent(for: vm, from: agents, strategy: .random)

        // Should select one of the agents
        #expect(selectedId == "agent1" || selectedId == "agent2")
    }

    // MARK: - Resource Filtering Tests

    @Test("Scheduler filters out offline agents")
    func testFiltersOfflineAgents() throws {
        let logger = Logger(label: "test")
        let scheduler = SchedulerService(logger: logger)

        let agents = [
            createTestAgent(id: "agent1", name: "agent1", status: .offline),
            createTestAgent(id: "agent2", name: "agent2", status: .online)
        ]

        let vm = createTestVM(cpu: 1, memory: 1000, disk: 10000)
        let selectedId = try scheduler.selectAgent(for: vm, from: agents)

        #expect(selectedId == "agent2")
    }

    @Test("Scheduler filters out agents with insufficient CPU")
    func testFiltersInsufficientCPU() throws {
        let logger = Logger(label: "test")
        let scheduler = SchedulerService(logger: logger)

        let agents = [
            createTestAgent(id: "agent1", name: "agent1", availableCPU: 1),  // Not enough
            createTestAgent(id: "agent2", name: "agent2", availableCPU: 4)   // Enough
        ]

        let vm = createTestVM(cpu: 2, memory: 1000, disk: 10000)
        let selectedId = try scheduler.selectAgent(for: vm, from: agents)

        #expect(selectedId == "agent2")
    }

    @Test("Scheduler filters out agents with insufficient memory")
    func testFiltersInsufficientMemory() throws {
        let logger = Logger(label: "test")
        let scheduler = SchedulerService(logger: logger)

        let agents = [
            createTestAgent(id: "agent1", name: "agent1", availableMemory: 1000),  // Not enough
            createTestAgent(id: "agent2", name: "agent2", availableMemory: 10000)  // Enough
        ]

        let vm = createTestVM(cpu: 1, memory: 5000, disk: 10000)
        let selectedId = try scheduler.selectAgent(for: vm, from: agents)

        #expect(selectedId == "agent2")
    }

    @Test("Scheduler filters out agents with insufficient disk")
    func testFiltersInsufficientDisk() throws {
        let logger = Logger(label: "test")
        let scheduler = SchedulerService(logger: logger)

        let agents = [
            createTestAgent(id: "agent1", name: "agent1", availableDisk: 5000),   // Not enough
            createTestAgent(id: "agent2", name: "agent2", availableDisk: 50000)   // Enough
        ]

        let vm = createTestVM(cpu: 1, memory: 1000, disk: 20000)
        let selectedId = try scheduler.selectAgent(for: vm, from: agents)

        #expect(selectedId == "agent2")
    }

    // MARK: - Error Handling Tests

    @Test("Scheduler throws error when no agents available")
    func testNoAgentsAvailable() throws {
        let logger = Logger(label: "test")
        let scheduler = SchedulerService(logger: logger)

        let agents: [SchedulableAgent] = []
        let vm = createTestVM()

        #expect(throws: SchedulerError.self) {
            try scheduler.selectAgent(for: vm, from: agents)
        }
    }

    @Test("Scheduler throws error when no agents have sufficient resources")
    func testInsufficientResources() throws {
        let logger = Logger(label: "test")
        let scheduler = SchedulerService(logger: logger)

        let agents = [
            createTestAgent(id: "agent1", name: "agent1", availableCPU: 1, availableMemory: 500, availableDisk: 5000)
        ]

        let vm = createTestVM(cpu: 4, memory: 8000, disk: 50000) // Requires more than available

        #expect(throws: SchedulerError.self) {
            try scheduler.selectAgent(for: vm, from: agents)
        }
    }

    @Test("Scheduler throws error when all agents are offline")
    func testAllAgentsOffline() throws {
        let logger = Logger(label: "test")
        let scheduler = SchedulerService(logger: logger)

        let agents = [
            createTestAgent(id: "agent1", name: "agent1", status: .offline),
            createTestAgent(id: "agent2", name: "agent2", status: .offline)
        ]

        let vm = createTestVM()

        #expect(throws: SchedulerError.self) {
            try scheduler.selectAgent(for: vm, from: agents)
        }
    }

    // MARK: - Strategy Override Tests

    @Test("Strategy can be overridden per request")
    func testStrategyOverride() throws {
        let logger = Logger(label: "test")
        let scheduler = SchedulerService(logger: logger, defaultStrategy: .leastLoaded)

        let agents = [
            createTestAgent(id: "agent1", name: "agent1", availableCPU: 2),  // Higher utilization
            createTestAgent(id: "agent2", name: "agent2", availableCPU: 6)   // Lower utilization
        ]

        let vm = createTestVM(cpu: 1, memory: 1000, disk: 10000)

        // Default strategy (least loaded) should select agent2
        let defaultSelection = try scheduler.selectAgent(for: vm, from: agents)
        #expect(defaultSelection == "agent2")

        // Override with best fit (should select agent with least capacity = agent1)
        let overrideSelection = try scheduler.selectAgent(for: vm, from: agents, strategy: .bestFit)
        #expect(overrideSelection == "agent1")
    }

    // MARK: - Edge Cases

    @Test("Scheduler handles agent with zero total resources")
    func testZeroTotalResources() throws {
        let logger = Logger(label: "test")
        let scheduler = SchedulerService(logger: logger)

        let agents = [
            createTestAgent(id: "agent1", name: "agent1", totalCPU: 0, availableCPU: 0),
            createTestAgent(id: "agent2", name: "agent2", totalCPU: 8, availableCPU: 6)
        ]

        let vm = createTestVM(cpu: 1, memory: 1000, disk: 10000)
        let selectedId = try scheduler.selectAgent(for: vm, from: agents)

        // Should select agent2 since agent1 has no resources
        #expect(selectedId == "agent2")
    }

    @Test("Scheduler handles exact resource match")
    func testExactResourceMatch() throws {
        let logger = Logger(label: "test")
        let scheduler = SchedulerService(logger: logger)

        let agents = [
            createTestAgent(id: "agent1", name: "agent1", availableCPU: 2, availableMemory: 2048, availableDisk: 20000)
        ]

        let vm = createTestVM(cpu: 2, memory: 2048, disk: 20000)
        let selectedId = try scheduler.selectAgent(for: vm, from: agents)

        #expect(selectedId == "agent1")
    }

    // MARK: - Utility Method Tests

    @Test("getSchedulingInfo returns formatted information")
    func testGetSchedulingInfo() throws {
        let logger = Logger(label: "test")
        let scheduler = SchedulerService(logger: logger)

        let agents = [
            createTestAgent(
                id: "agent1",
                name: "test-agent",
                totalCPU: 8,
                availableCPU: 6,
                totalMemory: 16_000_000_000,
                availableMemory: 12_000_000_000,
                totalDisk: 100_000_000_000,
                availableDisk: 80_000_000_000,
                status: .online,
                runningVMCount: 3
            )
        ]

        let info = scheduler.getSchedulingInfo(for: "agent1", in: agents)

        #expect(info != nil)
        #expect(info!.contains("test-agent"))
        #expect(info!.contains("online"))
        #expect(info!.contains("6/8"))
        #expect(info!.contains("Running VMs: 3"))
    }

    @Test("getSchedulingInfo returns nil for unknown agent")
    func testGetSchedulingInfoUnknownAgent() throws {
        let logger = Logger(label: "test")
        let scheduler = SchedulerService(logger: logger)

        let agents = [
            createTestAgent(id: "agent1", name: "agent1")
        ]

        let info = scheduler.getSchedulingInfo(for: "unknown", in: agents)

        #expect(info == nil)
    }
}
