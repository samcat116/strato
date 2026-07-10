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

    /// Every hypervisor on the host with probed availability and capabilities
    @Field(key: "hypervisors")
    var hypervisors: [HypervisorSupport]

    /// Host networking capability, nil for agents that registered before it was reported
    @OptionalField(key: "network_capability")
    var networkCapability: String?

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

    /// Owning organization (exactly one of organization / organizational unit;
    /// see `organizationScope`). Agents are dedicated capacity: the scheduler
    /// only places a VM on an agent whose root organization matches the VM's.
    /// Assigned via the registration token, durable on the row afterwards.
    @OptionalParent(key: "organization_id")
    var organization: Organization?

    @OptionalParent(key: "organizational_unit_id")
    var organizationalUnit: OrganizationalUnit?

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
        return Agent(
            name: name,
            hostname: registration.hostname,
            version: registration.version,
            capabilities: registration.capabilities,
            status: .connecting,
            resources: registration.resources,
            architecture: registration.architecture,
            hypervisors: registration.effectiveHypervisors,
            networkCapability: registration.networkCapability,
            lastHeartbeat: Date()
        )
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
    let hypervisors: [HypervisorSupport]
    let networkCapability: NetworkCapability?
    let siteId: UUID?
    let organizationId: UUID?
    let organizationalUnitId: UUID?
    let lastHeartbeat: Date?
    let createdAt: Date?
    let isOnline: Bool

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
        self.hypervisors = agent.hypervisors
        self.networkCapability = agent.networkCapability.flatMap(NetworkCapability.init(rawValue:))
        self.siteId = agent.$site.id
        self.organizationId = agent.$organization.id
        self.organizationalUnitId = agent.$organizationalUnit.id
        self.lastHeartbeat = agent.lastHeartbeat
        self.createdAt = agent.createdAt
        self.isOnline = agent.isOnline
    }
}
