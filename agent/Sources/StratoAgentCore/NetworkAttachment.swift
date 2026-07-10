import Foundation
import StratoShared

/// IP address math lives in StratoShared so the control plane's IPAM and the
/// agent share one implementation; the alias keeps existing call sites.
public typealias IPv4Address = StratoShared.IPv4Address

/// How a VM's NIC is realized on this host, as resolved by the platform network
/// service. Hypervisor drivers translate the descriptor into their native
/// configuration (QEMU netdev arguments, Firecracker API calls) and reject
/// kinds their backend cannot realize — Firecracker, for example, only
/// supports `.tap`.
///
/// This replaces the old `tapInterface: String` field whose `"n/a"` sentinel
/// every driver had to know about. New backends (vmnet on macOS, vhost-user)
/// become new cases here rather than new sentinels.
public enum NetworkAttachment: Codable, Sendable, Equatable {
    /// A kernel TAP device (created and bridged by the network service) the
    /// hypervisor should open by name.
    case tap(interface: String)
    /// Hypervisor-internal user-mode (SLIRP) networking; nothing exists on the
    /// host for this attachment.
    case userMode

    /// True for a host TAP device — the only attachment OVN's DHCP responder can
    /// serve (user-mode NICs are addressed by the hypervisor's own SLIRP DHCP).
    public var isTap: Bool {
        if case .tap = self { return true }
        return false
    }
}

/// One NIC of a VM after the network service has realized it on this host:
/// the typed attachment plus the addressing the hypervisor driver and guest
/// provisioning need. This is what drivers consume — they never talk to the
/// network service themselves.
public struct ResolvedNetworkAttachment: Sendable {
    /// Logical network name from the spec.
    public let network: String
    /// How the hypervisor should realize this NIC.
    public let attachment: NetworkAttachment
    public let macAddress: String?
    /// Static IP pushed down by the control plane (or recovered from an
    /// existing port), when one exists.
    public let ipAddress: String?
    public let netmask: String?
    public let gateway: String?
    public let mtu: Int?
    /// When true, this NIC's L3 config is delivered by the network's DHCP
    /// responder (OVN), so guest provisioning omits static addressing and lets
    /// the guest DHCP instead.
    public let dhcpEnabled: Bool
    /// DNS resolvers for this NIC. Delivered over DHCP when `dhcpEnabled`;
    /// otherwise written into the static guest config as `nameservers`.
    public let dnsServers: [String]

    public init(
        network: String,
        attachment: NetworkAttachment,
        macAddress: String? = nil,
        ipAddress: String? = nil,
        netmask: String? = nil,
        gateway: String? = nil,
        mtu: Int? = nil,
        dhcpEnabled: Bool = false,
        dnsServers: [String] = []
    ) {
        self.network = network
        self.attachment = attachment
        self.macAddress = macAddress
        self.ipAddress = ipAddress
        self.netmask = netmask
        self.gateway = gateway
        self.mtu = mtu
        self.dhcpEnabled = dhcpEnabled
        self.dnsServers = dnsServers
    }
}

/// Derives the network CIDR (e.g. "192.168.1.0/24") from an interface's IP
/// and dotted-quad netmask. Nil when either part is missing or unparsable.
public func subnetCIDR(ipAddress: String?, netmask: String?) -> String? {
    guard let ipAddress, let netmask,
        let ip = IPv4Address(ipAddress),
        let mask = IPv4Address(netmask),
        let prefix = mask.prefixLength
    else {
        return nil
    }
    let network = IPv4Address(raw: ip.raw & mask.raw)
    return "\(network)/\(prefix)"
}
