import Fluent
import Vapor

/// Membership of one VM NIC in one security group (many-to-many). The
/// interface FK cascades — deleting a VM (whose NIC rows cascade away)
/// detaches it from all groups — while the group FK is RESTRICT: a group
/// cannot be deleted while any NIC still attaches it, surfaced by the API as
/// a 409. Every NIC has at least one row (the ≥1-group invariant), enforced
/// by the controllers rather than the schema.
final class VMInterfaceSecurityGroup: Model, @unchecked Sendable {
    static let schema = "vm_interface_security_groups"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "interface_id")
    var interface: VMNetworkInterface

    @Parent(key: "security_group_id")
    var securityGroup: SecurityGroup

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, interfaceID: UUID, securityGroupID: UUID) {
        self.id = id
        self.$interface.id = interfaceID
        self.$securityGroup.id = securityGroupID
    }
}
