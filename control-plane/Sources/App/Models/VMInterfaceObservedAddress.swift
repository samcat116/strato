import Fluent
import StratoShared
import Vapor

/// One IP address the guest actually has configured on a NIC, as reported by
/// the QEMU guest agent (issue #563). The observed counterpart of
/// `VMInterfaceAddress` (which records what IPAM *allocated*): these are what
/// the guest OS itself reports — DHCP leases, IPv6 SLAAC/link-local, and any
/// manual changes — so a NIC may carry several per family, unlike the
/// one-per-family allocated rows.
///
/// The control plane reconciles these rows against each observed-state report
/// keyed by MAC, so they reflect the guest's current view rather than a
/// point-in-time allocation.
final class VMInterfaceObservedAddress: Model, @unchecked Sendable {
    static let schema = "vm_interface_observed_addresses"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "interface_id")
    var interface: VMNetworkInterface

    /// Address family, stored as `IPFamily.rawValue`.
    @Field(key: "family")
    var family: String

    /// The address in canonical text form (no prefix suffix).
    @Field(key: "address")
    var address: String

    /// The prefix length (CIDR bits) the guest reported, when it supplied one.
    @OptionalField(key: "prefix_length")
    var prefixLength: Int?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        interfaceID: UUID,
        family: IPFamily,
        address: String,
        prefixLength: Int? = nil
    ) {
        self.id = id
        self.$interface.id = interfaceID
        self.family = family.rawValue
        self.address = address
        self.prefixLength = prefixLength
    }

    var ipFamily: IPFamily? { IPFamily(rawValue: family) }
}

extension VMInterfaceObservedAddress: Content {}
