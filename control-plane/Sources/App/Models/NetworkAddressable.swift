import Foundation
import StratoShared

/// One allocated address row on a NIC. Abstracted so the address lookups
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

extension VMNetworkInterface: NetworkAddressable {
    var allocatedAddresses: [InterfaceAddressSnapshot] { loadedAddresses ?? [] }
    var networkInterfaceID: UUID? { id }
    var networkDeviceName: String? { deviceName }
    var networkOrderIndex: Int? { orderIndex }
}

extension SandboxNetworkInterface: NetworkAddressable {
    var allocatedAddresses: [InterfaceAddressSnapshot] { loadedAddresses ?? [] }
}

/// A NIC whose addressing comes from per-family address rows: `VMNetworkInterface`
/// and `SandboxNetworkInterface`. Supplies everything `NetworkSpec.build` needs,
/// so neither spec builder has to reimplement the field mapping.
protocol NetworkAddressable {
    associatedtype AddressRow: InterfaceAddressRow

    /// Id of the logical network the NIC attaches to; the row itself is looked
    /// up by the caller, since names identify a network only within a project
    /// (issue #765).
    var logicalNetworkID: UUID { get }
    var macAddress: String { get }
    var mtu: Int? { get }
    var networkInterfaceID: UUID? { get }
    var networkDeviceName: String? { get }
    var networkOrderIndex: Int? { get }
    /// The allocated address rows; requires `addresses` to be eager-loaded.
    var allocatedAddresses: [AddressRow] { get }
}

extension NetworkAddressable {
    var networkInterfaceID: UUID? { nil }
    var networkDeviceName: String? { nil }
    var networkOrderIndex: Int? { nil }

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
