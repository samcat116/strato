import StratoShared

/// One allocated address row on a NIC, as `VMInterfaceAddress` and
/// `SandboxInterfaceAddress` both model it. Abstracted so the address lookups
/// and wire-spec construction shared by VMs and sandboxes are written once
/// (issue #597).
protocol InterfaceAddressRow {
    /// Address family, stored as `IPFamily.rawValue`.
    var family: String { get }
    /// The address in canonical text form (no prefix suffix).
    var address: String { get }
    var prefixLength: Int { get }
    var gateway: String? { get }
}

/// A NIC whose addressing comes from per-family address rows: `VMNetworkInterface`
/// and `SandboxNetworkInterface`. Supplies everything `NetworkSpec.build` needs,
/// so neither spec builder has to reimplement the field mapping.
protocol NetworkAddressable {
    associatedtype AddressRow: InterfaceAddressRow

    /// Logical network name the NIC attaches to.
    var network: String { get }
    var macAddress: String { get }
    var mtu: Int? { get }
    /// The allocated address rows; requires `addresses` to be eager-loaded.
    var allocatedAddresses: [AddressRow] { get }
}

extension NetworkAddressable {
    /// The interface's IPv4 address row, when one is allocated. At most one
    /// exists per family (enforced in code, not schema). Requires `addresses`
    /// to be eager-loaded.
    var ipv4Address: AddressRow? {
        allocatedAddresses.first { $0.family == IPFamily.ipv4.rawValue }
    }

    /// The interface's IPv6 address row, when one is allocated. Requires
    /// `addresses` to be eager-loaded.
    var ipv6Address: AddressRow? {
        allocatedAddresses.first { $0.family == IPFamily.ipv6.rawValue }
    }

    /// Dotted-quad netmask derived from the IPv4 address row's prefix, for
    /// wire compatibility (`NetworkSpec.netmask` predates prefix lengths).
    var ipv4Netmask: String? {
        guard let prefix = ipv4Address?.prefixLength, (0...32).contains(prefix) else { return nil }
        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix)
        return IPv4Address(raw: mask).description
    }
}
