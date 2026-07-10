import Fluent
import Vapor

/// A logical network VMs attach to, and the unit of IPAM ownership: the control
/// plane allocates NIC addresses from a network's subnet and pushes them down to
/// agents in the `VMSpec` (issue #212). Agents realize the network on their
/// platform (OVN logical switch on Linux, user-mode on macOS) by name.
///
/// Names are globally unique — `VMNetworkInterface` rows, the IPAM uniqueness
/// index, and agent realization all key on the name string, not the row id.
/// Networks with a nil `project` are global (the seeded "default" network);
/// per-project name scoping would require migrating NIC references to an FK
/// and is deferred.
final class LogicalNetwork: Model, @unchecked Sendable {
    static let schema = "logical_networks"

    /// Name of the network every VM's default NIC lands on. Seeded at migration
    /// time; the subnet/gateway match what agents historically hardcoded so
    /// existing deployments keep their addressing.
    static let defaultNetworkName = "default"

    @ID(key: .id)
    var id: UUID?

    /// Unique name agents use to find or create the network.
    @Field(key: "name")
    var name: String

    /// Subnet in CIDR notation (e.g. "192.168.1.0/24"). IPs are allocated from
    /// its host range.
    @Field(key: "subnet")
    var subnet: String

    /// Gateway address inside the subnet; excluded from allocation and pushed
    /// to guests via the VM spec. Changing it only affects future allocations:
    /// existing NICs carry a denormalized copy.
    @OptionalField(key: "gateway")
    var gateway: String?

    /// IPv6 subnet in canonical CIDR notation (always a /64), when the network
    /// is dual-stack. New networks default to a generated RFC 4193 ULA /64;
    /// nil means v4-only (explicit opt-out, or a network predating IPv6).
    @OptionalField(key: "subnet6")
    var subnet6: String?

    /// IPv6 gateway (the router-port address) inside `subnet6`; excluded from
    /// allocation and announced to guests via Router Advertisements.
    @OptionalField(key: "gateway6")
    var gateway6: String?

    /// When true, agents program OVN's native DHCP responder to deliver the
    /// control-plane-allocated IP, gateway, DNS, and MTU to guests, and cloud-init
    /// omits static L3 config. When false, guests are configured statically via
    /// cloud-init (the pre-DHCP behavior, and the fallback for non-OVN platforms).
    @Field(key: "dhcp_enabled")
    var dhcpEnabled: Bool

    /// DNS resolvers advertised to guests over DHCP, stored comma-separated.
    /// Use `dnsServers` for the parsed list.
    @OptionalField(key: "dns_servers")
    var dnsServersRaw: String?

    /// DNS search domain advertised over DHCP (`domain_name` option).
    @OptionalField(key: "domain_name")
    var domainName: String?

    /// DHCP lease time in seconds (`lease_time` option). Agents apply a default
    /// when nil.
    @OptionalField(key: "lease_time")
    var leaseTime: Int?

    /// When true, agents attach the network to its project's logical router and
    /// program outbound SNAT to the host uplink (issue #342), giving VMs internet
    /// access. False keeps the network internal (L3 gateway only, no egress).
    /// The uplink IP is auto-detected on the agent — no operator config yet.
    @Field(key: "external_access")
    var externalAccess: Bool

    /// Monotonic counter bumped whenever a change alters how agents realize the
    /// network's L3 (subnet, gateway, or external access). Sent to agents as the
    /// `DesiredNetworkState.generation` so replayed/reordered syncs can't roll
    /// the network's realization backward.
    @Field(key: "generation")
    var generation: Int

    /// Project this network belongs to; nil means global (visible to everyone,
    /// managed by system admins only).
    @OptionalParent(key: "project_id")
    var project: Project?

    /// Site (availability zone) this network is pinned to. A pinned network's
    /// VMs may only place on that site's agents, where the shared OVN
    /// deployment lets one logical switch span nodes over geneve. Nil means
    /// unpinned: the legacy model, where the same name on different agents is
    /// disconnected segments sharing an IP pool — only safe single-node.
    @OptionalParent(key: "site_id")
    var site: Site?

