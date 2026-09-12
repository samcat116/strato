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
    let physicalFreeDisk: Int64
    let status: AgentStatus
    let runningVMCount: Int
    /// Hypervisor backends this agent can actually run, from its structured registration report.
    let supportedHypervisors: [HypervisorType]
    /// Host CPU architecture; nil for agents that predate architecture reporting
    let architecture: CPUArchitecture?
    /// Whether the agent's networking backend supports VM-to-VM traffic
    /// (OVN/OVS). User-mode (SLIRP) agents cannot satisfy inter-VM networking.
    let supportsInterVMNetworking: Bool
    /// Whether the agent initialized its guest-facing metadata listener
    /// supervisor. Overlay networking alone does not imply this capability.
    let supportsMetadataService: Bool
    let siteID: UUID
    /// Whether this agent can run sandbox workloads (issue #415): it
    /// advertised the sandbox runtime at registration.
    let supportsSandboxWorkloads: Bool
    /// Whether this agent can realize a **sandbox NIC** (STR-103): it
    /// advertised OVN, the jailer barrier, and a guest image that configures
    /// the interface. Strictly stronger than `supportsSandboxWorkloads` — a
    /// host with only that runs network-free sandboxes and nothing else.
    let supportsSandboxNetworking: Bool
    /// Whether this agent can give a guest an emulated TPM 2.0 (issue #565):
    /// it advertised swtpm at registration.
    let supportsVTPM: Bool
    /// Whether this agent's QEMU backend can attach a host-backed
    /// virtio-vsock device for the Strato guest agent.
    let supportsVsock: Bool

    init(
        id: String,
        name: String,
        totalCPU: Int,
        availableCPU: Int,
        totalMemory: Int64,
        availableMemory: Int64,
        totalDisk: Int64,
        availableDisk: Int64,
        physicalFreeDisk: Int64? = nil,
        status: AgentStatus,
        runningVMCount: Int,
        supportedHypervisors: [HypervisorType] = [.qemu],
        architecture: CPUArchitecture? = nil,
        supportsInterVMNetworking: Bool = false,
        supportsMetadataService: Bool = false,
        siteID: UUID,
        supportsSandboxWorkloads: Bool = false,
        supportsSandboxNetworking: Bool = false,
        supportsVTPM: Bool = false,
        supportsVsock: Bool = false
    ) {
        self.id = id
        self.name = name
        self.totalCPU = totalCPU
        self.availableCPU = availableCPU
        self.totalMemory = totalMemory
        self.availableMemory = availableMemory
        self.totalDisk = totalDisk
        self.availableDisk = availableDisk
        self.physicalFreeDisk = physicalFreeDisk ?? availableDisk
        self.status = status
        self.runningVMCount = runningVMCount
        self.supportedHypervisors = supportedHypervisors
        self.architecture = architecture
        self.supportsInterVMNetworking = supportsInterVMNetworking
        self.supportsMetadataService = supportsMetadataService
        self.siteID = siteID
        self.supportsSandboxWorkloads = supportsSandboxWorkloads
        self.supportsSandboxNetworking = supportsSandboxNetworking
        self.supportsVTPM = supportsVTPM
        self.supportsVsock = supportsVsock
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
        let diskScore = availableDisk / (1024 * 1024 * 1024)  // GiB
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
            physicalFreeDisk: physicalFreeDisk,
            status: status,
            runningVMCount: runningVMCount,
            supportedHypervisors: supportedHypervisors,
            architecture: architecture,
            supportsInterVMNetworking: supportsInterVMNetworking,
            supportsMetadataService: supportsMetadataService,
            siteID: siteID,
            supportsSandboxWorkloads: supportsSandboxWorkloads,
            supportsSandboxNetworking: supportsSandboxNetworking,
            supportsVTPM: supportsVTPM,
            supportsVsock: supportsVsock
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
    /// Whether the VM's first-boot seed must fetch from the guest-facing
    /// metadata service. Independent from the overlay-networking requirement.
    let requiresMetadataService: Bool
    /// Site the VM must place into, when one of its networks is pinned to a
    /// site (a pinned network only exists in that site's OVN deployment).
    /// Hard constraint; nil means unconstrained.
    let siteID: UUID?
    /// Whether the workload is a sandbox, which only agents advertising the
    /// sandbox runtime can run (issue #415). Hard constraint — hypervisor
    /// support alone is not enough, since a Firecracker-capable agent may
    /// lack the runtime or the guest base image.
    let requiresSandboxRuntime: Bool
    /// Whether the sandbox has a NIC, which only agents advertising sandbox
    /// networking can realize (STR-103). Hard constraint, and refusal is the
    /// deliberate choice over the alternative: an agent without it boots the
    /// sandbox with no interface at all while the API keeps reporting the
    /// address IPAM allocated, and a workload that is silently unreachable is
    /// worse than one that never started.
    let requiresSandboxNetworking: Bool
    /// Whether the VM asks for an emulated TPM 2.0 (issue #565). Hard
    /// constraint: only agents with swtpm can realize one, and a guest that
    /// silently loses its TPM fails Windows setup with nothing in the API
    /// explaining why.
    let requiresVTPM: Bool
    /// Whether the VM enables the Strato guest agent and therefore requires
    /// a host-backed virtio-vsock device. Hard constraint: without it the VM
    /// cannot start.
    let requiresVsock: Bool
    init(
        cpu: Int,
        memory: Int64,
        disk: Int64,
        hypervisorType: HypervisorType = .qemu,
        architecture: CPUArchitecture? = nil,
        requiresInterVMNetworking: Bool = false,
        requiresMetadataService: Bool = false,
        siteID: UUID? = nil,
        requiresSandboxRuntime: Bool = false,
        requiresSandboxNetworking: Bool = false,
        requiresVTPM: Bool = false,
        requiresVsock: Bool = false
    ) {
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.hypervisorType = hypervisorType
        self.architecture = architecture
        self.requiresInterVMNetworking = requiresInterVMNetworking
        self.requiresMetadataService = requiresMetadataService
        self.siteID = siteID
        self.requiresSandboxRuntime = requiresSandboxRuntime
        self.requiresSandboxNetworking = requiresSandboxNetworking
        self.requiresVTPM = requiresVTPM
        self.requiresVsock = requiresVsock
    }
}

