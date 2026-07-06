import Foundation

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

    public init(
        network: String,
        attachment: NetworkAttachment,
        macAddress: String? = nil,
        ipAddress: String? = nil,
        netmask: String? = nil,
        gateway: String? = nil,
        mtu: Int? = nil
    ) {
        self.network = network
        self.attachment = attachment
        self.macAddress = macAddress
        self.ipAddress = ipAddress
        self.netmask = netmask
        self.gateway = gateway
        self.mtu = mtu
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

/// Minimal IPv4 address value for subnet math (Foundation has no portable one).
public struct IPv4Address: CustomStringConvertible, Equatable, Sendable {
    public let raw: UInt32

    public init(raw: UInt32) {
        self.raw = raw
    }

    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else { return nil }
            value = (value << 8) | UInt32(octet)
        }
        self.raw = value
    }

    /// The prefix length when this address is a contiguous netmask
    /// (e.g. 255.255.255.0 → 24); nil for non-contiguous masks.
    public var prefixLength: Int? {
        let ones = raw.nonzeroBitCount
        // A valid mask is `ones` set bits followed only by zeros.
        guard raw == (ones == 0 ? 0 : ~UInt32(0) << (32 - ones)) else { return nil }
        return ones
    }

    public var description: String {
        "\((raw >> 24) & 0xff).\((raw >> 16) & 0xff).\((raw >> 8) & 0xff).\(raw & 0xff)"
    }
}