    /// User who created the network; nil for seeded networks.
    @OptionalParent(key: "created_by_id")
    var createdBy: User?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        name: String,
        subnet: String,
        gateway: String? = nil,
        subnet6: String? = nil,
        gateway6: String? = nil,
        projectID: UUID? = nil,
        createdByID: UUID? = nil,
        dhcpEnabled: Bool = true,
        dnsServers: [String] = [],
        domainName: String? = nil,
        leaseTime: Int? = nil,
        externalAccess: Bool = true,
        generation: Int = 1,
        siteID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.subnet = subnet
        self.gateway = gateway
        self.subnet6 = subnet6
        self.gateway6 = gateway6
        self.$project.id = projectID
        self.$site.id = siteID
        self.$createdBy.id = createdByID
        self.dhcpEnabled = dhcpEnabled
        self.dnsServersRaw = LogicalNetwork.joinDNS(dnsServers)
        self.domainName = domainName
        self.leaseTime = leaseTime
        self.externalAccess = externalAccess
        self.generation = generation
    }

    /// The identity of the logical router this network attaches to on agents.
    /// Per-project so a project's networks share one router (cross-switch
    /// east-west); a project-less (global) network keys on its own id and gets a
    /// dedicated router. Opaque to agents — see `DesiredNetworkState.routerKey`.
    ///
    /// Split by `externalAccess`: a project's egress networks share one router
    /// (with the uplink), and its no-egress networks share a separate `-internal`
    /// router with no uplink — so `externalAccess=false` guests provably have no
    /// route to the internet, honoring the contract (issue #342). The tradeoff:
    /// an egress and a no-egress network in the same project are on different
    /// routers, so they don't route to each other (per-network egress policy that
    /// preserves that east-west is a follow-up).
    var routerKey: String {
        if let projectID = $project.id {
            let scope = externalAccess ? "" : "-internal"
            return "project-\(projectID.uuidString)\(scope)"
        }
        return "network-\(id?.uuidString ?? name)"
    }

    /// Parsed DNS resolver list, backed by the comma-separated `dns_servers` column.
    var dnsServers: [String] {
        get { LogicalNetwork.splitDNS(dnsServersRaw) }
        set { dnsServersRaw = LogicalNetwork.joinDNS(newValue) }
    }

    static func splitDNS(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func joinDNS(_ servers: [String]) -> String? {
        let cleaned =
            servers
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return cleaned.isEmpty ? nil : cleaned.joined(separator: ",")
    }
}

extension LogicalNetwork: Content {}

// MARK: - Request/Response DTOs

struct CreateNetworkRequest: Content {
    let name: String
    /// Subnet in CIDR notation; prefix must be within /8–/30.
    let subnet: String
    /// Defaults to the subnet's first host address when omitted.
    let gateway: String?
    /// IPv6 subnet (must be a /64). When omitted and IPv6 isn't disabled, a
    /// unique-local (ULA) /64 is generated — new networks default dual-stack.
    let subnet6: String?
    /// Defaults to the IPv6 subnet's first host address (`<prefix>::1`).
    let gateway6: String?
    /// Pass false for a v4-only network (subnet6 must then be omitted).
    let ipv6Enabled: Bool?
    /// Defaults to the caller's default project when omitted.
    let projectId: UUID?
    /// Whether agents program OVN DHCP for this network. Defaults true.
    let dhcpEnabled: Bool?
    /// DNS resolvers advertised over DHCP.
    let dnsServers: [String]?
    /// DNS search domain advertised over DHCP.
    let domainName: String?
    /// DHCP lease time in seconds.
    let leaseTime: Int?
    /// Whether the network gets outbound SNAT to the host uplink. Defaults true.
    let externalAccess: Bool?
    /// Site to pin the network to; its VMs then only place on that site's
    /// agents, where the shared OVN deployment spans it across nodes.
    let siteId: UUID?

