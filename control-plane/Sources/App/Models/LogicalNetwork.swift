import ControlPlanePostgres
import StratoShared
import Vapor

/// Immutable application view of a logical network. SQL decoding stays private
/// to the persistence layer so request handlers and background work never share
/// Fluent identity-map or dirty-tracking state.
struct LogicalNetwork: Content, Equatable, Sendable {
    static let schema = "logical_networks"
    static let maxDNSServers = 32

    let id: UUID?
    let name: String
    let subnet: String
    let gateway: String?
    let subnet6: String?
    let gateway6: String?
    let dhcpEnabled: Bool
    let dnsServersRaw: String?
    let domainName: String?
    let leaseTime: Int?
    let externalAccess: Bool
    let metadataEnabled: Bool
    let resolverEnabled: Bool
    let resolverIndex: Int?
    let generation: Int
    let projectID: UUID
    let siteID: UUID
    let primaryDNSZoneID: UUID?
    let createdByID: UUID?
    let createdAt: Date?
    let updatedAt: Date?

    init(
        id: UUID? = UUID(),
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
        siteID: UUID,
        primaryDNSZoneID: UUID? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.subnet = subnet
        self.gateway = gateway
        self.subnet6 = subnet6
        self.gateway6 = gateway6
        self.projectID = projectID
        self.siteID = siteID
        self.createdByID = createdByID
        self.dhcpEnabled = dhcpEnabled
        self.dnsServersRaw = Self.joinDNS(dnsServers)
        self.domainName = domainName
        self.leaseTime = leaseTime
        self.externalAccess = externalAccess
        self.metadataEnabled = metadataEnabled
        self.resolverEnabled = resolverEnabled
        self.resolverIndex = resolverIndex
        self.generation = generation
        self.primaryDNSZoneID = primaryDNSZoneID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(snapshot: NetworkSnapshot) {
        self.init(
            id: snapshot.id,
            name: snapshot.name,
            subnet: snapshot.subnet,
            gateway: snapshot.gateway,
            subnet6: snapshot.subnet6,
            gateway6: snapshot.gateway6,
            projectID: snapshot.projectID,
            createdByID: snapshot.createdByID,
            dhcpEnabled: snapshot.dhcpEnabled,
            dnsServers: snapshot.dnsServers,
            domainName: snapshot.domainName,
            leaseTime: snapshot.leaseTime,
            externalAccess: snapshot.externalAccess,
            metadataEnabled: snapshot.metadataEnabled,
            resolverEnabled: snapshot.resolverEnabled,
            resolverIndex: snapshot.resolverIndex,
            generation: snapshot.generation,
            siteID: snapshot.siteID,
            primaryDNSZoneID: snapshot.primaryDNSZoneID,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt
        )
    }

    func requireID() throws -> UUID {
        guard let id else {
            throw Abort(.internalServerError, reason: "Logical network has no identifier")
        }
        return id
    }

    @discardableResult
    func persisted(on db: PostgresStoreContext) async throws -> Self {
        try await LegacyLogicalNetworkStore.upsert(self, on: db)
    }

    func save(on db: PostgresStoreContext) async throws {
        _ = try await persisted(on: db)
    }

    func delete(on db: PostgresStoreContext) async throws {
        guard let id else { return }
        _ = try await LegacyLogicalNetworkStore.delete(id: id, on: db)
    }

    static func find(_ id: UUID?, on db: PostgresStoreContext) async throws -> Self? {
        try await LegacyLogicalNetworkStore.network(id: id, on: db)
    }

    static func all(on db: PostgresStoreContext) async throws -> [Self] {
        try await LegacyLogicalNetworkStore.networks(on: db)
    }

    static func count(on db: PostgresStoreContext) async throws -> Int {
        try await LegacyLogicalNetworkStore.count(on: db)
    }

    func replacing(
        name: String? = nil,
        subnet: String? = nil,
        gateway: String?? = nil,
        subnet6: String?? = nil,
        gateway6: String?? = nil,
        dhcpEnabled: Bool? = nil,
        dnsServers: [String]? = nil,
        domainName: String?? = nil,
        leaseTime: Int?? = nil,
        externalAccess: Bool? = nil,
        metadataEnabled: Bool? = nil,
        resolverEnabled: Bool? = nil,
        resolverIndex: Int?? = nil,
        generation: Int? = nil,
        primaryDNSZoneID: UUID?? = nil
    ) -> Self {
        Self(
            id: id,
            name: name ?? self.name,
            subnet: subnet ?? self.subnet,
            gateway: gateway ?? self.gateway,
            subnet6: subnet6 ?? self.subnet6,
            gateway6: gateway6 ?? self.gateway6,
            projectID: projectID,
            createdByID: createdByID,
            dhcpEnabled: dhcpEnabled ?? self.dhcpEnabled,
            dnsServers: dnsServers ?? self.dnsServers,
            domainName: domainName ?? self.domainName,
            leaseTime: leaseTime ?? self.leaseTime,
            externalAccess: externalAccess ?? self.externalAccess,
            metadataEnabled: metadataEnabled ?? self.metadataEnabled,
            resolverEnabled: resolverEnabled ?? self.resolverEnabled,
            resolverIndex: resolverIndex ?? self.resolverIndex,
            generation: generation ?? self.generation,
            siteID: siteID,
            primaryDNSZoneID: primaryDNSZoneID ?? self.primaryDNSZoneID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
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
        return "project-\(projectID.uuidString)\(scope)"
    }

    /// Parsed DNS resolver list, backed by the comma-separated `dns_servers` column.
    var dnsServers: [String] { Self.splitDNS(dnsServersRaw) }

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
        self.projectId = network.projectID
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
        self.siteId = network.siteID
        self.primaryDnsZoneId = network.primaryDNSZoneID
        self.zoneResolutionWarning = zoneResolutionWarning
        self.createdAt = network.createdAt
        self.updatedAt = network.updatedAt
    }

    init(from overview: NetworkOverview, zoneResolutionWarning: String?) {
        let network = overview.network
        self.id = network.id
        self.name = network.name
        self.subnet = network.subnet
        self.gateway = network.gateway
        self.subnet6 = network.subnet6
        self.gateway6 = network.gateway6
        self.projectId = network.projectID
        self.attachedInterfaceCount = overview.attachedInterfaceCount
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
        self.siteId = network.siteID
        self.primaryDnsZoneId = network.primaryDNSZoneID
        self.zoneResolutionWarning = zoneResolutionWarning
        self.createdAt = network.createdAt
        self.updatedAt = network.updatedAt
    }
}
