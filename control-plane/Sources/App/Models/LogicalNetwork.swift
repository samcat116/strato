import Fluent
import Vapor

/// A logical network VMs attach to, and the unit of IPAM ownership: the control
/// plane allocates NIC addresses from a network's subnet and pushes them down to
/// agents in the `VMSpec` (issue #212). Agents realize the network on their
/// platform (OVN logical switch on Linux, user-mode on macOS) by name.
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
    /// to guests via the VM spec.
    @OptionalField(key: "gateway")
    var gateway: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, name: String, subnet: String, gateway: String? = nil) {
        self.id = id
        self.name = name
        self.subnet = subnet
        self.gateway = gateway
    }
}

extension LogicalNetwork: Content {}
