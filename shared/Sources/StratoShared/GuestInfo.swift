import Foundation
import SwiftProtobuf

/// What the QEMU guest agent (qga) reported about a running VM's guest OS,
/// attached to that VM's `ObservedVMState` on the agent → control-plane
/// observed-state report (issue #563).
///
/// This is a best-effort, informational channel, not a source of truth: qga is
/// *unresponsive whenever the guest is not running the agent*, so the whole
/// struct is absent (`ObservedVMState.guestInfo == nil`) for VMs whose image
/// lacks qga, whose guest is still booting, or whose guest hung — and every
/// field within it is independently optional for the same reason. Readers must
/// tolerate a missing struct and missing pieces rather than assume a complete
/// record.
///
/// The observed addresses here are deliberately distinct from a VM's
/// *allocated* addresses (IPAM's static assignment, or nothing at all on
/// DHCP/SLIRP): only qga can see what the guest actually configured — DHCP
/// leases, manual changes, IPv6 SLAAC addresses — so these are the sole way
/// those addresses become visible to the control plane.
public typealias GuestInfo = Strato_Agent_V1_GuestInfo
extension Strato_Agent_V1_GuestInfo: Codable {

    public init(
        qgaAvailable: Bool,
        hostname: String? = nil,
        interfaces: [GuestNetworkInterface] = []
    ) {
        self.init()
        self._jsonQgaAvailable = qgaAvailable
        self._jsonHostname = hostname
        self._jsonInterfaces = interfaces
    }

    private enum CodingKeys: String, CodingKey { case qgaAvailable; case hostname; case interfaces }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonQgaAvailable = try container.decode(Bool.self, forKey: .qgaAvailable)
        self._jsonHostname = try container.decodeIfPresent(String.self, forKey: .hostname)
        self._jsonInterfaces = try container.decode([GuestNetworkInterface].self, forKey: .interfaces)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonQgaAvailable, forKey: .qgaAvailable)
        try container.encodeIfPresent(_jsonHostname, forKey: .hostname)
        try container.encode(_jsonInterfaces, forKey: .interfaces)
    }

}

/// One network interface as seen *inside the guest* by qga
/// (`guest-network-get-interfaces`). Distinct from `VMNetworkInterface`, which
/// is the control plane's own record of the NIC it attached: this is what the
/// guest OS reports it did with that NIC.
public typealias GuestNetworkInterface = Strato_Agent_V1_GuestNetworkInterface
extension Strato_Agent_V1_GuestNetworkInterface: Codable {

    public init(name: String, hardwareAddress: String? = nil, addresses: [GuestIPAddress] = []) {
        self.init()
        self._jsonName = name
        self._jsonHardwareAddress = hardwareAddress
        self._jsonAddresses = addresses
    }

    private enum CodingKeys: String, CodingKey { case name; case hardwareAddress; case addresses }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonName = try container.decode(String.self, forKey: .name)
        self._jsonHardwareAddress = try container.decodeIfPresent(String.self, forKey: .hardwareAddress)
        self._jsonAddresses = try container.decode([GuestIPAddress].self, forKey: .addresses)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonName, forKey: .name)
        try container.encodeIfPresent(_jsonHardwareAddress, forKey: .hardwareAddress)
        try container.encode(_jsonAddresses, forKey: .addresses)
    }

}

/// One IP address configured inside the guest, as reported by qga.
public typealias GuestIPAddress = Strato_Agent_V1_GuestIPAddress
extension Strato_Agent_V1_GuestIPAddress: Codable {

    public init(family: IPFamily, address: String, prefixLength: Int? = nil) {
        self.init()
        self._jsonFamily = family
        self._jsonAddress = address
        self._jsonPrefixLength = prefixLength
    }

    private enum CodingKeys: String, CodingKey { case family; case address; case prefixLength }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonFamily = try container.decode(IPFamily.self, forKey: .family)
        self._jsonAddress = try container.decode(String.self, forKey: .address)
        self._jsonPrefixLength = try container.decodeIfPresent(Int.self, forKey: .prefixLength)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonFamily, forKey: .family)
        try container.encode(_jsonAddress, forKey: .address)
        try container.encodeIfPresent(_jsonPrefixLength, forKey: .prefixLength)
    }

}
