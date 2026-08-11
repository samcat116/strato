import Fluent
import Vapor

/// Membership of one sandbox NIC in one security group (many-to-many), the
/// sandbox twin of `VMInterfaceSecurityGroup` with identical FK semantics:
/// the interface FK cascades (deleting a sandbox cascades its NIC, which
/// cascades these rows) and the group FK is RESTRICT, so a group attached to
/// a sandbox NIC refuses deletion with the same 409 a VM attachment earns.
///
/// These rows are read by two halves of the sync, which STR-102 landed
/// together and which reach an agent at different times:
///
/// - **The group closure** — every group a sandbox NIC attaches, plus what its
///   rules reference, is seeded into `DesiredStateMessage.securityGroups`, so
///   a topology authority realizes the port groups and ACLs *today*.
/// - **The per-NIC membership** — the ids inside the sandbox's `NetworkSpec` —
///   rides the spec, and so reaches only a host that advertises sandbox
///   networking (STR-103). On a host without it there is no OVN port, so there
///   is nothing to make a member of anything.
///
/// Realizing the groups first is what makes that per-host arrival safe: a port
/// group with no members filters nothing, and its existing means the first
/// sandbox port to come up joins it immediately instead of parking on
/// `DependencyPendingError`.
/// Safety: this mutable Fluent model stays inside one logical operation; child tasks
/// receive IDs or immutable snapshots and reload their own instance.
final class SandboxInterfaceSecurityGroup: Model, @unchecked Sendable {
    static let schema = "sandbox_interface_security_groups"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "interface_id")
    var interface: SandboxNetworkInterface

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
