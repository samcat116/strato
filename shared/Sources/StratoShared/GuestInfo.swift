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
    /// Whether the guest agent answered at all during the last probe. `true`
    /// means a `guest-ping`/`guest-sync` round-trip succeeded within its
    /// budget; the address/hostname fields are only meaningful when this is
    /// `true`. A VM with no qga never produces a `GuestInfo` at all, so in
    /// practice this is `true` on every reported struct — it exists so the
    /// control plane can still record a positive liveness signal even when the
    /// follow-up detail queries came back empty.

    /// The guest OS hostname (`guest-get-host-name`), or nil if the guest could
    /// not report one.

    /// The network interfaces the guest actually has configured
    /// (`guest-network-get-interfaces`), keyed for the control plane by each
    /// interface's hardware (MAC) address so it can be matched against the
    /// VM's `VMNetworkInterface` rows. Empty when the guest reported no
    /// interfaces or the query failed.

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

    var _jsonQgaAvailable: Bool {
        get { qgaAvailable }
        set { let value = newValue; qgaAvailable = value }
    }
    var _jsonHostname: String? {
        get { hasHostname ? (hostname) : nil }
        set { if let value = newValue { hostname = value } else { clearHostname() } }
    }
    var _jsonInterfaces: [GuestNetworkInterface] {
        get { interfaces.values }
        set { let value = newValue; interfaces = Strato_Agent_V1_GuestInfoInterfacesSection.with { $0.values = value } }
    }
}

/// One network interface as seen *inside the guest* by qga
/// (`guest-network-get-interfaces`). Distinct from `VMNetworkInterface`, which
/// is the control plane's own record of the NIC it attached: this is what the
/// guest OS reports it did with that NIC.
public typealias GuestNetworkInterface = Strato_Agent_V1_GuestNetworkInterface
extension Strato_Agent_V1_GuestNetworkInterface: Codable {
    /// The guest's name for the interface, e.g. "eth0", "enp0s3", "lo".

    /// The interface's hardware (MAC) address, lowercased and colon-separated
    /// (e.g. "52:54:00:12:34:56"), or nil for interfaces the guest reported
    /// without one (notably loopback). This is the join key the control plane
    /// uses to attribute observed addresses to a `VMNetworkInterface`.

    /// The addresses the guest has configured on this interface. Includes
    /// DHCP/SLAAC/link-local addresses the control plane never allocated, which
    /// is the whole point — nil-nothing here means the guest reported none.

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

    var _jsonName: String {
        get { name }
        set { let value = newValue; name = value }
    }
    var _jsonHardwareAddress: String? {
        get { hasHardwareAddress ? (hardwareAddress) : nil }
        set { if let value = newValue { hardwareAddress = value } else { clearHardwareAddress() } }
    }
    var _jsonAddresses: [GuestIPAddress] {
        get { addresses.values }
        set {
            let value = newValue;
            addresses = Strato_Agent_V1_GuestNetworkInterfaceAddressesSection.with { $0.values = value }
        }
    }
}

/// One IP address configured inside the guest, as reported by qga.
public typealias GuestIPAddress = Strato_Agent_V1_GuestIPAddress
extension Strato_Agent_V1_GuestIPAddress: Codable {
    /// The address family this address belongs to.

    /// The address in its canonical text form (no prefix suffix), e.g.
    /// "192.168.1.42" or "fe80::5054:ff:fe12:3456".

    /// The prefix length (CIDR bits) the guest reported for this address, or
    /// nil if qga did not supply one.

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

    var _jsonFamily: IPFamily {
        get { family }
        set { let value = newValue; family = value }
    }
    var _jsonAddress: String {
        get { address }
        set { let value = newValue; address = value }
    }
    var _jsonPrefixLength: Int? {
        get { hasPrefixLength ? (Int(prefixLength)) : nil }
        set { if let value = newValue { prefixLength = Int64(value) } else { clearPrefixLength() } }
    }
}
