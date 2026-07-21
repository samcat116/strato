import Fluent
import StratoShared
import Vapor

/// One IP address allocated to a sandbox NIC, the sandbox analogue of
/// `VMInterfaceAddress` (issue #416). A dual-stack NIC carries one row per
/// family. `network` is denormalized from the owning interface so IPAM's
/// used-set query and spec building need no joins, and so its per-network
/// `(network, address)` unique index can serve as the sandbox-side concurrency
/// backstop — IPAM unions this table with `vm_interface_addresses` when reading
/// the used set.
final class SandboxInterfaceAddress: Model, @unchecked Sendable {
    static let schema = "sandbox_interface_addresses"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "interface_id")
    var interface: SandboxNetworkInterface

    /// Logical network name, denormalized from the owning interface so the
    /// IPAM uniqueness index `(network, address)` needs no join.
    @Field(key: "network")
    var network: String

    /// Address family, stored as `IPFamily.rawValue`.
    @Field(key: "family")
    var family: String

    /// The address in canonical text form (no prefix suffix).
    @Field(key: "address")
    var address: String

    @Field(key: "prefix_length")
    var prefixLength: Int

    /// Gateway for this family on the network, denormalized at allocation
    /// time so spec building needs no network lookup.
    @OptionalField(key: "gateway")
    var gateway: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        interfaceID: UUID,
        network: String,
        family: IPFamily,
        address: String,
        prefixLength: Int,
        gateway: String? = nil
    ) {
        self.id = id
        self.$interface.id = interfaceID
        self.network = network
        self.family = family.rawValue
        self.address = address
        self.prefixLength = prefixLength
        self.gateway = gateway
    }

    var ipFamily: IPFamily? { IPFamily(rawValue: family) }
}

extension SandboxInterfaceAddress: Content {}

extension SandboxInterfaceAddress: InterfaceAddressRow {}

/// The per-family address lookups (`ipv4Address`, `ipv6Address`, `ipv4Netmask`)
/// come from `NetworkAddressable`, shared with the VM NIC.
extension SandboxNetworkInterface: NetworkAddressable {
    var allocatedAddresses: [SandboxInterfaceAddress] { $addresses.value ?? [] }
}
