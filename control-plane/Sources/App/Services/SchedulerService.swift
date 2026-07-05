import Vapor
import Fluent
import NIOConcurrencyHelpers
import StratoShared

/// Scheduling strategy for VM placement
enum SchedulingStrategy: String, Codable, Sendable {
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
struct SchedulableAgent: Sendable {
    let id: String
    let name: String
    let totalCPU: Int
    let availableCPU: Int
    let totalMemory: Int64
    let availableMemory: Int64
    let totalDisk: Int64
    let availableDisk: Int64
    let status: AgentStatus
    let runningVMCount: Int
    /// Hypervisor backends this agent can actually run (from its registered capabilities)
    let supportedHypervisors: [HypervisorType]
    /// Host CPU architecture; nil for agents that predate architecture reporting
    let architecture: CPUArchitecture?
    /// Whether the agent's networking backend supports VM-to-VM traffic
    /// (OVN/OVS). User-mode (SLIRP) agents cannot satisfy inter-VM networking.
    let supportsInterVMNetworking: Bool

    init(
        id: String,
        name: String,
        totalCPU: Int,
        availableCPU: Int,
        totalMemory: Int64,
        availableMemory: Int64,
        totalDisk: Int64,
        availableDisk: Int64,
        status: AgentStatus,
        runningVMCount: Int,
        supportedHypervisors: [HypervisorType] = [.qemu],
        architecture: CPUArchitecture? = nil,
        supportsInterVMNetworking: Bool = false
    ) {
        self.id = id
        self.name = name
        self.totalCPU = totalCPU
        self.availableCPU = availableCPU
        self.totalMemory = totalMemory
        self.availableMemory = availableMemory
        self.totalDisk = totalDisk
        self.availableDisk = availableDisk
        self.status = status
        self.runningVMCount = runningVMCount
        self.supportedHypervisors = supportedHypervisors
        self.architecture = architecture
        self.supportsInterVMNetworking = supportsInterVMNetworking
    }

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

/// VM placement requirements for scheduling: hard constraints (hypervisor
/// backend, architecture, network capability) plus resource needs.
struct VMPlacementRequirements: Sendable {
    let cpu: Int
    let memory: Int64
    let disk: Int64
    /// Hypervisor backend the VM must run under. Hard constraint — agents
    /// that don't support it are never eligible.
    let hypervisorType: HypervisorType
    /// Guest CPU architecture, when known. KVM/HVF acceleration is same-arch
    /// only, so when set, only agents with a matching (known) host
    /// architecture are eligible. Nil means unconstrained (no image
    /// architecture metadata yet).
    let architecture: CPUArchitecture?
    /// Whether the VM needs VM-to-VM networking, which user-mode (SLIRP)
    /// agents cannot provide.
    let requiresInterVMNetworking: Bool

    init(
        cpu: Int,
        memory: Int64,
        disk: Int64,
        hypervisorType: HypervisorType = .qemu,
        architecture: CPUArchitecture? = nil,
        requiresInterVMNetworking: Bool = false
    ) {
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.hypervisorType = hypervisorType
        self.architecture = architecture
        self.requiresInterVMNetworking = requiresInterVMNetworking
    }
}

/// Scheduler service errors
enum SchedulerError: Error, CustomStringConvertible, Sendable {
    case noAvailableAgents
    case unsupportedHypervisor(required: HypervisorType, onlineAgents: Int, agentsWithoutHypervisors: Int)
    case noUsableHypervisors(onlineAgents: Int)
    case architectureMismatch(required: CPUArchitecture)
    case networkCapabilityUnsatisfied
    case insufficientResources(required: VMPlacementRequirements, available: [SchedulableAgent])
    case invalidStrategy(String)
    case agentServiceUnavailable

