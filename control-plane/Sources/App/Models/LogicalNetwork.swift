import Fluent
import StratoShared
import Vapor

/// A logical network VMs attach to, and the unit of IPAM ownership: the control
/// plane allocates NIC addresses from a network's subnet and pushes them down to
/// agents in the `VMSpec` (issue #212). Agents realize the network on their
/// platform (OVN logical switch on Linux, user-mode on macOS), naming their
/// objects after the row id.
///
/// Every network belongs to exactly one project, and everything that identifies
/// one — NIC rows, address rows, the IPAM uniqueness index and lock, the agent's
/// OVN object names — keys on the row id (issue #765). The name is a display
/// label, unique only within its project, so two tenants can each own a network
/// called "default" without sharing an L2 domain or an IP pool.
final class LogicalNetwork: Model, @unchecked Sendable {
    static let schema = "logical_networks"

    /// Hard cap on resolvers advertised over DHCP. Well above anything a
    /// resolver stack reads (glibc's `resolv.conf` stops at three) and still
    /// under what DHCP option 6 can carry — its length byte tops out at 63
    /// IPv4 addresses, so a longer list could not be programmed anyway.
    static let maxDNSServers = 32

    @ID(key: .id)
    var id: UUID?

    /// Display name, unique within the owning project. Not an identifier: use
    /// the row id to reference a network.
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

    /// When true, agents publish the link-local instance metadata service to
    /// this network's guests — an OVN `localport` on the network's logical
    /// switch, terminated in a per-network namespace on every chassis running
    /// one of its NICs (STR-49).
    ///
    /// An opt-*out*, defaulting true: the metadata service replaces the
    /// boot-time seed ISO rather than supplementing it. Editing it deliberately
    /// does **not** bump `generation` — the metadata port converges
    /// level-triggered on every network reconcile, exactly like the DHCP rows.
    @Field(key: "metadata_enabled")
    var metadataEnabled: Bool

    /// When true, agents give this network's guests a DNS resolver at
    /// `NetworkResolverEndpoint` — the host-wide CoreDNS each agent runs in its
    /// *host* namespace (ADR 0008), serving the network's zones in full
    /// (including the CNAME/TXT/SRV the OVN `DNS` table cannot express) and
    /// forwarding everything else to `dnsServers` (STR-40).
    ///
    /// **This changes what `dnsServers` means for the network.** With the
    /// resolver on, guests are told the resolver's link-local address over DHCP
    /// and `dnsServers` becomes the resolver's upstream forwarders; with it off,
    /// `dnsServers` is handed to guests verbatim, which is what it always was.
    ///
    /// An opt-*out*, defaulting true, like `metadataEnabled` — see
    /// `AddResolverEnabledToLogicalNetwork` for why that is safe. The short
    /// version: the resolver forwards through the *hypervisor's* egress, so a
    /// network whose `dnsServers` already worked keeps working and one with no
    /// external access at all starts being able to resolve public names, which
    /// is the bug this phase was filed for. And the control plane withholds the
    /// flag entirely unless every agent in the site reports `resolverCapable`,
    /// so a site that cannot run CoreDNS is unaffected by the default until it
    /// can.
    ///
    /// Editing it deliberately does **not** bump `generation` — the port and the
    /// DHCP row converge level-triggered on every network reconcile.
    @Field(key: "resolver_enabled")
    var resolverEnabled: Bool

    /// The index this network's two link-local resolver addresses derive from
    /// (`NetworkResolverEndpoint`), allocated fleet-wide by
    /// `ResolverAddressAllocator`.
    ///
    /// Nil until the resolver is first enabled, and **kept** if it is later
    /// disabled: the addresses live in the host namespace where every network's
    /// resolver shares one namespace, so reusing an index while some agent still
    /// has the old interface configured would put two networks on one address.
    /// Holding it costs one number out of 65k and makes re-enabling free of any
    /// guest-visible change.
    @OptionalField(key: "resolver_index")
    var resolverIndex: Int?

    /// Monotonic counter bumped whenever a change alters how agents realize the
    /// network's L3 (subnet, gateway, or external access). Sent to agents as the
    /// `DesiredNetworkState.generation` so replayed/reordered syncs can't roll
    /// the network's realization backward.
    @Field(key: "generation")
    var generation: Int

    /// Project that owns this network. Required since issue #765: a network is
    /// a tenant-scoped resource, and the project is what its name, its IP pool
    /// and its logical router are scoped by.
    @Parent(key: "project_id")
    var project: Project

    /// Site (availability zone) this network is pinned to. The network's
    /// VMs may only place on that site's agents, where the shared OVN
    /// deployment lets one logical switch span nodes over geneve.
    @Parent(key: "site_id")
    var site: Site

