import Testing
import Vapor
import Fluent
import FluentSQLiteDriver
@testable import App

@Suite("Scheduler Service Tests")
final class SchedulerServiceTests {

    // MARK: - Test Helpers

    /// Create a test VM with specified resource requirements
    private func createTestVM(
        id: UUID = UUID(),
        name: String = "test-vm",
        cpu: Int = 2,
        memory: Int64 = 4 * 1024 * 1024 * 1024, // 4GB
        disk: Int64 = 50 * 1024 * 1024 * 1024 // 50GB
    ) -> VM {
        let vm = VM(
            name: name,
            description: "Test VM",
            imageName: "ubuntu-22.04",
            cpu: cpu,
            memory: memory,
            disk: disk,
            projectId: UUID()
        )
        vm.id = id
        return vm
    }

    /// Create a test schedulable agent with specified resources
    private func createTestAgent(
        id: String,
        totalCPU: Int = 16,
        availableCPU: Int = 12,
        totalMemory: Int64 = 32 * 1024 * 1024 * 1024, // 32GB
        availableMemory: Int64 = 24 * 1024 * 1024 * 1024, // 24GB
        totalDisk: Int64 = 500 * 1024 * 1024 * 1024, // 500GB
        availableDisk: Int64 = 400 * 1024 * 1024 * 1024, // 400GB
        status: Agent.Status = .online,
        runningVMCount: Int = 4
    ) -> SchedulableAgent {
        return SchedulableAgent(
            id: id,
            name: id,
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

    // MARK: - Least Loaded Strategy Tests

    @Test("Least Loaded: Selects agent with lowest utilization")
    func testLeastLoadedSelectsLowestUtilization() async throws {
        let app = try await Application.makeForTesting()
        defer { Task { try await app.asyncShutdown() } }

        let scheduler = SchedulerService(logger: app.logger, defaultStrategy: .leastLoaded)

        // Create agents with different utilization levels
        let agents = [
            createTestAgent(id: "agent-1", availableCPU: 8, availableMemory: 16 * GB), // 50% CPU, 50% memory
            createTestAgent(id: "agent-2", availableCPU: 12, availableMemory: 24 * GB), // 25% CPU, 25% memory (LEAST LOADED)
            createTestAgent(id: "agent-3", availableCPU: 4, availableMemory: 8 * GB), // 75% CPU, 75% memory
        ]

        let vm = createTestVM(cpu: 2, memory: 4 * GB, disk: 50 * GB)
        let selectedId = try scheduler.selectAgent(for: vm, from: agents)

        #expect(selectedId == "agent-2", "Should select agent with lowest utilization")
    }

    @Test("Least Loaded: Handles agents with equal utilization")
    func testLeastLoadedWithEqualUtilization() async throws {
        let app = try await Application.makeForTesting()
        defer { Task { try await app.asyncShutdown() } }

        let scheduler = SchedulerService(logger: app.logger, defaultStrategy: .leastLoaded)

        // Create agents with identical utilization
        let agents = [
            createTestAgent(id: "agent-1", availableCPU: 8, availableMemory: 16 * GB),
            createTestAgent(id: "agent-2", availableCPU: 8, availableMemory: 16 * GB),
        ]

        let vm = createTestVM(cpu: 2, memory: 4 * GB, disk: 50 * GB)
        let selectedId = try scheduler.selectAgent(for: vm, from: agents)

        // Should select one of them (deterministic based on min algorithm)
        #expect(agents.contains(where: { $0.id == selectedId }), "Should select one of the agents")
    }

    // MARK: - Best Fit Strategy Tests

    @Test("Best Fit: Selects agent with least remaining capacity")
    func testBestFitSelectsLeastRemainingCapacity() async throws {
        let app = try await Application.makeForTesting()
        defer { Task { try await app.asyncShutdown() } }

        let scheduler = SchedulerService(logger: app.logger, defaultStrategy: .bestFit)

        // Create agents with different remaining capacities
        let agents = [
            createTestAgent(id: "agent-1", availableCPU: 12, availableMemory: 24 * GB, availableDisk: 400 * GB), // High remaining
            createTestAgent(id: "agent-2", availableCPU: 4, availableMemory: 8 * GB, availableDisk: 100 * GB), // Low remaining (BEST FIT)
            createTestAgent(id: "agent-3", availableCPU: 8, availableMemory: 16 * GB, availableDisk: 250 * GB), // Medium remaining
        ]

        let vm = createTestVM(cpu: 2, memory: 4 * GB, disk: 50 * GB)
        let selectedId = try scheduler.selectAgent(for: vm, from: agents)

        #expect(selectedId == "agent-2", "Should select agent with least remaining capacity")
    }

    @Test("Best Fit: Packs VMs efficiently")
    func testBestFitPackingBehavior() async throws {
        let app = try await Application.makeForTesting()
        defer { Task { try await app.asyncShutdown() } }

        let scheduler = SchedulerService(logger: app.logger, defaultStrategy: .bestFit)

        // Agent with just enough resources
        let agents = [
            createTestAgent(id: "agent-1", availableCPU: 16, availableMemory: 32 * GB), // Plenty of space
            createTestAgent(id: "agent-2", availableCPU: 2, availableMemory: 4 * GB), // Just enough (BEST FIT)
        ]

        let vm = createTestVM(cpu: 2, memory: 4 * GB, disk: 50 * GB)
        let selectedId = try scheduler.selectAgent(for: vm, from: agents)

        #expect(selectedId == "agent-2", "Should pack VM into agent with least remaining space")
    }

    // MARK: - Round Robin Strategy Tests

    @Test("Round Robin: Distributes VMs evenly")
    func testRoundRobinDistribution() async throws {
        let app = try await Application.makeForTesting()
        defer { Task { try await app.asyncShutdown() } }

        let scheduler = SchedulerService(logger: app.logger, defaultStrategy: .roundRobin)

        let agents = [
            createTestAgent(id: "agent-1"),
            createTestAgent(id: "agent-2"),
            createTestAgent(id: "agent-3"),
        ]

        // Schedule 6 VMs and verify round-robin distribution
        var selections: [String] = []
        for i in 0..<6 {
            let vm = createTestVM(name: "vm-\(i)")
            let selectedId = try scheduler.selectAgent(for: vm, from: agents)
            selections.append(selectedId)
        }

        // Should cycle through agents: 1, 2, 3, 1, 2, 3
        #expect(selections[0] == "agent-1", "First VM should go to agent-1")
        #expect(selections[1] == "agent-2", "Second VM should go to agent-2")
        #expect(selections[2] == "agent-3", "Third VM should go to agent-3")
        #expect(selections[3] == "agent-1", "Fourth VM should cycle back to agent-1")
        #expect(selections[4] == "agent-2", "Fifth VM should go to agent-2")
        #expect(selections[5] == "agent-3", "Sixth VM should go to agent-3")
    }

    @Test("Round Robin: Handles single agent")
    func testRoundRobinSingleAgent() async throws {
        let app = try await Application.makeForTesting()
        defer { Task { try await app.asyncShutdown() } }

        let scheduler = SchedulerService(logger: app.logger, defaultStrategy: .roundRobin)

        let agents = [createTestAgent(id: "agent-1")]

        // Schedule multiple VMs on single agent
        for i in 0..<3 {
            let vm = createTestVM(name: "vm-\(i)")
            let selectedId = try scheduler.selectAgent(for: vm, from: agents)
            #expect(selectedId == "agent-1", "All VMs should go to the only agent")
        }
    }

    // MARK: - Random Strategy Tests

    @Test("Random: Selects from available agents")
    func testRandomSelectsAvailableAgent() async throws {
        let app = try await Application.makeForTesting()
        defer { Task { try await app.asyncShutdown() } }

        let scheduler = SchedulerService(logger: app.logger, defaultStrategy: .random)

        let agents = [
            createTestAgent(id: "agent-1"),
            createTestAgent(id: "agent-2"),
            createTestAgent(id: "agent-3"),
        ]

        let vm = createTestVM()
        let selectedId = try scheduler.selectAgent(for: vm, from: agents)

        #expect(agents.contains(where: { $0.id == selectedId }), "Should select one of the available agents")
    }

    @Test("Random: Distributes across multiple agents over time")
    func testRandomDistribution() async throws {
        let app = try await Application.makeForTesting()
        defer { Task { try await app.asyncShutdown() } }

        let scheduler = SchedulerService(logger: app.logger, defaultStrategy: .random)

        let agents = [
            createTestAgent(id: "agent-1"),
            createTestAgent(id: "agent-2"),
            createTestAgent(id: "agent-3"),
        ]

        // Schedule many VMs and verify they're distributed (not all on same agent)
        var selections: Set<String> = []
        for i in 0..<20 {
            let vm = createTestVM(name: "vm-\(i)")
            let selectedId = try scheduler.selectAgent(for: vm, from: agents)
            selections.insert(selectedId)
        }

        // With 20 VMs and 3 agents, we should hit multiple agents (not all 3 guaranteed due to randomness)
        #expect(selections.count >= 2, "Random strategy should distribute across at least 2 agents over 20 VMs")
    }

    // MARK: - Resource Filtering Tests

    @Test("Filters out agents with insufficient CPU")
    func testFiltersInsufficientCPU() async throws {
        let app = try await Application.makeForTesting()
        defer { Task { try await app.asyncShutdown() } }

        let scheduler = SchedulerService(logger: app.logger, defaultStrategy: .leastLoaded)

        let agents = [
            createTestAgent(id: "agent-1", availableCPU: 1), // Not enough CPU
            createTestAgent(id: "agent-2", availableCPU: 4), // Enough CPU
        ]

        let vm = createTestVM(cpu: 2, memory: 4 * GB, disk: 50 * GB)
        let selectedId = try scheduler.selectAgent(for: vm, from: agents)

        #expect(selectedId == "agent-2", "Should only select agent with sufficient CPU")
    }

    @Test("Filters out agents with insufficient memory")
    func testFiltersInsufficientMemory() async throws {
        let app = try await Application.makeForTesting()
        defer { Task { try await app.asyncShutdown() } }

        let scheduler = SchedulerService(logger: app.logger, defaultStrategy: .leastLoaded)

        let agents = [
            createTestAgent(id: "agent-1", availableMemory: 2 * GB), // Not enough memory
            createTestAgent(id: "agent-2", availableMemory: 8 * GB), // Enough memory
        ]

        let vm = createTestVM(cpu: 2, memory: 4 * GB, disk: 50 * GB)
        let selectedId = try scheduler.selectAgent(for: vm, from: agents)

        #expect(selectedId == "agent-2", "Should only select agent with sufficient memory")
    }

    @Test("Filters out agents with insufficient disk")
    func testFiltersInsufficientDisk() async throws {
        let app = try await Application.makeForTesting()
        defer { Task { try await app.asyncShutdown() } }

        let scheduler = SchedulerService(logger: app.logger, defaultStrategy: .leastLoaded)

        let agents = [
            createTestAgent(id: "agent-1", availableDisk: 20 * GB), // Not enough disk
            createTestAgent(id: "agent-2", availableDisk: 100 * GB), // Enough disk
        ]

        let vm = createTestVM(cpu: 2, memory: 4 * GB, disk: 50 * GB)
        let selectedId = try scheduler.selectAgent(for: vm, from: agents)

        #expect(selectedId == "agent-2", "Should only select agent with sufficient disk")
    }

    @Test("Filters out offline agents")
    func testFiltersOfflineAgents() async throws {
        let app = try await Application.makeForTesting()
        defer { Task { try await app.asyncShutdown() } }

        let scheduler = SchedulerService(logger: app.logger, defaultStrategy: .leastLoaded)

        let agents = [
            createTestAgent(id: "agent-1", status: .offline),
            createTestAgent(id: "agent-2", status: .online),
        ]

        let vm = createTestVM(cpu: 2, memory: 4 * GB, disk: 50 * GB)
        let selectedId = try scheduler.selectAgent(for: vm, from: agents)

        #expect(selectedId == "agent-2", "Should only select online agents")
    }

    // MARK: - Error Handling Tests

    @Test("Throws error when no agents available")
    func testNoAgentsError() async throws {
        let app = try await Application.makeForTesting()
        defer { Task { try await app.asyncShutdown() } }

        let scheduler = SchedulerService(logger: app.logger, defaultStrategy: .leastLoaded)

        let agents: [SchedulableAgent] = []
        let vm = createTestVM()

        #expect(throws: SchedulerError.self) {
            try scheduler.selectAgent(for: vm, from: agents)
        }
    }

    @Test("Throws error when no agents have sufficient resources")
    func testInsufficientResourcesError() async throws {
        let app = try await Application.makeForTesting()
        defer { Task { try await app.asyncShutdown() } }

        let scheduler = SchedulerService(logger: app.logger, defaultStrategy: .leastLoaded)

        // All agents have insufficient resources
        let agents = [
            createTestAgent(id: "agent-1", availableCPU: 1, availableMemory: 2 * GB),
            createTestAgent(id: "agent-2", availableCPU: 1, availableMemory: 2 * GB),
        ]

        let vm = createTestVM(cpu: 4, memory: 8 * GB, disk: 50 * GB)

        #expect(throws: SchedulerError.self) {
            try scheduler.selectAgent(for: vm, from: agents)
        }
    }

