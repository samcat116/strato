import Foundation
import StratoShared

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
    /// Optional IPv6 counterpart of `externalCIDR` — the router gateway port's
    /// address on the provider network, `ip/prefix` (e.g. `2001:db8::2/64`),
    /// also used as the IPv6 SNAT `external_ip`. Additive to the v4 uplink, not
    /// a replacement: `external_cidr` stays required (the gateway port's MAC is
    /// derived from it). Absent means dual-stack networks get v4 egress only.
    public let externalCIDR6: String?
    /// Next hop on the provider network for the router's IPv6 default route.
    /// Absent means no `::/0` route, so v6 egress is limited to the external
    /// subnet even when `externalCIDR6` is set.
    public let gateway6: String?

    public static let defaultBridge = "br-ex"
    public static let defaultPhysnet = "physnet-strato"

    enum CodingKeys: String, CodingKey {
        case externalCIDR = "external_cidr"
        case gateway
        case bridge
        case physnet
        case externalCIDR6 = "external_cidr6"
        case gateway6 = "gateway6"
    }

    public init(
        externalCIDR: String,
        gateway: String? = nil,
        bridge: String = OVNUplinkConfig.defaultBridge,
        physnet: String = OVNUplinkConfig.defaultPhysnet,
        externalCIDR6: String? = nil,
        gateway6: String? = nil
    ) {
        self.externalCIDR = externalCIDR
        self.gateway = gateway
        self.bridge = bridge
        self.physnet = physnet
        self.externalCIDR6 = externalCIDR6
        self.gateway6 = gateway6
    }

    /// The dedicated external IP (host portion of `externalCIDR`), used as the
    /// SNAT `external_ip` and to derive the gateway router port's MAC. Nil when
    /// `externalCIDR` isn't a valid `ip/prefix`.
    public var externalIP: String? {
        let parts = externalCIDR.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let ip = parts.first, IPv4Address(String(ip)) != nil else { return nil }
        return String(ip)
    }

    /// The dedicated external IPv6 address (host portion of `externalCIDR6`),
    /// used as the IPv6 SNAT `external_ip`. Canonicalized to RFC 5952 form so
    /// it compares equal to what OVN reports back and SNAT rules don't churn.
    /// Nil when `externalCIDR6` is absent or isn't a valid `ip/prefix` —
    /// including an out-of-range prefix like `/129`. Parsed through `IPv6CIDR`,
    /// the *same* validation `ensureUplink` uses to decide whether the gateway
    /// router port gets a v6 address: were this laxer, a bad prefix would leave
    /// the port v4-only while SNAT still translated to an address the port
    /// never claimed.
    public var externalIP6: String? {
        guard let externalCIDR6, let cidr6 = IPv6CIDR(externalCIDR6) else { return nil }
        return cidr6.base.description
    }
}