    var description: String {
        switch self {
        case .noAvailableAgents:
            return "No online agents available for VM placement"
        case .unsupportedHypervisor(let required, let onlineAgents, let agentsWithoutHypervisors):
            var message = "No online agent supports the \(required.displayName) hypervisor (\(onlineAgents) online agent(s) checked)"
            if agentsWithoutHypervisors > 0 {
                message += "; \(agentsWithoutHypervisors) of them advertise no usable hypervisor backend at all — check their configured binary paths"
            }
            return message
        case .noUsableHypervisors(let onlineAgents):
            return "All \(onlineAgents) online agent(s) advertise no usable hypervisor backend — check each agent's QEMU/Firecracker binary path configuration and its logs"
        case .architectureMismatch(let required):
            return "No eligible agent has a \(required.displayName) host architecture (required for hardware-accelerated guests)"
        case .networkCapabilityUnsatisfied:
            return "No eligible agent supports VM-to-VM networking required by this VM"
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
final class SchedulerService: @unchecked Sendable {
    private let logger: Logger
    private let defaultStrategy: SchedulingStrategy
    private let lock: NIOLock
    private var roundRobinCounter: Int

    init(logger: Logger, defaultStrategy: SchedulingStrategy = .leastLoaded) {
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
    func selectAgent(
        for vm: VM,
        from agents: [SchedulableAgent],
        strategy: SchedulingStrategy? = nil
    ) throws -> String {
        // Guest architecture is unconstrained until images carry architecture
        // metadata; once VMs can derive it, the arch hard constraint below
        // applies automatically.
        //
        // Inter-VM networking is likewise unconstrained here: every VM gets a
        // NIC (a MAC is assigned at creation), and a plain NIC is satisfiable
        // by user-mode/SLIRP agents (outbound NAT). Deriving the requirement
        // from NIC presence would make every VM unplaceable on macOS dev
        // agents. It becomes derivable once VMs can express attachment to a
        // shared/tenant network at creation time.
        let requirements = VMPlacementRequirements(
            cpu: vm.cpu,
            memory: vm.memory,
            disk: vm.disk,
            hypervisorType: vm.hypervisorType
        )

        return try selectAgent(requirements: requirements, from: agents, strategy: strategy, vmName: vm.name)
    }

    /// Select an agent for a set of placement requirements. Hard constraints
    /// (hypervisor support, architecture, network capability) are applied
    /// before resource filtering, and each stage that eliminates all
    /// candidates throws its own error so placement failures say why.
    func selectAgent(
        requirements: VMPlacementRequirements,
        from agents: [SchedulableAgent],
        strategy: SchedulingStrategy? = nil,
        vmName: String = "unnamed"
    ) throws -> String {
        let selectedStrategy = strategy ?? defaultStrategy

        logger.info("Scheduling VM '\(vmName)' using \(selectedStrategy.rawValue) strategy (hypervisor: \(requirements.hypervisorType.rawValue), arch: \(requirements.architecture?.rawValue ?? "any"))")

        let eligibleAgents = try filterEligibleAgents(agents, for: requirements)

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

        logger.info("Selected agent '\(selectedAgent.name)' for VM '\(vmName)' - CPU: \(selectedAgent.availableCPU)/\(selectedAgent.totalCPU), Memory: \(selectedAgent.availableMemory)/\(selectedAgent.totalMemory), Disk: \(selectedAgent.availableDisk)/\(selectedAgent.totalDisk)")

        return selectedAgent.id
    }

    // MARK: - Private Scheduling Algorithms

    /// Filter agents through the placement constraints, most fundamental
    /// first. Throws a stage-specific error when a stage leaves no candidates,
    /// so a Firecracker VM on a QEMU-only fleet fails with "unsupported
    /// hypervisor" rather than a generic resource error.
    private func filterEligibleAgents(
        _ agents: [SchedulableAgent],
        for requirements: VMPlacementRequirements
    ) throws -> [SchedulableAgent] {
        let online = agents.filter { $0.status == AgentStatus.online }
        guard !online.isEmpty else {
            throw SchedulerError.noAvailableAgents
        }

        let hypervisorCapable = online.filter { $0.supportedHypervisors.contains(requirements.hypervisorType) }
        guard !hypervisorCapable.isEmpty else {
            // Distinguish a genuine backend mismatch from agents that
            // advertise no hypervisor at all (failed binary probes at
            // registration) so the operator is pointed at the agent's
            // configuration rather than the VM's hypervisor type.
            let agentsWithoutHypervisors = online.count(where: { $0.supportedHypervisors.isEmpty })
            if agentsWithoutHypervisors == online.count {
                throw SchedulerError.noUsableHypervisors(onlineAgents: online.count)
            }
            throw SchedulerError.unsupportedHypervisor(
                required: requirements.hypervisorType,
                onlineAgents: online.count,
                agentsWithoutHypervisors: agentsWithoutHypervisors
            )
        }

        // An agent with unknown architecture cannot prove it satisfies an
        // explicit architecture requirement, so it is excluded.
        let architectureMatched: [SchedulableAgent]
        if let requiredArchitecture = requirements.architecture {
            architectureMatched = hypervisorCapable.filter { $0.architecture == requiredArchitecture }
            guard !architectureMatched.isEmpty else {
                throw SchedulerError.architectureMismatch(required: requiredArchitecture)
            }
        } else {
            architectureMatched = hypervisorCapable
        }

        let networkCapable = requirements.requiresInterVMNetworking
            ? architectureMatched.filter { $0.supportsInterVMNetworking }
            : architectureMatched
        guard !networkCapable.isEmpty else {
            throw SchedulerError.networkCapabilityUnsatisfied
        }

        let eligible = networkCapable.filter { agent in
            agent.availableCPU >= requirements.cpu &&
            agent.availableMemory >= requirements.memory &&
            agent.availableDisk >= requirements.disk
        }
        guard !eligible.isEmpty else {
            throw SchedulerError.insufficientResources(required: requirements, available: networkCapable)
        }

        return eligible
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
        roundRobinCounter += 1
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
    func getSchedulingInfo(for agentId: String, in agents: [SchedulableAgent]) -> String? {
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
    struct SchedulerServiceKey: StorageKey {
        typealias Value = SchedulerService
    }

    /// The configured scheduler service.
    ///
    /// Throws rather than calling `fatalError` if accessed before `configure`
    /// installed it: this getter is reachable from request handling, so a missing
    /// service should surface as a request error, not crash the process. Install
    /// it with `useScheduler(_:)` during boot.
    var scheduler: SchedulerService {
        get throws {
            guard let scheduler = self.storage[SchedulerServiceKey.self] else {
                throw Abort(
                    .internalServerError,
                    reason: "SchedulerService not configured. Call app.useScheduler(...) in configure.swift"
                )
            }
            return scheduler
        }
    }

    /// Install the scheduler service during application configuration.
    func useScheduler(_ scheduler: SchedulerService) {
        self.storage[SchedulerServiceKey.self] = scheduler
    }
}

extension Request {
    var scheduler: SchedulerService {
        get throws { try self.application.scheduler }
    }
}
