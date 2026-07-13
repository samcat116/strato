import Fluent
import Vapor
import StratoShared

final class Agent: Model, Content, @unchecked Sendable {
    static let schema = "agents"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "name")
    var name: String

    @Field(key: "hostname")
    var hostname: String

    @Field(key: "version")
    var version: String

    @Field(key: "capabilities")
    var capabilities: [String]

    @Enum(key: "status")
    var status: AgentStatus

    @Field(key: "total_cpu")
    var totalCPU: Int

    @Field(key: "total_memory")
    var totalMemory: Int64

    @Field(key: "total_disk")
    var totalDisk: Int64

    @Field(key: "available_cpu")
    var availableCPU: Int

    @Field(key: "available_memory")
    var availableMemory: Int64

    @Field(key: "available_disk")
    var availableDisk: Int64

    @Timestamp(key: "last_heartbeat", on: .none)
    var lastHeartbeat: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    /// Host CPU architecture, nil for agents that registered before it was reported
    @OptionalField(key: "architecture")
    var architecture: String?

    /// Host operating system ("linux"/"macos"), nil for agents that registered
    /// before it was reported. The update endpoint needs it to resolve the
    /// per-OS/arch release artifact and refuses to guess when absent.
    @OptionalField(key: "operating_system")
    var operatingSystem: String?

    /// Every hypervisor on the host with probed availability and capabilities
    @Field(key: "hypervisors")
    var hypervisors: [HypervisorSupport]

    /// Host networking capability, nil for agents that registered before it was reported
    @OptionalField(key: "network_capability")
    var networkCapability: String?

    /// Descriptive hardware/platform/OS details (CPU model, kernel version,
    /// distribution, physical core count, boot time, ...) the agent reports at
    /// registration, for operator display. Purely informational — nothing in
    /// scheduling or reconciliation reads it. Nil for agents that registered
    /// before host-info reporting.
    @OptionalField(key: "host_info")
    var hostInfo: HostInfo?

    /// The site (availability zone) this agent belongs to. Nil means the
    /// legacy single-node model: the agent owns a private local OVN NB and is
    /// always its topology authority. Assigned via the registration token.
    @OptionalParent(key: "site_id")
    var site: Site?

    /// Wire protocol version the agent last registered with; nil for rows that
    /// predate this column. Sync assembly keys site topology authority on it:
    /// a pre-v4 agent ignores `networksAuthoritative` and would misread a
    /// non-authoritative empty sync as a full L3 teardown, so it must stay on
    /// legacy per-node scoping even when assigned to a site.
    @OptionalField(key: "wire_protocol_version")
    var wireProtocolVersion: Int?

    /// Whether the agent advertised the sandbox runtime at its last
    /// registration (issue #415): Firecracker + KVM usable and the sandbox
    /// guest base image present on its disk. The scheduler gates sandbox
    /// placement on this explicit signal (combined with a v5+ wire protocol) —
    /// never on the protocol version alone, which a runtime-less build also
    /// speaks.
    @Field(key: "sandbox_capable")
    var sandboxCapable: Bool

    /// Owning organization (exactly one of organization / organizational unit;
    /// see `organizationScope`). Agents are dedicated capacity: the scheduler
    /// only places a VM on an agent whose root organization matches the VM's.
    /// Assigned via the registration token, durable on the row afterwards.
    @OptionalParent(key: "organization_id")
    var organization: Organization?

    @OptionalParent(key: "organizational_unit_id")
    var organizationalUnit: OrganizationalUnit?

    /// Whether this agent is enrolled in declarative auto-update (issue
    /// #434): the fleet rollout may assign it the deployment's target version
    /// and the agent converges on its own. Default off — an update restarts
    /// the agent, so enrollment is an explicit operator decision.
    @Field(key: "auto_update")
    var autoUpdate: Bool

    /// The version the auto-update rollout has assigned this agent, carried
    /// on its desired-state syncs as `desiredAgentUpdate` until the agent
    /// re-registers at it. Nil when the rollout has no opinion (not enrolled,
    /// not reached, or already converged). Owned by the rollout sweep.
    @OptionalField(key: "update_desired_version")
    var updateDesiredVersion: String?

    /// When `updateDesiredVersion` was assigned — the rollout's health-budget
    /// clock: an assigned agent that neither converges nor reports a blocker
    /// within the budget halts the rollout.
    @Timestamp(key: "update_attempted_at", on: .none)
    var updateAttemptedAt: Date?

    /// The agent's most recent self-reported reason for not converging on
    /// its assigned update (running Firecracker VMs, containerized install,
    /// reconcile work in flight). Cleared when the agent reports clean.
    @OptionalField(key: "update_blocked_reason")
    var updateBlockedReason: String?

    /// A terminal update failure for the assigned version — either reported
    /// by the agent (download/checksum/swap failure) or recorded by the sweep
    /// when the agent went silent past its health budget. Any non-nil value
    /// for the current target halts the fleet rollout until an operator
    /// intervenes (or the target moves on).
    @OptionalField(key: "update_failure_reason")
    var updateFailureReason: String?

    init() {}

    init(
        id: UUID? = nil,
        name: String,
        hostname: String,
        version: String,
        capabilities: [String],
        status: AgentStatus = .offline,
        resources: AgentResources,
        architecture: CPUArchitecture? = nil,
        hypervisors: [HypervisorSupport] = [],
        networkCapability: NetworkCapability? = nil,
        sandboxCapable: Bool = false,
        lastHeartbeat: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.version = version
        self.capabilities = capabilities
        self.status = status
        self.totalCPU = resources.totalCPU
        self.totalMemory = resources.totalMemory
        self.totalDisk = resources.totalDisk
        self.availableCPU = resources.availableCPU
        self.availableMemory = resources.availableMemory
        self.availableDisk = resources.availableDisk
        self.architecture = architecture?.rawValue
        self.hypervisors = hypervisors
        self.networkCapability = networkCapability?.rawValue
        self.sandboxCapable = sandboxCapable
        self.autoUpdate = false
        self.lastHeartbeat = lastHeartbeat
    }

    func updateResources(_ resources: AgentResources) {
        self.availableCPU = resources.availableCPU
        self.availableMemory = resources.availableMemory
        self.availableDisk = resources.availableDisk
        self.lastHeartbeat = Date()
    }

    var resources: AgentResources {
        return AgentResources(
            totalCPU: totalCPU,
            availableCPU: availableCPU,
            totalMemory: totalMemory,
            availableMemory: availableMemory,
            totalDisk: totalDisk,
            availableDisk: availableDisk
        )
    }
}

