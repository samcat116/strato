import Fluent
import Vapor

/// One external IPv4 address allocated from a `FloatingIPPool` (issue #344).
/// Project-scoped like a network: a project allocates an address, then
/// attaches it to one of its VMs' NICs. An attached floating IP is realized
/// agent-side as an OVN `dnat_and_snat` rule on the NIC's network router —
/// inbound traffic to the floating address is DNAT'd to the NIC's fixed IP,
/// and the VM's outbound traffic is SNAT'd to the floating address.
///
/// The interface FK is `SET NULL` on delete, so deleting the VM (or NIC)
/// detaches the address instead of releasing it — the project keeps the
/// (possibly DNS-published) address to re-attach elsewhere.
final class FloatingIP: Model, @unchecked Sendable {
    static let schema = "floating_ips"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "pool_id")
    var pool: FloatingIPPool

    /// The external address in canonical dotted-quad form. Unique per pool
    /// (schema-enforced).
    @Field(key: "address")
    var address: String

    /// Project that owns the allocation.
    @Parent(key: "project_id")
    var project: Project

    /// The VM NIC this address is attached to; nil while the address is
    /// reserved but unattached (no NAT anywhere).
    @OptionalParent(key: "interface_id")
    var interface: VMNetworkInterface?

    @OptionalParent(key: "created_by_id")
    var createdBy: User?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        poolID: UUID,
        address: String,
        projectID: UUID,
        interfaceID: UUID? = nil,
        createdByID: UUID? = nil
    ) {
        self.id = id
        self.$pool.id = poolID
        self.address = address
        self.$project.id = projectID
        self.$interface.id = interfaceID
        self.$createdBy.id = createdByID
    }
}

extension FloatingIP: Content {}

// MARK: - DTOs

struct CreateFloatingIPRequest: Content {
    let poolId: UUID
    /// Defaults to the caller's default project when omitted, matching VM and
    /// network creation.
    let projectId: UUID?
}

struct AttachFloatingIPRequest: Content {
    let vmId: UUID
    /// The VM NIC to attach to; defaults to the VM's first interface.
    let interfaceId: UUID?
}

struct FloatingIPResponse: Content {
    let id: UUID
    let address: String
    let poolId: UUID
    let projectId: UUID
    /// Attachment details, nil while unattached.
    let interfaceId: UUID?
    let vmId: UUID?
    let fixedIP: String?
    let networkName: String?
    let createdAt: Date?

    init(from floatingIP: FloatingIP, interface: VMNetworkInterface? = nil) throws {
        self.id = try floatingIP.requireID()
        self.address = floatingIP.address
        self.poolId = floatingIP.$pool.id
        self.projectId = floatingIP.$project.id
        self.interfaceId = floatingIP.$interface.id
        self.vmId = interface?.$vm.id
        self.fixedIP = interface?.ipv4Address?.address
        self.networkName = interface?.network
        self.createdAt = floatingIP.createdAt
    }
}
