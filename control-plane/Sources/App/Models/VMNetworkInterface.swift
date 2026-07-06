import Fluent
import Vapor

/// A NIC attached to a VM, mirroring how `Volume` models disks. Each row is one
/// interface on a logical network; `VMSpecBuilder` turns the VM's interfaces into
/// the `NetworkSpec` list sent to agents, ordered by `orderIndex` then `deviceName`.
final class VMNetworkInterface: Model, @unchecked Sendable {
    static let schema = "vm_network_interfaces"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "vm_id")
    var vm: VM

    /// Logical network reference; agents use this to find or create the network.
    @Field(key: "network")
    var network: String

    @Field(key: "mac_address")
    var macAddress: String

    /// Static IP assignment, when the control plane has allocated one.
    @OptionalField(key: "ip_address")
    var ipAddress: String?

    @OptionalField(key: "netmask")
    var netmask: String?

    /// Gateway of the logical network, denormalized at allocation time so spec
    /// building needs no network lookup.
    @OptionalField(key: "gateway")
    var gateway: String?

    @OptionalField(key: "mtu")
    var mtu: Int?

    /// Stable device identifier within the VM (e.g. "net0", "net1").
    @Field(key: "device_name")
    var deviceName: String

    /// Position of this NIC in the VM's interface list (lower = earlier).
    @Field(key: "order_index")
    var orderIndex: Int

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        vmID: UUID,
        network: String = "default",
        macAddress: String,
        ipAddress: String? = nil,
        netmask: String? = nil,
        gateway: String? = nil,
        mtu: Int? = nil,
        deviceName: String = "net0",
        orderIndex: Int = 0
    ) {
        self.id = id
        self.$vm.id = vmID
        self.network = network
        self.macAddress = macAddress
        self.ipAddress = ipAddress
        self.netmask = netmask
        self.gateway = gateway
        self.mtu = mtu
        self.deviceName = deviceName
        self.orderIndex = orderIndex
    }

    /// Generates a random MAC address with VMware OUI (00:0c:29)
    static func generateMACAddress() -> String {
        let randomBytes = (0..<3).map { _ in String(format: "%02x", Int.random(in: 0...255)) }
        return "00:0c:29:\(randomBytes.joined(separator: ":"))"
    }
}

extension VMNetworkInterface: Content {}
