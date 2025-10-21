import Vapor
import Fluent
import NIOConcurrencyHelpers

/// Scheduling strategy for VM placement
public enum SchedulingStrategy: String, Codable {
    /// Pack VMs onto agents with least remaining capacity (bin-packing)
    case bestFit = "best_fit"

    /// Spread VMs across agents with most available resources (load balancing)
    case leastLoaded = "least_loaded"

    /// Distribute VMs evenly in round-robin fashion
    case roundRobin = "round_robin"

    /// Random selection from available agents
    case random = "random"
}

/// Represents an agent with its current resource availability
public struct SchedulableAgent {
    let id: String
    let name: String
    let totalCPU: Int
    let availableCPU: Int
    let totalMemory: Int64
    let availableMemory: Int64
    let totalDisk: Int64
    let availableDisk: Int64
    let status: Agent.Status
    let runningVMCount: Int

    /// Calculate resource utilization percentage (0.0 to 1.0)
    var cpuUtilization: Double {
        guard totalCPU > 0 else { return 0.0 }
        return Double(totalCPU - availableCPU) / Double(totalCPU)
    }

    var memoryUtilization: Double {
        guard totalMemory > 0 else { return 0.0 }
        return Double(totalMemory - availableMemory) / Double(totalMemory)
    }

    var diskUtilization: Double {
        guard totalDisk > 0 else { return 0.0 }
        return Double(totalDisk - availableDisk) / Double(totalDisk)
    }

    /// Combined utilization score (weighted average)
    var overallUtilization: Double {
        return (cpuUtilization * 0.4) + (memoryUtilization * 0.4) + (diskUtilization * 0.2)
    }

    /// Remaining capacity score (lower means less capacity)
    var remainingCapacity: Int64 {
        // Normalize to common scale and sum
        let cpuScore = Int64(availableCPU) * 1000
        let memoryScore = availableMemory / (1024 * 1024) // MB
        let diskScore = availableDisk / (1024 * 1024 * 1024) // GB
        return cpuScore + memoryScore + diskScore
    }
}

/// VM resource requirements for scheduling
public struct VMResourceRequirements {
    let cpu: Int
    let memory: Int64
    let disk: Int64
}

/// Scheduler service errors
public enum SchedulerError: Error, CustomStringConvertible {
    case noAvailableAgents
    case insufficientResources(required: VMResourceRequirements, available: [SchedulableAgent])
    case invalidStrategy(String)
    case agentServiceUnavailable

    public var description: String {
        switch self {
        case .noAvailableAgents:
            return "No online agents available for VM placement"
        case .insufficientResources(let required, let available):
            return "No agent has sufficient resources. Required: CPU=\(required.cpu), Memory=\(required.memory), Disk=\(required.disk). Available agents: \(available.count)"
        case .invalidStrategy(let strategy):
            return "Invalid scheduling strategy: \(strategy)"
        case .agentServiceUnavailable:
            return "Agent service is not available"
        }
    }
}

/// Service responsible for scheduling VM placement decisions
public final class SchedulerService {
    private let logger: Logger
    private let defaultStrategy: SchedulingStrategy
    private let lock: NIOLock
    private var roundRobinCounter: Int

    public init(logger: Logger, defaultStrategy: SchedulingStrategy = .leastLoaded) {
        self.logger = logger
        self.defaultStrategy = defaultStrategy
        self.lock = NIOLock()
        self.roundRobinCounter = 0
    }

    /// Select an agent for VM placement using the configured strategy
    /// - Parameters:
    ///   - vm: The VM to schedule
    ///   - agents: List of available agents with current resource info
    ///   - strategy: Optional strategy override (defaults to service default)
    /// - Returns: The ID of the selected agent
    /// - Throws: SchedulerError if no suitable agent is found
    public func selectAgent(
        for vm: VM,
        from agents: [SchedulableAgent],
        strategy: SchedulingStrategy? = nil
    ) throws -> String {
        let selectedStrategy = strategy ?? defaultStrategy

        logger.info("Scheduling VM '\(vm.name)' using \(selectedStrategy.rawValue) strategy")

        let requirements = VMResourceRequirements(
            cpu: vm.cpu,
            memory: vm.memory,
            disk: vm.disk
        )

        // Filter to only online agents with sufficient resources
        let eligibleAgents = filterEligibleAgents(agents, for: requirements)

        guard !eligibleAgents.isEmpty else {
            if agents.isEmpty {
                throw SchedulerError.noAvailableAgents
            } else {
                throw SchedulerError.insufficientResources(required: requirements, available: agents)
            }
        }

        // Apply scheduling strategy
        let selectedAgent: SchedulableAgent
        switch selectedStrategy {
        case .bestFit:
            selectedAgent = try selectBestFit(from: eligibleAgents)
        case .leastLoaded:
            selectedAgent = try selectLeastLoaded(from: eligibleAgents)
        case .roundRobin:
            selectedAgent = try selectRoundRobin(from: eligibleAgents)
        case .random:
            selectedAgent = try selectRandom(from: eligibleAgents)
        }

        logger.info("Selected agent '\(selectedAgent.name)' for VM '\(vm.name)' - CPU: \(selectedAgent.availableCPU)/\(selectedAgent.totalCPU), Memory: \(selectedAgent.availableMemory)/\(selectedAgent.totalMemory), Disk: \(selectedAgent.availableDisk)/\(selectedAgent.totalDisk)")

        return selectedAgent.id
    }

