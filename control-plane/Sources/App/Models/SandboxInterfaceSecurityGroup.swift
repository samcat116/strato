import Fluent
import Vapor

/// Membership of one sandbox NIC in one security group (many-to-many), the
/// sandbox twin of `VMInterfaceSecurityGroup` with identical FK semantics:
/// the interface FK cascades (deleting a sandbox cascades its NIC, which
/// cascades these rows) and the group FK is RESTRICT, so a group attached to
/// a sandbox NIC refuses deletion with the same 409 a VM attachment earns.
///
/// **Bookkeeping only, for now.** Sandbox guest networking is still disabled
/// (`SandboxSpecBuilder.guestNetworkingSupported`), so a sandbox NIC's
/// `NetworkSpec` never reaches an agent and these memberships enforce
/// nothing. They exist so the model, the API, and the ≥1-group invariant are
/// already right when guest networking lands — at which point the sync's
/// membership assembly grows a sandbox arm and the rows start mattering
/// without a data migration.
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
