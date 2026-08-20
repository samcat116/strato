import ControlPlanePostgres
import Vapor

// MARK: - DTOs

struct CreateFloatingIPRequest: Content {
    let poolId: UUID
    /// Required: there is no default project (issue #1059). Optional here so
    /// the refusal is `Request.projectIsRequired`'s, which names the remedy,
    /// rather than a `Codable` decode failure that names neither.
    let projectId: UUID?
}

struct AttachFloatingIPRequest: Content {
    let vmId: UUID?
    /// The VM NIC to attach to; defaults to the VM's first interface.
    let interfaceId: UUID?
    /// Alternative attachment target: a native load-balancer VIP.
    let loadBalancerId: UUID?
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
    let loadBalancerId: UUID?
    /// The attached NIC's network: the id references it, the name is a display
    /// label present only when the caller eager-loaded the relation (issue #765).
    let networkId: UUID?
    let networkName: String?
    let createdAt: Date?

    init(from floatingIP: FloatingIPAllocationSnapshot) throws {
        self.id = floatingIP.id
        self.address = floatingIP.address
        self.poolId = floatingIP.poolID
        self.projectId = floatingIP.projectID
        self.interfaceId = floatingIP.interfaceID
        self.vmId = floatingIP.vmID
        self.fixedIP = floatingIP.fixedIP
        self.loadBalancerId = floatingIP.loadBalancerID
        self.networkId = floatingIP.networkID
        self.networkName = floatingIP.networkName
        self.createdAt = floatingIP.createdAt
    }
}