    // Explicit init so the DHCP fields default when omitted (e.g. in tests) while
    // JSON decoding still populates them via the synthesized Codable conformance.
    init(
        name: String, subnet: String, gateway: String? = nil, subnet6: String? = nil,
        gateway6: String? = nil, ipv6Enabled: Bool? = nil, projectId: UUID? = nil,
        dhcpEnabled: Bool? = nil, dnsServers: [String]? = nil, domainName: String? = nil,
        leaseTime: Int? = nil, externalAccess: Bool? = nil, siteId: UUID? = nil
    ) {
        self.name = name
        self.subnet = subnet
        self.gateway = gateway
        self.subnet6 = subnet6
        self.gateway6 = gateway6
        self.ipv6Enabled = ipv6Enabled
        self.projectId = projectId
        self.dhcpEnabled = dhcpEnabled
        self.dnsServers = dnsServers
        self.domainName = domainName
        self.leaseTime = leaseTime
        self.externalAccess = externalAccess
        self.siteId = siteId
    }
}

struct UpdateNetworkRequest: Content {
    /// Rejected while any VM interface references the network.
    let name: String?
    /// Rejected while any VM interface references the network.
    let subnet: String?
    /// May change anytime, but only affects future allocations.
    let gateway: String?
    /// Adding IPv6 to a v4-only network is allowed anytime (existing NICs stay
    /// v4; future allocations get both). Changing an established subnet6 is
    /// rejected while any v6 address is allocated on the network.
    let subnet6: String?
    let gateway6: String?
    /// Pass false to remove IPv6 from the network (rejected while any v6
    /// address is allocated); pass true with no subnet6 to enable IPv6 with a
    /// generated ULA /64.
    let ipv6Enabled: Bool?
    /// DHCP settings; applied to the network and re-synced to affected agents.
    let dhcpEnabled: Bool?
    let dnsServers: [String]?
    let domainName: String?
    let leaseTime: Int?
    /// Toggle outbound SNAT. Re-synced to agents, which add/remove the SNAT rule.
    let externalAccess: Bool?

    init(
        name: String? = nil, subnet: String? = nil, gateway: String? = nil,
        subnet6: String? = nil, gateway6: String? = nil, ipv6Enabled: Bool? = nil,
        dhcpEnabled: Bool? = nil, dnsServers: [String]? = nil, domainName: String? = nil,
        leaseTime: Int? = nil, externalAccess: Bool? = nil
    ) {
        self.name = name
        self.subnet = subnet
        self.gateway = gateway
        self.subnet6 = subnet6
        self.gateway6 = gateway6
        self.ipv6Enabled = ipv6Enabled
        self.dhcpEnabled = dhcpEnabled
        self.dnsServers = dnsServers
        self.domainName = domainName
        self.leaseTime = leaseTime
        self.externalAccess = externalAccess
    }
}

struct NetworkResponse: Content {
    let id: UUID?
    let name: String
    let subnet: String
    let gateway: String?
    let subnet6: String?
    let gateway6: String?
    let projectId: UUID?
    let isDefault: Bool
    let attachedInterfaceCount: Int
    let dhcpEnabled: Bool
    let dnsServers: [String]
    let domainName: String?
    let leaseTime: Int?
    let externalAccess: Bool
    let siteId: UUID?
    let createdAt: Date?
    let updatedAt: Date?

    init(from network: LogicalNetwork, attachedInterfaceCount: Int) {
        self.id = network.id
        self.name = network.name
        self.subnet = network.subnet
        self.gateway = network.gateway
        self.subnet6 = network.subnet6
        self.gateway6 = network.gateway6
        self.projectId = network.$project.id
        self.isDefault = network.name == LogicalNetwork.defaultNetworkName
        self.attachedInterfaceCount = attachedInterfaceCount
        self.dhcpEnabled = network.dhcpEnabled
        self.dnsServers = network.dnsServers
        self.domainName = network.domainName
        self.leaseTime = network.leaseTime
        self.externalAccess = network.externalAccess
        self.siteId = network.$site.id
        self.createdAt = network.createdAt
        self.updatedAt = network.updatedAt
    }
}
