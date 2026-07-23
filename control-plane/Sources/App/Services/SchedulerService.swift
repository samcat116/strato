import Vapor
import Fluent
import NIOConcurrencyHelpers
import StratoShared
import Tracing

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
    /// Site (availability zone) the agent belongs to; nil for site-less agents.
    let siteID: UUID?
    /// Wire protocol version the agent last registered with; nil for unknown
    /// (rows predating the column). Site-pinned placement requires
    /// site-authority support: a pre-v4 agent is kept on legacy per-node
    /// network scoping, so a pinned-network VM placed there would get its
    /// switch in the agent's local NB instead of the site's shared one.
    let wireProtocolVersion: Int?
    /// Whether this agent can run sandbox workloads (issue #415): it
    /// advertised the sandbox runtime at registration AND speaks a wire
    /// protocol that carries sandbox desired state. Callers fold both in —
    /// either alone is insufficient (a v5 build may lack the runtime, and a
    /// capable runtime behind a pre-v5 protocol could never receive the
    /// desired entries).
    let supportsSandboxWorkloads: Bool
    /// Whether this agent can give a guest an emulated TPM 2.0 (issue #565):
    /// it advertised swtpm AND speaks a wire protocol that carries the machine
    /// profile. Same two-signal rule as `supportsSandboxWorkloads`.
    let supportsVTPM: Bool
    /// Whether this agent realizes `VMSpec.machine` at all. Secure Boot needs
    /// only this — no host binary, just a firmware set the agent resolves — so
    /// it is tracked separately from `supportsVTPM`.
    let supportsMachineProfile: Bool

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
        supportsInterVMNetworking: Bool = false,
        siteID: UUID? = nil,
        wireProtocolVersion: Int? = nil,
        supportsSandboxWorkloads: Bool = false,
        supportsVTPM: Bool = false,
        supportsMachineProfile: Bool = false
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
        self.siteID = siteID
        self.wireProtocolVersion = wireProtocolVersion
        self.supportsSandboxWorkloads = supportsSandboxWorkloads
        self.supportsVTPM = supportsVTPM
        self.supportsMachineProfile = supportsMachineProfile
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
        let memoryScore = availableMemory / (1024 * 1024)  // MB
        let diskScore = availableDisk / (1024 * 1024 * 1024)  // GB
        return cpuScore + memoryScore + diskScore
    }

    /// A copy of this agent with `reserved` subtracted from its available
    /// resources (floored at zero). Used to make selection see capacity net of
    /// placements that are in flight but not yet reflected in the agent's own
    /// resource reports.
    func subtractingReservations(_ reserved: ReservationAmounts) -> SchedulableAgent {
        SchedulableAgent(
            id: id,
            name: name,
            totalCPU: totalCPU,
            availableCPU: max(0, availableCPU - reserved.cpu),
            totalMemory: totalMemory,
            availableMemory: max(0, availableMemory - reserved.memory),
            totalDisk: totalDisk,
            availableDisk: max(0, availableDisk - reserved.disk),
            status: status,
            runningVMCount: runningVMCount,
            supportedHypervisors: supportedHypervisors,
            architecture: architecture,
            supportsInterVMNetworking: supportsInterVMNetworking,
            siteID: siteID,
            wireProtocolVersion: wireProtocolVersion,
            supportsSandboxWorkloads: supportsSandboxWorkloads,
            supportsVTPM: supportsVTPM,
            supportsMachineProfile: supportsMachineProfile
        )
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
    /// Site the VM must place into, when one of its networks is pinned to a
    /// site (a pinned network only exists in that site's OVN deployment).
    /// Hard constraint; nil means unconstrained.
    let siteID: UUID?
    /// Whether the workload is a sandbox, which only agents advertising the
    /// sandbox runtime can run (issue #415). Hard constraint — hypervisor
    /// support alone is not enough, since a Firecracker-capable agent may
    /// lack the runtime or the guest base image.
    let requiresSandboxRuntime: Bool
    /// Whether the VM asks for an emulated TPM 2.0 (issue #565). Hard
    /// constraint: only agents with swtpm can realize one, and a guest that
    /// silently loses its TPM fails Windows setup with nothing in the API
    /// explaining why.
    let requiresVTPM: Bool
    /// Whether the VM asks for UEFI Secure Boot. Hard constraint on the wire
    /// protocol only — any agent that understands the machine profile can
    /// resolve a signed firmware set (or fail the create loudly if its host
    /// has none).
    let requiresSecureBoot: Bool

    init(
        cpu: Int,
        memory: Int64,
        disk: Int64,
        hypervisorType: HypervisorType = .qemu,
        architecture: CPUArchitecture? = nil,
        requiresInterVMNetworking: Bool = false,
        siteID: UUID? = nil,
        requiresSandboxRuntime: Bool = false,
        requiresVTPM: Bool = false,
        requiresSecureBoot: Bool = false
    ) {
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.hypervisorType = hypervisorType
        self.architecture = architecture
        self.requiresInterVMNetworking = requiresInterVMNetworking
        self.siteID = siteID
        self.requiresSandboxRuntime = requiresSandboxRuntime
        self.requiresVTPM = requiresVTPM
        self.requiresSecureBoot = requiresSecureBoot
    }
}

