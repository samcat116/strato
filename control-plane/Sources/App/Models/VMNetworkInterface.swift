import Fluent
import Vapor

/// A NIC attached to a VM, mirroring how `Volume` models disks. Each row is one
/// interface on a logical network; `VMSpecBuilder` turns the VM's interfaces into
/// the `NetworkSpec` list sent to agents, ordered by `orderIndex` then `deviceName`.
/// Safety: this mutable Fluent model stays inside one logical operation; child tasks
/// receive IDs or immutable snapshots and reload their own instance.
final class VMNetworkInterface: Model, @unchecked Sendable {
    static let schema = "vm_network_interfaces"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "vm_id")
    var vm: VM

    /// The logical network this NIC attaches to. A real FK (issue #765): the
    /// name is a per-project display label and cannot identify a network.
    @Parent(key: "logical_network_id")
    var logicalNetwork: LogicalNetwork

    @Field(key: "mac_address")
    var macAddress: String

    /// The addresses allocated to this NIC, one row per family (requires
    /// eager loading with `.with(\.$addresses)`).
    @Children(for: \.$interface)
    var addresses: [VMInterfaceAddress]

    /// The addresses the guest actually configured on this NIC, as reported by
    /// the QEMU guest agent (issue #563) — distinct from the allocated
    /// `addresses` above: these include DHCP leases, IPv6 SLAAC, and any manual
    /// changes the control plane never assigned. Requires eager loading with
    /// `.with(\.$observedAddresses)`.
    @Children(for: \.$interface)
    var observedAddresses: [VMInterfaceObservedAddress]

    /// This NIC's security-group memberships (STR-34). Requires eager loading
    /// with `.with(\.$securityGroupMemberships)`; `NetworkInterfaceResponse`
    /// reports nil rather than an empty list when it wasn't loaded, because
    /// "attached to no groups" is a claim about filtering that a missing
    /// eager-load must never make.
    @Children(for: \.$interface)
    var securityGroupMemberships: [VMInterfaceSecurityGroup]

    @OptionalField(key: "mtu")
    var mtu: Int?

    /// Stable device identifier within the VM (e.g. "net0", "net1").
    @Field(key: "device_name")
    var deviceName: String

    /// Position of this NIC in the VM's interface list (lower = earlier).
    @Field(key: "order_index")
    var orderIndex: Int

    /// VM generation that first asked the agent to realize this NIC. Nil marks
    /// rows created before STR-202, which are treated as already attached.
    @OptionalField(key: "attach_generation")
    var attachGeneration: Int64?

    /// VM generation that asks the agent to remove this NIC. The row and its IP
    /// leases remain until an observed v40 manifest confirms absence.
    @OptionalField(key: "detach_generation")
    var detachGeneration: Int64?

    @OptionalField(key: "security_group_status")
    var securityGroupStatus: String?

    @OptionalField(key: "security_group_last_error")
    var securityGroupLastError: String?

    @OptionalField(key: "security_group_last_error_at")
    var securityGroupLastErrorAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        vmID: UUID,
        logicalNetworkID: UUID,
        macAddress: String,
        mtu: Int? = nil,
        deviceName: String = "net0",
        orderIndex: Int = 0
    ) {
        self.id = id
        self.$vm.id = vmID
        self.$logicalNetwork.id = logicalNetworkID
        self.macAddress = macAddress
        self.mtu = mtu
        self.deviceName = deviceName
        self.orderIndex = orderIndex
        self.attachGeneration = nil
        self.detachGeneration = nil
        self.securityGroupStatus = nil
        self.securityGroupLastError = nil
        self.securityGroupLastErrorAt = nil
    }

}

extension VMNetworkInterface {
    static let maxInterfacesPerVM = 8
}

extension VMNetworkInterface: Content {}

extension Sequence where Element == VMNetworkInterface {
    /// The interfaces in the VM's device order: `orderIndex`, then
    /// `deviceName` for stability when orders collide.
    ///
    /// One definition because four things have to agree on it — the `VMSpec`'s
    /// `NetworkSpec` list, the `InstanceMetadata` the guest reads, the API's
    /// `VMDetailResponse`, and a floating IP's `nicIndex`, which *is* a
    /// position in this order on the wire. Four copies of the comparator meant
    /// four places to change it and one guest whose NIC list disagreed with its
    /// links if you missed one.
    var inDeviceOrder: [VMNetworkInterface] {
        sorted { ($0.orderIndex, $0.deviceName) < ($1.orderIndex, $1.deviceName) }
    }
}
