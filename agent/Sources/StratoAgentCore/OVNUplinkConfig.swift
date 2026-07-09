import Foundation

/// Operator-provided configuration for the site uplink OVN SNAT egress uses
/// (issue #342). SNAT needs a **dedicated** external IP on the provider
/// network — distinct from the host's own address, which the distributed OVN
/// router cannot claim without an ARP/address conflict — so this is explicit
/// config, never auto-detected from the host's default route. When absent, the
/// agent still realizes routers and cross-switch east-west, but no uplink or
/// SNAT (a network's `externalAccess` has no effect until it is configured).
public struct OVNUplinkConfig: Sendable, Equatable, Codable {
    /// The router gateway port's address on the provider network, `ip/prefix`
    /// (e.g. `203.0.113.2/24`). Must be an address the host does NOT own — it is
    /// also used as the SNAT `external_ip`.
    public let externalCIDR: String
    /// Next hop on the provider network for the router's default route. Without
    /// it the router has only its connected routes, so off-subnet egress fails.
    public let gateway: String?
    /// OVS provider bridge carrying the external network. Defaults to `br-ex`.
    public let bridge: String
    /// OVN physnet name mapped to `bridge`. Defaults to `physnet-strato`.
    public let physnet: String

    public static let defaultBridge = "br-ex"
    public static let defaultPhysnet = "physnet-strato"

    enum CodingKeys: String, CodingKey {
        case externalCIDR = "external_cidr"
        case gateway
        case bridge
        case physnet
    }

    public init(
        externalCIDR: String,
        gateway: String? = nil,
        bridge: String = OVNUplinkConfig.defaultBridge,
        physnet: String = OVNUplinkConfig.defaultPhysnet
    ) {
        self.externalCIDR = externalCIDR
        self.gateway = gateway
        self.bridge = bridge
        self.physnet = physnet
    }

    /// The dedicated external IP (host portion of `externalCIDR`), used as the
    /// SNAT `external_ip` and to derive the gateway router port's MAC. Nil when
    /// `externalCIDR` isn't a valid `ip/prefix`.
    public var externalIP: String? {
        let parts = externalCIDR.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let ip = parts.first, IPv4Address(String(ip)) != nil else { return nil }
        return String(ip)
    }
}