    @Test("Throws error when all agents are offline")
    func testAllAgentsOfflineError() async throws {
        let app = try await Application.makeForTesting()
        defer { Task { try await app.asyncShutdown() } }

        let scheduler = SchedulerService(logger: app.logger, defaultStrategy: .leastLoaded)

        let agents = [
            createTestAgent(id: "agent-1", status: .offline),
            createTestAgent(id: "agent-2", status: .error),
        ]

        let vm = createTestVM()

        #expect(throws: SchedulerError.self) {
            try scheduler.selectAgent(for: vm, from: agents)
        }
    }

    // MARK: - Strategy Override Tests

    @Test("Strategy override works correctly")
    func testStrategyOverride() async throws {
        let app = try await Application.makeForTesting()
        defer { Task { try await app.asyncShutdown() } }

        // Create scheduler with least_loaded default
        let scheduler = SchedulerService(logger: app.logger, defaultStrategy: .leastLoaded)

        let agents = [
            createTestAgent(id: "agent-1", availableCPU: 4, availableMemory: 8 * GB), // Less remaining (best fit)
            createTestAgent(id: "agent-2", availableCPU: 12, availableMemory: 24 * GB), // More remaining (least loaded)
        ]

        let vm = createTestVM(cpu: 2, memory: 4 * GB, disk: 50 * GB)

        // Without override, should use least_loaded
        let leastLoadedId = try scheduler.selectAgent(for: vm, from: agents)
        #expect(leastLoadedId == "agent-2", "Default strategy should select least loaded")

        // With override to best_fit, should select differently
        let bestFitId = try scheduler.selectAgent(for: vm, from: agents, strategy: .bestFit)
        #expect(bestFitId == "agent-1", "Override strategy should select best fit")
    }

    // MARK: - Edge Cases

    @Test("Handles VM with zero resources")
    func testZeroResourceVM() async throws {
        let app = try await Application.makeForTesting()
        defer { Task { try await app.asyncShutdown() } }

        let scheduler = SchedulerService(logger: app.logger, defaultStrategy: .leastLoaded)

        let agents = [createTestAgent(id: "agent-1")]
        let vm = createTestVM(cpu: 0, memory: 0, disk: 0)

        let selectedId = try scheduler.selectAgent(for: vm, from: agents)
        #expect(selectedId == "agent-1", "Should handle VM with zero resources")
    }

    @Test("Handles agent with zero available resources but exact match")
    func testExactResourceMatch() async throws {
        let app = try await Application.makeForTesting()
        defer { Task { try await app.asyncShutdown() } }

        let scheduler = SchedulerService(logger: app.logger, defaultStrategy: .leastLoaded)

        // Agent with exactly the resources needed
        let agents = [
            createTestAgent(id: "agent-1", availableCPU: 2, availableMemory: 4 * GB, availableDisk: 50 * GB),
        ]

        let vm = createTestVM(cpu: 2, memory: 4 * GB, disk: 50 * GB)
        let selectedId = try scheduler.selectAgent(for: vm, from: agents)

        #expect(selectedId == "agent-1", "Should select agent with exact resource match")
    }

    @Test("Utilization calculations are correct")
    func testUtilizationCalculations() async throws {
        let agent = createTestAgent(
            id: "test-agent",
            totalCPU: 16,
            availableCPU: 8, // 50% used
            totalMemory: 32 * GB,
            availableMemory: 16 * GB, // 50% used
            totalDisk: 1000 * GB,
            availableDisk: 500 * GB // 50% used
        )

        #expect(agent.cpuUtilization == 0.5, "CPU utilization should be 50%")
        #expect(agent.memoryUtilization == 0.5, "Memory utilization should be 50%")
        #expect(agent.diskUtilization == 0.5, "Disk utilization should be 50%")

        // Overall: (0.5 * 0.4) + (0.5 * 0.4) + (0.5 * 0.2) = 0.5
        #expect(agent.overallUtilization == 0.5, "Overall utilization should be 50%")
    }
}

// MARK: - Test Constants

private let GB: Int64 = 1024 * 1024 * 1024
