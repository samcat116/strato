import Fluent
import Vapor

/// A NIC attached to a sandbox, the sandbox analogue of `VMNetworkInterface`
/// (issue #416). Deliberately its own slim table rather than a generalization
/// of the VM NIC — sandboxes are a parallel resource with their own lifecycle —
/// but the shape mirrors the VM path so `IPAMService`, `MACAllocator`, and
/// stable device naming are reused. v1 gives each sandbox exactly one NIC.
/// Safety: this mutable Fluent model stays inside one logical operation; child tasks
/// receive IDs or immutable snapshots and reload their own instance.
final class SandboxNetworkInterface: Model, @unchecked Sendable {
    static let schema = "sandbox_network_interfaces"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "sandbox_id")
    var sandbox: Sandbox

    /// The logical network this NIC attaches to. A real FK (issue #765): the
    /// name is a per-project display label and cannot identify a network.
    @Parent(key: "logical_network_id")
    var logicalNetwork: LogicalNetwork

    @Field(key: "mac_address")
    var macAddress: String

    /// The addresses allocated to this NIC, one row per family (requires
    /// eager loading with `.with(\.$addresses)`).
    @Children(for: \.$interface)
    var addresses: [SandboxInterfaceAddress]

    /// This NIC's security-group memberships (STR-34, STR-102) — see
    /// `SandboxInterfaceSecurityGroup` for which half of the sync each row
    /// reaches today. Requires eager loading with
    /// `.with(\.$securityGroupMemberships)`.
    @Children(for: \.$interface)
    var securityGroupMemberships: [SandboxInterfaceSecurityGroup]

    @OptionalField(key: "security_group_status")
    var securityGroupStatus: String?

    @OptionalField(key: "security_group_last_error")
    var securityGroupLastError: String?

    @OptionalField(key: "security_group_last_error_at")
    var securityGroupLastErrorAt: Date?

    @OptionalField(key: "mtu")
    var mtu: Int?

    /// Stable device identifier within the sandbox (e.g. "net0"). Single-NIC in
    /// v1, so always "net0", but kept for parity with the VM path.
    @Field(key: "device_name")
    var deviceName: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        sandboxID: UUID,
        logicalNetworkID: UUID,
        macAddress: String,
        mtu: Int? = nil,
        deviceName: String = "net0"
    ) {
        self.id = id
        self.$sandbox.id = sandboxID
        self.$logicalNetwork.id = logicalNetworkID
        self.macAddress = macAddress
        self.mtu = mtu
        self.deviceName = deviceName
        self.securityGroupStatus = nil
        self.securityGroupLastError = nil
        self.securityGroupLastErrorAt = nil
    }
}

extension SandboxNetworkInterface: Content {}