enum AgentStatus: String, Codable, CaseIterable, Sendable {
    case online = "online"
    case offline = "offline"
    case connecting = "connecting"
    case error = "error"
}

// MARK: - Agent Extensions for Registration

extension Agent {
    /// Create an agent from registration message
    static func from(registration: AgentRegisterMessage, name: String) -> Agent {
        let agent = Agent(
            name: name,
            hostname: registration.hostname,
            version: registration.version,
            capabilities: registration.capabilities,
            status: .connecting,
            resources: registration.resources,
            architecture: registration.architecture,
            hypervisors: registration.effectiveHypervisors,
            networkCapability: registration.networkCapability,
            sandboxCapable: registration.sandboxCapable ?? false,
            lastHeartbeat: Date()
        )
        agent.operatingSystem = registration.operatingSystem?.rawValue
        agent.hostInfo = registration.hostInfo
        return agent
    }

    /// Check if agent is considered online based on heartbeat
    var isOnline: Bool {
        guard let lastHeartbeat = lastHeartbeat else { return false }
        return Date().timeIntervalSince(lastHeartbeat) < 60  // 60 seconds timeout
    }

    /// Host CPU architecture as a typed value; nil for agents that registered
    /// before architecture reporting (or an unrecognized raw value).
    var cpuArchitecture: CPUArchitecture? {
        architecture.flatMap(CPUArchitecture.init(rawValue:))
    }

    /// Host operating system as a typed value; nil for agents that registered
    /// before OS reporting (or an unrecognized raw value).
    var hostOperatingSystem: OperatingSystem? {
        operatingSystem.flatMap(OperatingSystem.init(rawValue:))
    }

    /// Hypervisor backends this agent can actually run. Agents probe each
    /// backend before reporting it, so an empty list means the agent cannot
    /// run VMs at all — it stays registered but is never eligible for
    /// placement. No QEMU fallback here: assuming QEMU for an empty list
    /// would defeat the agent-side probe in exactly the case it exists for.
    var supportedHypervisors: [HypervisorType] {
        hypervisors.filter(\.available).map(\.type)
    }