/// Scheduler service errors
enum SchedulerError: Error, CustomStringConvertible, Sendable {
    case noAvailableAgents
    case unsupportedHypervisor(required: HypervisorType, onlineAgents: Int, agentsWithoutHypervisors: Int)
    case noUsableHypervisors(onlineAgents: Int)
    case architectureMismatch(required: CPUArchitecture)
    case networkCapabilityUnsatisfied
    case metadataServiceUnsatisfied(eligibleAgents: Int)
    case sandboxRuntimeUnsatisfied(eligibleAgents: Int)
    case sandboxNetworkingUnsatisfied(eligibleAgents: Int)
    case vtpmUnsatisfied(eligibleAgents: Int)
    case vsockUnsatisfied(eligibleAgents: Int)
    case siteUnsatisfied(requiredSiteID: UUID)
    case insufficientResources(required: VMPlacementRequirements, available: [SchedulableAgent])

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
        case .metadataServiceUnsatisfied(let eligibleAgents):
            return
                "No eligible agent advertises the instance metadata service "
                + "(\(eligibleAgents) OVN-capable agent(s) checked) — enable `metadata_service`, "
                + "satisfy its host prerequisites, and let the agent re-register"
        case .sandboxRuntimeUnsatisfied(let eligibleAgents):
            return
                "No eligible agent advertises the sandbox runtime (\(eligibleAgents) Firecracker-capable agent(s) checked) — each needs a working Firecracker/KVM setup and the sandbox guest base image installed"
        case .sandboxNetworkingUnsatisfied(let eligibleAgents):
            return
                "No eligible agent can give a sandbox a NIC (\(eligibleAgents) sandbox-capable agent(s) checked) "
                + "— each needs `network_mode = \"ovn\"` with a connected OVN/OVS, "
                + "`sandbox_jailer_mode = \"required\"` satisfied, and a sandbox guest image new enough to "
                + "configure its interface; create the sandbox without a network to place it anyway"
        case .vtpmUnsatisfied(let eligibleAgents):
            return
                "No eligible agent can provide a TPM 2.0 (\(eligibleAgents) agent(s) checked) — install swtpm on a "
                + "hypervisor node (Debian/Ubuntu: `apt install swtpm swtpm-tools`), restart libvirtd there "
                + "(it caches host capabilities, so installing the package alone changes nothing), and let its "
                + "agent re-register"
        case .vsockUnsatisfied(let eligibleAgents):
            return
                "No eligible QEMU agent can provide virtio-vsock (\(eligibleAgents) agent(s) checked) — load the "
                + "vhost_vsock kernel module, ensure /dev/vhost-vsock exists, and let the agent re-register"
        case .siteUnsatisfied(let requiredSiteID):
            return
                "No online agent belongs to site \(requiredSiteID) required by the VM's network pinning"
        case .insufficientResources(let required, let available):
            return
                "No agent has sufficient resources. Required: CPU=\(required.cpu), Memory=\(required.memory), Disk=\(required.disk). Available agents: \(available.count)"
        }
    }
}