    // MARK: - Private Scheduling Algorithms

    /// Filter agents to those online and with sufficient resources
    private func filterEligibleAgents(
        _ agents: [SchedulableAgent],
        for requirements: VMResourceRequirements
    ) -> [SchedulableAgent] {
        return agents.filter { agent in
            agent.status == .online &&
            agent.availableCPU >= requirements.cpu &&
            agent.availableMemory >= requirements.memory &&
            agent.availableDisk >= requirements.disk
        }
    }

    /// Best-fit strategy: Pack VMs onto agents with least remaining capacity
    /// This minimizes fragmentation and maximizes resource utilization
    private func selectBestFit(from agents: [SchedulableAgent]) throws -> SchedulableAgent {
        guard let selected = agents.min(by: { $0.remainingCapacity < $1.remainingCapacity }) else {
            throw SchedulerError.noAvailableAgents
        }
        logger.debug("BestFit selected agent '\(selected.name)' with remaining capacity score: \(selected.remainingCapacity)")
        return selected
    }

    /// Least-loaded strategy: Spread VMs across agents with most available resources
    /// This balances load and provides better performance isolation
    private func selectLeastLoaded(from agents: [SchedulableAgent]) throws -> SchedulableAgent {
        guard let selected = agents.min(by: { $0.overallUtilization < $1.overallUtilization }) else {
            throw SchedulerError.noAvailableAgents
        }
        logger.debug("LeastLoaded selected agent '\(selected.name)' with utilization: \(String(format: "%.2f%%", selected.overallUtilization * 100))")
        return selected
    }

    /// Round-robin strategy: Distribute VMs evenly across agents
    /// Simple and fair distribution
    private func selectRoundRobin(from agents: [SchedulableAgent]) throws -> SchedulableAgent {
        guard !agents.isEmpty else {
            throw SchedulerError.noAvailableAgents
        }

        // Thread-safe increment and wrap
        lock.lock()
        let index = roundRobinCounter % agents.count
        roundRobinCounter = (roundRobinCounter + 1) % Int.max
        lock.unlock()

        let selected = agents[index]
        logger.debug("RoundRobin selected agent '\(selected.name)' (index: \(index)/\(agents.count))")
        return selected
    }

    /// Random strategy: Randomly select from available agents
    /// Useful for testing or when no specific policy is needed
    private func selectRandom(from agents: [SchedulableAgent]) throws -> SchedulableAgent {
        guard let selected = agents.randomElement() else {
            throw SchedulerError.noAvailableAgents
        }
        logger.debug("Random selected agent '\(selected.name)'")
        return selected
    }

    // MARK: - Utility Methods

    /// Get a human-readable description of scheduling decision
    public func getSchedulingInfo(for agentId: String, in agents: [SchedulableAgent]) -> String? {
        guard let agent = agents.first(where: { $0.id == agentId }) else {
            return nil
        }

        return """
            Agent: \(agent.name)
            Status: \(agent.status)
            CPU: \(agent.availableCPU)/\(agent.totalCPU) (\(String(format: "%.1f%%", agent.cpuUtilization * 100)) used)
            Memory: \(formatBytes(agent.availableMemory))/\(formatBytes(agent.totalMemory)) (\(String(format: "%.1f%%", agent.memoryUtilization * 100)) used)
            Disk: \(formatBytes(agent.availableDisk))/\(formatBytes(agent.totalDisk)) (\(String(format: "%.1f%%", agent.diskUtilization * 100)) used)
            Running VMs: \(agent.runningVMCount)
            """
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        return String(format: "%.1f GB", gb)
    }
}

// MARK: - Application Extension

extension Application {
    public struct SchedulerServiceKey: StorageKey {
        public typealias Value = SchedulerService
    }

    public var scheduler: SchedulerService {
        get {
            guard let scheduler = self.storage[SchedulerServiceKey.self] else {
                fatalError("SchedulerService not configured. Call app.scheduler = SchedulerService(...) in configure.swift")
            }
            return scheduler
        }
        set {
            self.storage[SchedulerServiceKey.self] = newValue
        }
    }
}

extension Request {
    public var scheduler: SchedulerService {
        return self.application.scheduler
    }
}
