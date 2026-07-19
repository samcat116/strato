import Foundation

/// Operator-provided configuration for OVN native dynamic routing (issue
/// #344): north-south advertisement of NAT external IPs (floating IPs) and
/// connected routes over BGP, via OVN's `dynamic-routing*` options plus an
/// FRR daemon on the egress host. OVN itself never speaks BGP — with
/// `dynamic-routing=true` on a router, `ovn-northd` fills the southbound
/// `Advertised_Route` table, `ovn-controller` installs those routes into a
/// Linux VRF, and FRR (`redistribute connected` in that VRF) advertises them
/// to the fabric. Requires OVN ≥ 25.03 on the host; FRR configuration is the
/// operator's, out of band (see `docs/architecture/networking.md`).
///
/// Applied by the site's topology-authority agent to every uplinked router it
/// reconciles. When absent or `enabled = false`, the agent strips any
/// `dynamic-routing*` options it previously set (level-triggered, like every
/// other network reconcile step).
public struct OVNDynamicRoutingConfig: Sendable, Equatable, Codable {
    /// Master switch. False keeps the section inert while preserving it in
    /// the config file.
    public let enabled: Bool
    /// What the router redistributes into the fabric
    /// (`dynamic-routing-redistribute`). Values from
    /// `allowedRedistributeValues`; `nat` is what advertises floating IPs.
    public let redistribute: [String]
    /// The VRF `ovn-controller` maintains the advertised routes in
    /// (`dynamic-routing-vrf-name`). Nil uses OVN's default (`ovnvrf<n>` from
    /// the VRF id). FRR must be configured against the same VRF either way.
    public let vrfName: String?
    /// Whether `ovn-controller` creates/maintains the VRF netdev itself
    /// (`dynamic-routing-maintain-vrf` on the gateway port). False expects the
    /// operator (or FRR) to have created it.
    public let maintainVRF: Bool
    /// Routing-protocol traffic the gateway port punts to the local host for
    /// FRR (`routing-protocols`). Values from `allowedRoutingProtocols`.
    public let routingProtocols: [String]

    public static let allowedRedistributeValues: Set<String> = [
        "connected", "connected-as-host", "static", "nat", "lb",
    ]
    public static let allowedRoutingProtocols: Set<String> = ["BGP", "BFD"]

    /// Advertise connected tenant subnets and NAT external IPs (floating IPs)
    /// by default — the issue #344 use case.
    public static let defaultRedistribute = ["connected", "nat"]
    public static let defaultRoutingProtocols = ["BGP"]

    enum CodingKeys: String, CodingKey {
        case enabled
        case redistribute
        case vrfName = "vrf_name"
        case maintainVRF = "maintain_vrf"
        case routingProtocols = "routing_protocols"
    }

    public init(
        enabled: Bool,
        redistribute: [String] = OVNDynamicRoutingConfig.defaultRedistribute,
        vrfName: String? = nil,
        maintainVRF: Bool = true,
        routingProtocols: [String] = OVNDynamicRoutingConfig.defaultRoutingProtocols
    ) {
        self.enabled = enabled
        self.redistribute = redistribute
        self.vrfName = vrfName
        self.maintainVRF = maintainVRF
        self.routingProtocols = routingProtocols
    }

    /// The values in `redistribute`/`routingProtocols` that OVN does not
    /// accept, for load-time rejection: a typo silently dropped here would
    /// read as "BGP is on" while advertising nothing.
    public var invalidValues: [String] {
        redistribute.filter { !Self.allowedRedistributeValues.contains($0) }
            + routingProtocols.filter { !Self.allowedRoutingProtocols.contains($0) }
    }
}