/// Service responsible for scheduling VM placement decisions
final class SchedulerService: Sendable {
    private let logger: Logger
    private let defaultStrategy: SchedulingStrategy
    private let roundRobinCounter: NIOLockedValueBox<Int>

    init(logger: Logger, defaultStrategy: SchedulingStrategy = .leastLoaded) {
        self.logger = logger
        self.defaultStrategy = defaultStrategy
        self.roundRobinCounter = NIOLockedValueBox(0)
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
    /// A plain NIC remains satisfiable by user-mode/SLIRP agents (outbound
    /// NAT), so NIC presence alone does not require overlay networking. An
    /// IMDS-backed NoCloud seed is different: its `seedfrom` hand-off must
    /// reach the per-VM metadata localport, which only an OVN-backed agent can
    /// realize. That bootstrap choice therefore imposes the hard network
    /// capability requirement. It also requires the independent metadata
    /// listener capability because an OVN host can disable that service or
    /// fail one of its startup prerequisites.
    static func placementRequirements(
        for vm: VM, architecture: CPUArchitecture? = nil, siteID: UUID? = nil,
        diskBytes: Int64? = nil
    ) -> VMPlacementRequirements {
        VMPlacementRequirements(
            cpu: vm.cpu,
            memory: vm.memory,
            disk: diskBytes ?? vm.disk,
            hypervisorType: vm.hypervisorType,
            architecture: architecture,
            requiresInterVMNetworking: vm.metadataSource == .imds,
            requiresMetadataService: vm.metadataSource == .imds,
            siteID: siteID,
            requiresVTPM: vm.tpmEnabled,
            requiresVsock: vm.guestAgentEnabled
        )
    }

    /// Select an agent and atomically reserve the VM's resources on it.
    ///
    /// This closes the read-decide-write placement race (issue #258): plain
    /// `selectAgent` decides on resource numbers that may already be claimed
    /// by a concurrent placement the agent's resource reports don't reflect
    /// yet. Here, hard constraints first narrow the fleet; each attempt then
    /// subtracts a batched read of the coordination store's active reservations
    /// from eligible agents before selection and atomically reserves the
    /// candidate's capacity. If the reservation loses a race (another placement
    /// consumed the capacity between the read and the reserve), selection
    /// re-runs with fresh reservation data — the now-full agent drops out in
    /// the resource filter — until placement succeeds or no agent fits.
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

        // Apply categorical and raw-capacity constraints before touching the
        // coordination store. Reservations can only reduce availability, so
        // an agent excluded here can never become viable during this attempt.
        let eligibleAgents = try filterEligibleAgents(agents, for: requirements)

        // Each failed attempt means a concurrent reservation landed; with n
        // agents, capacity can be stolen out from under us at most once per
        // agent before the resource filter excludes them all, so a small
        // margin over n bounds the loop without ever cutting a viable retry.
        let maxAttempts = eligibleAgents.count + 2
        for attempt in 1...max(1, maxAttempts) {
            let reservations = await coordination.activeReservations(
                agentIds: eligibleAgents.map(\.id))
            let adjusted = eligibleAgents.map {
                $0.subtractingReservations(reservations[$0.id] ?? .zero)
            }

            let selectedId = try selectAgent(
                requirements: requirements, from: adjusted, strategy: strategy, vmName: vmName)

            // The atomic reserve checks against the agent's *raw* reported
            // availability — the store re-subtracts reservations itself, so
            // passing adjusted numbers would double-count them.
            guard let selectedAgent = eligibleAgents.first(where: { $0.id == selectedId }) else {
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
                let outcome = Self.placementOutcome(for: error)
                span.attributes["scheduler.outcome"] = outcome
                span.recordError(error)
                Telemetry.recordPlacement(
                    strategy: selectedStrategy.rawValue, outcome: outcome,
                    durationSeconds: (clock.now - start).asSeconds)
                throw error
            }
        }
    }