/// Scheduler service errors
enum SchedulerError: Error, CustomStringConvertible, Sendable {
    case noAvailableAgents
    case unsupportedHypervisor(required: HypervisorType, onlineAgents: Int, agentsWithoutHypervisors: Int)
    case noUsableHypervisors(onlineAgents: Int)
    case architectureMismatch(required: CPUArchitecture)
    case networkCapabilityUnsatisfied
    case sandboxRuntimeUnsatisfied(eligibleAgents: Int)
    case vtpmUnsatisfied(eligibleAgents: Int)
    case machineProfileUnsatisfied(eligibleAgents: Int)
    case siteUnsatisfied(requiredSiteID: UUID)
    case insufficientResources(required: VMPlacementRequirements, available: [SchedulableAgent])
    case invalidStrategy(String)
    case agentServiceUnavailable

    var description: String {
        switch self {
        case .noAvailableAgents:
            return "No online agents available for VM placement"
        case .unsupportedHypervisor(let required, let onlineAgents, let agentsWithoutHypervisors):
            var message =
                "No online agent supports the \(required.displayName) hypervisor (\(onlineAgents) online agent(s) checked)"
            if agentsWithoutHypervisors > 0 {
                message +=
                    "; \(agentsWithoutHypervisors) of them advertise no usable hypervisor backend at all — check their configured binary paths"
            }
            return message
        case .noUsableHypervisors(let onlineAgents):
            return
                "All \(onlineAgents) online agent(s) advertise no usable hypervisor backend — check each agent's QEMU/Firecracker binary path configuration and its logs"
        case .architectureMismatch(let required):
            return
                "No eligible agent has a \(required.displayName) host architecture (required for hardware-accelerated guests)"
        case .networkCapabilityUnsatisfied:
            return "No eligible agent supports VM-to-VM networking required by this VM"
        case .sandboxRuntimeUnsatisfied(let eligibleAgents):
            return
                "No eligible agent advertises the sandbox runtime (\(eligibleAgents) Firecracker-capable agent(s) checked) — each needs a working Firecracker/KVM setup and the sandbox guest base image installed"
        case .vtpmUnsatisfied(let eligibleAgents):
            return
                "No eligible agent can provide a TPM 2.0 (\(eligibleAgents) agent(s) checked) — install swtpm on a "
                + "hypervisor node (Debian/Ubuntu: `apt install swtpm swtpm-tools`) and let its agent re-register"
        case .machineProfileUnsatisfied(let eligibleAgents):
            return
                "No eligible agent is new enough to realize Secure Boot or a TPM (\(eligibleAgents) agent(s) "
                + "checked) — upgrade the agents on your hypervisor nodes"
        case .siteUnsatisfied(let requiredSiteID):
            return
                "No online agent belongs to site \(requiredSiteID) required by the VM's network pinning"
        case .insufficientResources(let required, let available):
            return
                "No agent has sufficient resources. Required: CPU=\(required.cpu), Memory=\(required.memory), Disk=\(required.disk). Available agents: \(available.count)"
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
        return try selectAgent(
            requirements: Self.placementRequirements(for: vm), from: agents, strategy: strategy, vmName: vm.name)
    }

    /// The placement requirements a VM implies.
    ///
    /// Guest architecture comes from the VM's source image (KVM/HVF are
    /// same-arch only). When no image architecture is available it stays nil
    /// (unconstrained) — the arch hard constraint only engages once the image
    /// carries architecture metadata.
    ///
    /// Inter-VM networking is likewise unconstrained here: every VM gets a
    /// NIC (a MAC is assigned at creation), and a plain NIC is satisfiable
    /// by user-mode/SLIRP agents (outbound NAT). Deriving the requirement
    /// from NIC presence would make every VM unplaceable on macOS dev
    /// agents. It becomes derivable once VMs can express attachment to a
    /// shared/tenant network at creation time.
    static func placementRequirements(
        for vm: VM, architecture: CPUArchitecture? = nil, siteID: UUID? = nil
    ) -> VMPlacementRequirements {
        VMPlacementRequirements(
            cpu: vm.cpu,
            memory: vm.memory,
            disk: vm.disk,
            hypervisorType: vm.hypervisorType,
            architecture: architecture,
            siteID: siteID,
            requiresVTPM: vm.tpmEnabled,
            requiresSecureBoot: vm.secureBoot
        )
    }

    /// Select an agent and atomically reserve the VM's resources on it.
    ///
    /// This closes the read-decide-write placement race (issue #258): plain
    /// `selectAgent` decides on resource numbers that may already be claimed
    /// by a concurrent placement the agent's resource reports don't reflect
    /// yet. Here, each attempt subtracts the coordination store's active
    /// reservations from every agent's availability before selection, then
    /// atomically reserves the candidate's capacity. If the reservation loses
    /// a race (another placement consumed the capacity between the read and
    /// the reserve), selection re-runs with fresh reservation data — the
    /// now-full agent drops out in the resource filter — until placement
    /// succeeds or no agent fits.
    ///
    /// The reservation is released by the caller on send failure or once the
    /// agent starts reporting the VM; its TTL is the backstop.
    func selectAndReserveAgent(
        requirements: VMPlacementRequirements,
        vmId: String,
        from agents: [SchedulableAgent],
        coordination: CoordinationService,
        strategy: SchedulingStrategy? = nil,
        vmName: String = "unnamed"
    ) async throws -> String {
        let amounts = ReservationAmounts(
            cpu: requirements.cpu, memory: requirements.memory, disk: requirements.disk)

        // Each failed attempt means a concurrent reservation landed; with n
        // agents, capacity can be stolen out from under us at most once per
        // agent before the resource filter excludes them all, so a small
        // margin over n bounds the loop without ever cutting a viable retry.
        let maxAttempts = agents.count + 2
        for attempt in 1...max(1, maxAttempts) {
            var adjusted: [SchedulableAgent] = []
            adjusted.reserveCapacity(agents.count)
            for agent in agents {
                let reserved = await coordination.activeReservations(agentId: agent.id)
                adjusted.append(agent.subtractingReservations(reserved))
            }

            let selectedId = try selectAgent(
                requirements: requirements, from: adjusted, strategy: strategy, vmName: vmName)

            // The atomic reserve checks against the agent's *raw* reported
            // availability — the store re-subtracts reservations itself, so
            // passing adjusted numbers would double-count them.
            guard let selectedAgent = agents.first(where: { $0.id == selectedId }) else {
                throw SchedulerError.noAvailableAgents
            }
            let capacity = ReservationAmounts(
                cpu: selectedAgent.availableCPU,
                memory: selectedAgent.availableMemory,
                disk: selectedAgent.availableDisk
            )

            if await coordination.reserveCapacity(
                agentId: selectedId, vmId: vmId, amounts: amounts, capacity: capacity)
            {
                return selectedId
            }

            logger.info(
                "Placement reservation for VM '\(vmName)' on agent '\(selectedAgent.name)' lost a concurrent race; re-running selection (attempt \(attempt))"
            )
        }

        // Every attempt lost its reservation race and no agent had room left.
        throw SchedulerError.insufficientResources(required: requirements, available: agents)
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
        let clock = ContinuousClock()
        let start = clock.now

        // One span per placement decision, nesting under the request span when
        // called on a request path. `outcome`/duration are also emitted as
        // metrics so placement is alertable without traces enabled.
        return try withSpan("scheduler.select_agent", ofKind: .internal) { span in
            span.attributes["scheduler.strategy"] = selectedStrategy.rawValue
            span.attributes["scheduler.candidate_count"] = agents.count
            span.attributes["vm.name"] = vmName
            span.attributes["vm.hypervisor"] = requirements.hypervisorType.rawValue
            do {
                logger.info(
                    "Scheduling VM '\(vmName)' using \(selectedStrategy.rawValue) strategy (hypervisor: \(requirements.hypervisorType.rawValue), arch: \(requirements.architecture?.rawValue ?? "any"))"
                )

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

                logger.info(
                    "Selected agent '\(selectedAgent.name)' for VM '\(vmName)' - CPU: \(selectedAgent.availableCPU)/\(selectedAgent.totalCPU), Memory: \(selectedAgent.availableMemory)/\(selectedAgent.totalMemory), Disk: \(selectedAgent.availableDisk)/\(selectedAgent.totalDisk)"
                )

                span.attributes["scheduler.selected_agent"] = selectedAgent.name
                Telemetry.recordPlacement(
                    strategy: selectedStrategy.rawValue, outcome: "success",
                    durationSeconds: (clock.now - start).asSeconds)
                return selectedAgent.id
            } catch {
                // Every `SchedulerError` is a "no eligible agent" outcome (a
                // constraint or capacity shortfall), distinct from an
                // unexpected fault.
                let outcome = error is SchedulerError ? "no_candidate" : "error"
                span.attributes["scheduler.outcome"] = outcome
                span.recordError(error)
                Telemetry.recordPlacement(
                    strategy: selectedStrategy.rawValue, outcome: outcome,
                    durationSeconds: (clock.now - start).asSeconds)
                throw error
            }
        }
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

        // Site pinning is categorical — a network pinned to a site exists only
        // in that site's OVN deployment, so agents elsewhere (or site-less)
        // can never satisfy it, regardless of capacity. Two further member
        // exclusions: agents that last registered below the site-authority
        // protocol (sync assembly keeps them on legacy per-node scoping, so
        // the VM's switch would land in a private local NB), and agents
        // without overlay networking (user-mode/SLIRP hosts never attach to
        // the site's OVN fabric at all).
        let siteMatched: [SchedulableAgent]
        if let requiredSiteID = requirements.siteID {
            siteMatched = online.filter {
                $0.siteID == requiredSiteID
                    && WireProtocol.supportsSiteAuthority($0.wireProtocolVersion ?? 0)
                    && $0.supportsInterVMNetworking
            }
            guard !siteMatched.isEmpty else {
                throw SchedulerError.siteUnsatisfied(requiredSiteID: requiredSiteID)
            }
        } else {
            siteMatched = online
        }

        let hypervisorCapable = siteMatched.filter { $0.supportedHypervisors.contains(requirements.hypervisorType) }
        guard !hypervisorCapable.isEmpty else {
            // Distinguish a genuine backend mismatch from agents that
            // advertise no hypervisor at all (failed binary probes at
            // registration) so the operator is pointed at the agent's
            // configuration rather than the VM's hypervisor type.
            let agentsWithoutHypervisors = siteMatched.count(where: { $0.supportedHypervisors.isEmpty })
            if agentsWithoutHypervisors == siteMatched.count {
                throw SchedulerError.noUsableHypervisors(onlineAgents: siteMatched.count)
            }
            throw SchedulerError.unsupportedHypervisor(
                required: requirements.hypervisorType,
                onlineAgents: siteMatched.count,
                agentsWithoutHypervisors: agentsWithoutHypervisors
            )
        }

        // Sandboxes additionally need the sandbox runtime, which is advertised
        // explicitly at registration (Firecracker/KVM usable plus the guest
        // base image on disk) — hypervisor support alone doesn't prove it,
        // and neither does the wire protocol version (issue #415).
        let runtimeCapable: [SchedulableAgent]
        if requirements.requiresSandboxRuntime {
            runtimeCapable = hypervisorCapable.filter { $0.supportsSandboxWorkloads }
            guard !runtimeCapable.isEmpty else {
                throw SchedulerError.sandboxRuntimeUnsatisfied(eligibleAgents: hypervisorCapable.count)
            }
        } else {
            runtimeCapable = hypervisorCapable
        }

        // Secure Boot and vTPM both ride `VMSpec.machine`, which only a v17+
        // agent acts on; a vTPM additionally needs swtpm on the host. Both are
        // categorical, and both fail *silently* on an agent that can't serve
        // them — the guest simply boots without the feature — so placement is
        // refused rather than degraded (issue #565).
        var machineCapable = runtimeCapable
        if requirements.requiresVTPM || requirements.requiresSecureBoot {
            let profileCapable = machineCapable.filter { $0.supportsMachineProfile }
            guard !profileCapable.isEmpty else {
                throw SchedulerError.machineProfileUnsatisfied(eligibleAgents: machineCapable.count)
            }
            machineCapable = profileCapable
        }
        if requirements.requiresVTPM {
            let tpmCapable = machineCapable.filter { $0.supportsVTPM }
            guard !tpmCapable.isEmpty else {
                throw SchedulerError.vtpmUnsatisfied(eligibleAgents: machineCapable.count)
            }
            machineCapable = tpmCapable
        }

        // An agent with unknown architecture cannot prove it satisfies an
        // explicit architecture requirement, so it is excluded.
        let architectureMatched: [SchedulableAgent]
        if let requiredArchitecture = requirements.architecture {
            architectureMatched = machineCapable.filter { $0.architecture == requiredArchitecture }
            guard !architectureMatched.isEmpty else {
                throw SchedulerError.architectureMismatch(required: requiredArchitecture)
            }
        } else {
            architectureMatched = machineCapable
        }

        let networkCapable =
            requirements.requiresInterVMNetworking
            ? architectureMatched.filter { $0.supportsInterVMNetworking }
            : architectureMatched
        guard !networkCapable.isEmpty else {
            throw SchedulerError.networkCapabilityUnsatisfied
        }

        let eligible = networkCapable.filter { agent in
            agent.availableCPU >= requirements.cpu && agent.availableMemory >= requirements.memory
                && agent.availableDisk >= requirements.disk
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
        logger.debug(
            "BestFit selected agent '\(selected.name)' with remaining capacity score: \(selected.remainingCapacity)")
        return selected
    }

    /// Least-loaded strategy: Spread VMs across agents with most available resources
    /// This balances load and provides better performance isolation
    private func selectLeastLoaded(from agents: [SchedulableAgent]) throws -> SchedulableAgent {
        guard let selected = agents.min(by: { $0.overallUtilization < $1.overallUtilization }) else {
            throw SchedulerError.noAvailableAgents
        }
        logger.debug(
            "LeastLoaded selected agent '\(selected.name)' with utilization: \(String(format: "%.2f%%", selected.overallUtilization * 100))"
        )
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
