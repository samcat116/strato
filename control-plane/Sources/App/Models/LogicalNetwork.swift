import Fluent
import Vapor

/// A logical network VMs attach to, and the unit of IPAM ownership: the control
/// plane allocates NIC addresses from a network's subnet and pushes them down to
/// agents in the `VMSpec` (issue #212). Agents realize the network on their
/// platform (OVN logical switch on Linux, user-mode on macOS) by name.
///
/// Names are globally unique — `VMNetworkInterface` rows, the IPAM uniqueness
/// index, and agent realization all key on the name string, not the row id.
/// Networks with a nil `project` are global (the seeded "default" network);
/// per-project name scoping would require migrating NIC references to an FK
/// and is deferred.
final class LogicalNetwork: Model, @unchecked Sendable {
    static let schema = "logical_networks"

    /// Name of the network every VM's default NIC lands on. Seeded at migration
    /// time; the subnet/gateway match what agents historically hardcoded so
    /// existing deployments keep their addressing.
    static let defaultNetworkName = "default"

    @ID(key: .id)
    var id: UUID?

    /// Unique name agents use to find or create the network.
    @Field(key: "name")
    var name: String

    /// Subnet in CIDR notation (e.g. "192.168.1.0/24"). IPs are allocated from
    /// its host range.
    @Field(key: "subnet")
    var subnet: String

    /// Gateway address inside the subnet; excluded from allocation and pushed
    /// to guests via the VM spec. Changing it only affects future allocations:
    /// existing NICs carry a denormalized copy.
    @OptionalField(key: "gateway")
    var gateway: String?

    /// Project this network belongs to; nil means global (visible to everyone,
    /// managed by system admins only).
    @OptionalParent(key: "project_id")
    var project: Project?

    /// User who created the network; nil for seeded networks.
    @OptionalParent(key: "created_by_id")
    var createdBy: User?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        name: String,
        subnet: String,
        gateway: String? = nil,
        projectID: UUID? = nil,
        createdByID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.subnet = subnet
        self.gateway = gateway
        self.$project.id = projectID
        self.$createdBy.id = createdByID
    }
}

extension LogicalNetwork: Content {}

// MARK: - Request/Response DTOs

struct CreateNetworkRequest: Content {
    let name: String
    /// Subnet in CIDR notation; prefix must be within /8–/30.
    let subnet: String
    /// Defaults to the subnet's first host address when omitted.
    let gateway: String?
    /// Defaults to the caller's default project when omitted.
    let projectId: UUID?
}

struct UpdateNetworkRequest: Content {
    /// Rejected while any VM interface references the network.
    let name: String?
    /// Rejected while any VM interface references the network.
    let subnet: String?
    /// May change anytime, but only affects future allocations.
    let gateway: String?
}

struct NetworkResponse: Content {
    let id: UUID?
    let name: String
    let subnet: String
    let gateway: String?
    let projectId: UUID?
    let isDefault: Bool
    let attachedInterfaceCount: Int
    let createdAt: Date?
    let updatedAt: Date?

    init(from network: LogicalNetwork, attachedInterfaceCount: Int) {
        self.id = network.id
        self.name = network.name
        self.subnet = network.subnet
        self.gateway = network.gateway
        self.projectId = network.$project.id
        self.isDefault = network.name == LogicalNetwork.defaultNetworkName
        self.attachedInterfaceCount = attachedInterfaceCount
        self.createdAt = network.createdAt
        self.updatedAt = network.updatedAt
    }
}