    /// Only OVN-backed agents can provide VM-to-VM networking; user-mode
    /// (SLIRP) agents cannot. Agents that predate structured network
    /// capability reporting are judged by their legacy capability strings.
    var supportsInterVMNetworking: Bool {
        if let capability = networkCapability.flatMap(NetworkCapability.init(rawValue:)) {
            return capability == .overlay
        }
        return capabilities.contains("ovn_networking")
    }

    /// Update agent status based on heartbeat age
    func updateStatusBasedOnHeartbeat() {
        if isOnline && status == .offline {
            status = .online
        } else if !isOnline && status == .online {
            status = .offline
        }
    }

    /// The agent's org-or-OU owner; nil only for rows that predate mandatory
    /// scoping and were never backfilled (a fresh install has none).
    var organizationScope: OrganizationScope? {
        get {
            if let orgID = self.$organization.id { return .organization(orgID) }
            if let ouID = self.$organizationalUnit.id { return .organizationalUnit(ouID) }
            return nil
        }
        set {
            self.$organization.id = newValue?.organizationID
            self.$organizationalUnit.id = newValue?.organizationalUnitID
        }
    }

    /// The root organization the agent is dedicated to (OU scope resolves to
    /// its owning org). Placement compares this against the VM project's root.
    func rootOrganizationID(on db: Database) async throws -> UUID? {
        try await organizationScope?.rootOrganizationID(on: db)
    }
}

// MARK: - DTO for API responses

struct AgentResponse: Content {
    let id: UUID
    let name: String
    let hostname: String
    let version: String
    let capabilities: [String]
    let status: AgentStatus
    let resources: AgentResources
    let architecture: CPUArchitecture?
    let operatingSystem: OperatingSystem?
    let hypervisors: [HypervisorSupport]
    let networkCapability: NetworkCapability?
    let sandboxCapable: Bool
    /// Descriptive hardware/platform/OS details for operator display; nil for
    /// agents that registered before host-info reporting.
    let hostInfo: HostInfo?
    let siteId: UUID?
    let organizationId: UUID?
    let organizationalUnitId: UUID?
    let lastHeartbeat: Date?
    let createdAt: Date?
    let isOnline: Bool
    /// The version this agent should be running (see `AgentVersionTarget`);
    /// nil when the deployment has no meaningful target (dev builds).
    let targetVersion: String?
    let updateAvailable: Bool
    /// Declarative auto-update enrollment and rollout state (issue #434).
    let autoUpdate: Bool
    /// The version the fleet rollout has assigned this agent, while it is
    /// converging; nil once converged (or never assigned).
    let updateDesiredVersion: String?
    let updateAttemptedAt: Date?
    /// The agent's self-reported reason for not converging yet.
    let updateBlockedReason: String?
    /// Terminal failure that halted the rollout at this agent, if any.
    let updateFailureReason: String?

    init(from agent: Agent) throws {
        guard let id = agent.id else {
            throw Abort(.internalServerError, reason: "Agent missing ID")
        }

        self.id = id
        self.name = agent.name
        self.hostname = agent.hostname
        self.version = agent.version
        self.capabilities = agent.capabilities
        self.status = agent.status
        self.resources = agent.resources
        self.architecture = agent.architecture.flatMap(CPUArchitecture.init(rawValue:))
        self.operatingSystem = agent.hostOperatingSystem
        self.hypervisors = agent.hypervisors
        self.networkCapability = agent.networkCapability.flatMap(NetworkCapability.init(rawValue:))
        self.sandboxCapable = agent.sandboxCapable
        self.hostInfo = agent.hostInfo
        self.siteId = agent.$site.id
        self.organizationId = agent.$organization.id
        self.organizationalUnitId = agent.$organizationalUnit.id
        self.lastHeartbeat = agent.lastHeartbeat
        self.createdAt = agent.createdAt
        self.isOnline = agent.isOnline
        self.targetVersion = AgentVersionTarget.version
        self.updateAvailable = AgentVersionTarget.updateAvailable(
            agentVersion: agent.version,
            target: AgentVersionTarget.version
        )
        self.autoUpdate = agent.autoUpdate
        self.updateDesiredVersion = agent.updateDesiredVersion
        self.updateAttemptedAt = agent.updateAttemptedAt
        self.updateBlockedReason = agent.updateBlockedReason
        self.updateFailureReason = agent.updateFailureReason
    }
}
