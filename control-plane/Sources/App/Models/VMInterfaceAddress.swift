import Fluent
import StratoShared
import Vapor

/// One IP address allocated to a NIC. Normalized out of `VMNetworkInterface`
/// so a dual-stack NIC carries one row per family (and the schema permits
/// more than one per family later); code enforces at most one IPv4 and one
/// IPv6 address per interface today.
///
/// `address` is stored in canonical text form — dotted quad for IPv4,
/// RFC 5952 for IPv6 — because the per-network uniqueness index compares
/// strings. `logicalNetwork` and `gateway` are denormalized at allocation time
/// so IPAM's used-set query and spec building need no joins.
final class VMInterfaceAddress: Model, @unchecked Sendable {
    static let schema = "vm_interface_addresses"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "interface_id")
    var interface: VMNetworkInterface

    /// The logical network the address came from, denormalized from the owning
    /// interface so the IPAM uniqueness index `(logical_network_id, address)`
    /// needs no join.
    @Parent(key: "logical_network_id")
    var logicalNetwork: LogicalNetwork

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
        logicalNetworkID: UUID,
        family: IPFamily,
        address: String,
        prefixLength: Int,
        gateway: String? = nil
    ) {
        self.id = id
        self.$interface.id = interfaceID
        self.$logicalNetwork.id = logicalNetworkID
        self.family = family.rawValue
        self.address = address
        self.prefixLength = prefixLength
        self.gateway = gateway
    }

    var ipFamily: IPFamily? { IPFamily(rawValue: family) }
}

extension VMInterfaceAddress: Content {}

extension VMInterfaceAddress: InterfaceAddressRow {}

/// The per-family address lookups (`ipv4Address`, `ipv6Address`, `ipv4Netmask`)
/// come from `NetworkAddressable`, shared with the sandbox NIC.
extension VMNetworkInterface: NetworkAddressable {
    var allocatedAddresses: [VMInterfaceAddress] { $addresses.value ?? [] }
    var logicalNetworkID: UUID { $logicalNetwork.id }
}
