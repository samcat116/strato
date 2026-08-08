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
///   is withheld with the whole spec while
///   `SandboxSpecBuilder.guestNetworkingSupported` is false. There is no OVN
///   port yet, so there is nothing to make a member of anything.
///
/// STR-103 flips that flag and the second half starts flowing. Realizing the
/// groups first is what makes that flip safe: a port group with no members
/// filters nothing, and its existing means the first sandbox port to come up
/// joins it immediately instead of parking on `DependencyPendingError`.
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