    /// Classifies a placement failure for the `outcome` metric label and span
    /// attribute. Every `SchedulerError` is a "no eligible agent" outcome (a
    /// constraint or capacity shortfall); anything else is an unexpected fault.
    /// Factored out so the classification is unit-testable.
    static func placementOutcome(for error: any Error) -> String {
        error is SchedulerError ? "no_candidate" : "error"
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

        // A network pinned to a site exists only in that site's OVN
        // deployment. User-mode agents in the site are still ineligible
        // because they never attach to its OVN fabric.
        let siteMatched: [SchedulableAgent]
        if let requiredSiteID = requirements.siteID {
            siteMatched = online.filter {
                $0.siteID == requiredSiteID && $0.supportsInterVMNetworking
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

        // A sandbox with a NIC needs more than the runtime (STR-103): OVN, the
        // jailer barrier the NIC's namespace belongs to, and a guest image that
        // configures the interface. Categorical and refused rather than
        // degraded, unlike every other network constraint here — a sandbox
        // placed without its NIC boots unreachable while the API still shows
        // the address IPAM allocated, and nothing later notices.
        let sandboxNetworkCapable: [SchedulableAgent]
        if requirements.requiresSandboxNetworking {
            sandboxNetworkCapable = runtimeCapable.filter { $0.supportsSandboxNetworking }
            guard !sandboxNetworkCapable.isEmpty else {
                throw SchedulerError.sandboxNetworkingUnsatisfied(eligibleAgents: runtimeCapable.count)
            }
        } else {
            sandboxNetworkCapable = runtimeCapable
        }

        // A vTPM needs swtpm on the host; the failure is categorical and
        // *silent* on a host that can't serve it — the guest simply boots
        // without the device — so placement is refused rather than degraded
        // (issue #565). Secure Boot and the graphics console need no host
        // capability: firmware is resolved on the agent, and a QEMU built
        // without VNC fails the create loudly.
        var machineCapable = sandboxNetworkCapable
        if requirements.requiresVTPM {
            let tpmCapable = machineCapable.filter { $0.supportsVTPM }
            guard !tpmCapable.isEmpty else {
                throw SchedulerError.vtpmUnsatisfied(eligibleAgents: machineCapable.count)
            }
            machineCapable = tpmCapable
        }

        // The Strato guest agent communicates over virtio-vsock. QEMU cannot
        // start a domain containing that device unless the host exposes the
        // vhost-vsock backend, so this is a placement constraint rather than
        // merely an agent-side warning.
        if requirements.requiresVsock {
            let vsockCapable = machineCapable.filter { $0.supportsVsock }
            guard !vsockCapable.isEmpty else {
                throw SchedulerError.vsockUnsatisfied(eligibleAgents: machineCapable.count)
            }
            machineCapable = vsockCapable
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

        let metadataCapable =
            requirements.requiresMetadataService
            ? networkCapable.filter { $0.supportsMetadataService }
            : networkCapable
        guard !metadataCapable.isEmpty else {
            throw SchedulerError.metadataServiceUnsatisfied(eligibleAgents: networkCapable.count)
        }

        let eligible = metadataCapable.filter { agent in
            agent.availableCPU >= requirements.cpu && agent.availableMemory >= requirements.memory
                && agent.availableDisk >= requirements.disk
        }
        guard !eligible.isEmpty else {
            throw SchedulerError.insufficientResources(required: requirements, available: metadataCapable)
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
        let index = roundRobinCounter.withLockedValue { counter in
            let index = counter % agents.count
            counter += 1
            return index
        }

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
        self.setStorageValue(SchedulerServiceKey.self, to: scheduler)
    }
}