    /// The zone VMs on this network **auto-register into** (issue #770) — the
    /// zone their derived `<hostname>.<zone>` and PTR records land in. Must be
    /// one of the network's attached zones (`DNSZoneNetwork`), which keeps
    /// derived-record placement unambiguous while attachment stays
    /// many-to-many. Nil is the ordinary case for a network that resolves
    /// zones without registering into any of them.
    @OptionalParent(key: "primary_dns_zone_id")
    var primaryDNSZone: DNSZone?

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
        projectID: UUID,
        createdByID: UUID? = nil,
        dhcpEnabled: Bool = true,
        dnsServers: [String] = [],
        domainName: String? = nil,
        leaseTime: Int? = nil,
        externalAccess: Bool = true,
        metadataEnabled: Bool = true,
        resolverEnabled: Bool = true,
        resolverIndex: Int? = nil,
        generation: Int = 1,
        siteID: UUID
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
        self.metadataEnabled = metadataEnabled
        self.resolverEnabled = resolverEnabled
        self.resolverIndex = resolverIndex
        self.generation = generation
    }

    /// The addresses to put on the wire for this network's resolver, or nil when
    /// it is off, has never been allocated one, or the receiver has no opinion.
    ///
    /// Nil and "enabled but unallocated" are deliberately the same answer: an
    /// address the control plane has not committed to is one no agent should
    /// realize, and the allocation happens on the write that turns the flag on,
    /// so the pair is missing only for a row that predates this feature.
    func resolverAddressesIfEnabled(siteCapable: Bool?) -> [String]? {
        guard siteCapable == true, resolverEnabled, let index = resolverIndex else { return nil }
        return [
            NetworkResolverEndpoint.address(forIndex: index),
            NetworkResolverEndpoint.addressV6(forIndex: index),
        ]
    }

    /// The identity of the logical router this network attaches to on agents.
    /// Per-project, so a project's networks share one router (cross-switch
    /// east-west) and no two tenants ever share one — which is what makes it
    /// safe for two projects to use the same subnet. Opaque to agents — see
    /// `DesiredNetworkState.routerKey`.
    ///
    /// Split by `externalAccess`: a project's egress networks share one router
    /// (with the uplink), and its no-egress networks share a separate `-internal`
    /// router with no uplink — so `externalAccess=false` guests provably have no
    /// route to the internet, honoring the contract (issue #342). The tradeoff:
    /// an egress and a no-egress network in the same project are on different
    /// routers, so they don't route to each other (per-network egress policy that
    /// preserves that east-west is a follow-up).
    var routerKey: String {
        let scope = externalAccess ? "" : "-internal"
        return "project-\($project.id.uuidString)\(scope)"
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

struct CreateNetworkRequest: Content, ValidatedRequestBody {
    /// Bounded, not just non-empty (STR-195): this name leaves the database.
    /// It rides `DesiredNetworkState.name` to the topology authority, which
    /// writes it into OVN NB `DHCP_Options.external_ids` and then *reads it
    /// back* to decide which DHCP rows this network owns
    /// (`DHCPRowIdentity.isLegacyOwned`). An identity key in the datapath's
    /// control database is not somewhere to put an unbounded string.
    var name: String
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
    /// Required: there is no default project (issue #1059). Optional here so
    /// the refusal is `Request.projectIsRequired`'s, which names the remedy,
    /// rather than a `Codable` decode failure that names neither.
    let projectId: UUID?
    /// Whether agents program OVN DHCP for this network. Defaults true.
    let dhcpEnabled: Bool?
    /// With `resolverEnabled` (the default) these are the network resolver's
    /// upstream forwarders; without it they are advertised to guests over DHCP
    /// verbatim.
    let dnsServers: [String]?
    /// DNS search domain advertised over DHCP. Held to the same grammar as a
    /// DNS zone name — it reaches guests as structured config, not as text.
    let domainName: String?
    /// DHCP lease time in seconds.
    let leaseTime: Int?
    /// Whether the network gets outbound SNAT to the host uplink. Defaults true.
    let externalAccess: Bool?
    /// Whether the network publishes the instance metadata service to its
    /// guests. Defaults true — an opt-out, not an opt-in.
    let metadataEnabled: Bool?
    /// Whether the network gives its guests a built-in DNS resolver, serving the
    /// zones attached to it in full and forwarding the rest through the
    /// hypervisor's egress. Defaults true — an opt-out, like `metadataEnabled`.
    let resolverEnabled: Bool?
    /// Site to pin the network to; its VMs then only place on that site's
    /// agents, where the shared OVN deployment spans it across nodes.
    let siteId: UUID

    // Explicit init so the DHCP fields default when omitted (e.g. in tests) while
    // JSON decoding still populates them via the synthesized Codable conformance.
    init(
        name: String, subnet: String, gateway: String? = nil, subnet6: String? = nil,
        gateway6: String? = nil, ipv6Enabled: Bool? = nil, projectId: UUID? = nil,
        dhcpEnabled: Bool? = nil, dnsServers: [String]? = nil, domainName: String? = nil,
        leaseTime: Int? = nil, externalAccess: Bool? = nil, metadataEnabled: Bool? = nil,
        resolverEnabled: Bool? = nil, siteId: UUID
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
        self.metadataEnabled = metadataEnabled
        self.resolverEnabled = resolverEnabled
        self.siteId = siteId
    }

    mutating func validate() throws {
        name = try Validate.name(name)
        // `dnsServers` entries are parsed as addresses by `validatedDNS`, so
        // only their count is open-ended here.
        try Validate.list(dnsServers, "dnsServers", max: LogicalNetwork.maxDNSServers)
    }
}

struct UpdateNetworkRequest: Content, ValidatedRequestBody, Sendable {
    /// Rejected while any VM interface references the network.
    var name: String?
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
    /// An empty string clears the search domain; anything else must be a
    /// fully-qualified domain name.
    let domainName: String?
    let leaseTime: Int?
    /// Toggle outbound SNAT. Re-synced to agents, which add/remove the SNAT rule.
    let externalAccess: Bool?
    /// Toggle the instance metadata service. Re-synced to agents, which create
    /// or delete the network's metadata port and namespaces.
    let metadataEnabled: Bool?
    /// Toggle the network's built-in DNS resolver. Re-synced to agents, which
    /// add or remove the resolver's addresses from the network's localport and
    /// start or stop its CoreDNS. Guests pick the change up at their next DHCP
    /// lease, not immediately.
    let resolverEnabled: Bool?
    /// The zone this network's VMs auto-register into. Must already be
    /// attached to the network. Send `clearPrimaryDnsZone: true` to unset it —
    /// a JSON `null` is indistinguishable from an omitted field here.
    let primaryDnsZoneId: UUID?
    let clearPrimaryDnsZone: Bool?

    init(
        name: String? = nil, subnet: String? = nil, gateway: String? = nil,
        subnet6: String? = nil, gateway6: String? = nil, ipv6Enabled: Bool? = nil,
        dhcpEnabled: Bool? = nil, dnsServers: [String]? = nil, domainName: String? = nil,
        leaseTime: Int? = nil, externalAccess: Bool? = nil, metadataEnabled: Bool? = nil,
        resolverEnabled: Bool? = nil,
        primaryDnsZoneId: UUID? = nil, clearPrimaryDnsZone: Bool? = nil
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
        self.metadataEnabled = metadataEnabled
        self.resolverEnabled = resolverEnabled
        self.primaryDnsZoneId = primaryDnsZoneId
        self.clearPrimaryDnsZone = clearPrimaryDnsZone
    }

    mutating func validate() throws {
        name = try Validate.name(name)
        try Validate.list(dnsServers, "dnsServers", max: LogicalNetwork.maxDNSServers)
    }
}

struct NetworkResponse: Content {
    let id: UUID?
    let name: String
    let subnet: String
    let gateway: String?
    let subnet6: String?
    let gateway6: String?
    let projectId: UUID
    let attachedInterfaceCount: Int
    let dhcpEnabled: Bool
    let dnsServers: [String]
    let domainName: String?
    let leaseTime: Int?
    let externalAccess: Bool
    let metadataEnabled: Bool
    let resolverEnabled: Bool
    /// The addresses this network's guests resolve through, v4 first. Nil when
    /// the resolver has never been enabled. Exposed rather than the index behind
    /// them because these are what an operator compares against a guest's
    /// `resolv.conf`.
    let resolverAddresses: [String]?
    let siteId: UUID
    /// The zone this network's VMs auto-register into, if any (issue #770).
    let primaryDnsZoneId: UUID?
    /// Why this network's guests will not resolve the DNS zones attached to it,
    /// or nil when they will (STR-201). Derived on read from the resolver's
    /// state and the site's capability — see
    /// `ResolverCapability.zoneResolutionWarning`.
    ///
    /// A required init parameter rather than a defaulted one, so none of the
    /// handlers building this can silently omit the one field that reports a
    /// misconfiguration.
    let zoneResolutionWarning: String?
    let createdAt: Date?
    let updatedAt: Date?

    init(from network: LogicalNetwork, attachedInterfaceCount: Int, zoneResolutionWarning: String?) {
        self.id = network.id
        self.name = network.name
        self.subnet = network.subnet
        self.gateway = network.gateway
        self.subnet6 = network.subnet6
        self.gateway6 = network.gateway6
        self.projectId = network.$project.id
        self.attachedInterfaceCount = attachedInterfaceCount
        self.dhcpEnabled = network.dhcpEnabled
        self.dnsServers = network.dnsServers
        self.domainName = network.domainName
        self.leaseTime = network.leaseTime
        self.externalAccess = network.externalAccess
        self.metadataEnabled = network.metadataEnabled
        self.resolverEnabled = network.resolverEnabled
        self.resolverAddresses = network.resolverIndex.map {
            [
                NetworkResolverEndpoint.address(forIndex: $0),
                NetworkResolverEndpoint.addressV6(forIndex: $0),
            ]
        }
        self.siteId = network.$site.id
        self.primaryDnsZoneId = network.$primaryDNSZone.id
        self.zoneResolutionWarning = zoneResolutionWarning
        self.createdAt = network.createdAt
        self.updatedAt = network.updatedAt
    }
}
