import Fluent
import StratoShared
import Vapor

struct NetworkController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let networks = routes.grouped("api", "networks")

        // All routes require authentication
        let protected = networks.grouped(User.guardMiddleware())

        protected.get(use: listNetworks)
        protected.post(use: createNetwork)
        protected.get(":networkId", use: getNetwork)
        protected.put(":networkId", use: updateNetwork)
        protected.delete(":networkId", use: deleteNetwork)
    }

    // MARK: - List Networks

    /// List all networks the user has access to. Global networks (no project)
    /// are always included — they are the VM-create fallback everyone can use.
    /// GET /api/networks
    /// Query params: project_id (optional),
    /// limit/offset (optional) — select the page.
    @Sendable
    func listNetworks(req: Request) async throws -> PagedResponse<NetworkResponse> {
        let paging = try ListPaging.decode(from: req)
        let networks = try await visibleNetworks(req: req)
        return paging.page(networks)
    }

    /// Every network the caller may read, newest first, ready for slicing.
    func visibleNetworks(req: Request) async throws -> [NetworkResponse] {
        _ = try req.auth.require(User.self)

        // The projects to narrow the row query to, or nil for no narrowing at
        // all (a system admin). Every network belongs to a project (issue
        // #765), so the scope is the whole story — there is no project-less
        // network readable outside it.
        let projectScope: [UUID]?
        var visibility: ProjectVisibility?
        if let projectIdString = req.query[String.self, at: "project_id"],
            let projectId = UUID(uuidString: projectIdString)
        {
            let hasAccess = try await req.can("view_project", on: "project", id: projectId.uuidString)

            guard hasAccess else {
                throw Abort(.forbidden, reason: "You don't have access to this project")
            }

            projectScope = [projectId]
        } else {
            // Narrow to the projects the caller could reach, then let the
            // evaluator decide the ones that carry rows (`ProjectVisibility`).
            let resolved = try await ProjectVisibility.resolve(on: req)
            visibility = resolved
            projectScope = resolved.candidateProjectIDs
        }

        var query = LogicalNetwork.query(on: req.db)
        if let projectScope {
            // An empty scope reaches no project, and therefore no network.
            query = query.filter(\.$project.$id ~~ projectScope)
        }
        let networks =
            try await query
            .sort(\.$createdAt, .descending)
            .sort(\.$id, .descending)
            .all()

        var visible = networks
        if let visibility {
            let readable = try await visibility.readableProjects(
                among: networks.map { $0.$project.id }, on: req)
            visible = networks.filter { readable.contains($0.$project.id) }
        }

        // Attachment counts come from one grouped count per NIC table; both
        // count, since either kind of interface pins the network against
        // rename and delete.
        let visibleIDs = visible.compactMap(\.id)
        let vmCounts = try await VMNetworkInterface.counts(
            groupedBy: \.$logicalNetwork, in: visibleIDs, on: req.db)
        let sandboxCounts = try await SandboxNetworkInterface.counts(
            groupedBy: \.$logicalNetwork, in: visibleIDs, on: req.db)
        return visible.map { network in
            let id = network.id
            let attached = (id.map { vmCounts[$0] ?? 0 } ?? 0) + (id.map { sandboxCounts[$0] ?? 0 } ?? 0)
            return NetworkResponse(from: network, attachedInterfaceCount: attached)
        }
    }

    /// Whether a site's owning scope contains a project: an org-scoped site
    /// serves every project whose root org matches; an OU-scoped site serves
    /// only projects under that OU (directly or via a descendant OU). Legacy
    /// unscoped sites serve nothing until an operator assigns them an owner.
    static func siteScopeContains(project: Project, site: Site, on db: Database) async throws -> Bool {
        guard let siteScope = site.organizationScope else { return false }
        let projectScope: OrganizationScope
        if let orgID = project.$organization.id {
            projectScope = .organization(orgID)
        } else if let ouID = project.$organizationalUnit.id {
            projectScope = .organizationalUnit(ouID)
        } else {
            return false
        }
        return try await siteScope.contains(projectScope, on: db)
    }

    // MARK: - Create Network

    /// Create a new project-scoped network
    /// POST /api/networks
    @Sendable
    func createNetwork(req: Request) async throws -> NetworkResponse {
        let user = try req.auth.require(User.self)
        let request = try req.content.decodeValidated(CreateNetworkRequest.self)

        let project = try await req.authorizedProjectForCreate(
            requested: request.projectId, user: user,
            action: "create_network", resourceKind: "networks")
        let projectId = try project.requireID()

        // Trimmed and bounded by `CreateNetworkRequest.validate()`.
        let name = request.name

        let (subnet, gateway) = try Self.validateAddressing(subnet: request.subnet, gateway: request.gateway)
        // Dual-stack by default: absent an explicit /64 (or an explicit
        // opt-out), every new network gets a generated unique-local /64.
        let addressing6 = try Self.resolveIPv6Addressing(
            subnet6: request.subnet6, gateway6: request.gateway6, ipv6Enabled: request.ipv6Enabled)
        try await Self.assertNoSubnetOverlap(
            subnet: subnet, subnet6: addressing6?.subnet6, projectId: projectId, excluding: nil, on: req.db)
        let dnsServers = try Self.validatedDNS(request.dnsServers ?? [])
        try Self.validateLeaseTime(request.leaseTime)

        // Pinning to a site constrains all the network's VMs to that site's
        // agents, where the shared OVN deployment spans the switch across
        // nodes. Validated here so a typo'd id fails the create, not the
        // first VM placement — and the site's owning scope must CONTAIN the
        // network's project: sites are dedicated capacity, so an org-scoped
        // site serves its whole org while an OU-scoped site serves only that
        // OU's subtree. A bare root-org match would let a sibling OU's
        // project force its VMs onto (and realize its switch across) capacity
        // delegated to a different OU.
        if let siteId = request.siteId {
            guard let site = try await Site.find(siteId, on: req.db) else {
                throw Abort(.badRequest, reason: "Site \(siteId) does not exist")
            }
            guard try await Self.siteScopeContains(project: project, site: site, on: req.db) else {
                throw Abort(
                    .badRequest,
                    reason: "Site \(siteId) does not serve the network's project")
            }
            // A site whose topology nobody authors — no designated network
            // controller, or one that is offline past the grace window or came
            // back unable to author (issue #833) — reconciles nothing: the
            // switch would be created in the database and realized nowhere, and
            // the first VM on it would park forever with no API-visible symptom
            // (issue #743). An *empty* site is not refused — pre-provisioning a
            // network for capacity that hasn't been enrolled yet is legitimate,
            // and the first OVN-capable node to join becomes the controller
            // automatically. (A site with an unusable controller has a member
            // by definition, so only the unassigned case reaches that count.)
            let authority = try await SiteNetworkAuthority.resolve(forSite: site, on: req.db)
            if let refusal = SiteNetworkAuthority.refusal(
                authority, consequence: "a network pinned to it would be realized nowhere")
            {
                let members = try await Agent.query(on: req.db).filter(\.$site.$id == siteId).count()
                guard members == 0 else { throw refusal }
            }
        }

        let network = LogicalNetwork(
            name: name,
            subnet: subnet,
            gateway: gateway,
            subnet6: addressing6?.subnet6,
            gateway6: addressing6?.gateway6,
            projectID: projectId,
            createdByID: user.id!,
            dhcpEnabled: request.dhcpEnabled ?? true,
            dnsServers: dnsServers,
            domainName: try Self.validatedDomainName(request.domainName),
            leaseTime: request.leaseTime,
            externalAccess: request.externalAccess ?? true,
            metadataEnabled: request.metadataEnabled ?? true,
            siteID: request.siteId
        )

        do {
            // The creator's explicit, revocable binding on the network, in the
            // same transaction as the row (issue #477).
            let creatorID = user.id!
            try await req.db.transaction { db in
                // Inside the transaction, under a name lock: two concurrent
                // cross-project creates of the same name would otherwise both
                // observe "no collision" and both commit, since the unique
                // index is per project.
                try await LogicalNetworkService.lockName(name, on: db)
                try await Self.assertNameSafeForFleet(
                    name: name, projectId: projectId, siteId: request.siteId, on: db)
                try await network.save(on: db)
                try await RoleBindingService.grant(
                    principalType: .user,
                    principalID: creatorID,
                    role: .admin,
                    nodeType: .network,
                    nodeID: network.id!,
                    createdBy: creatorID,
                    on: db
                )
            }
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "A network named '\(name)' already exists")
        }

        req.logger.info(
            "Network created",
            metadata: [
                "networkId": .string(network.id!.uuidString),
                "name": .string(network.name),
                "subnet": .string(network.subnet),
                "projectId": .string(projectId.uuidString),
            ])

        return NetworkResponse(from: network, attachedInterfaceCount: 0)
    }

    // MARK: - Get Network

    /// Get a specific network by ID
    /// GET /api/networks/:networkId
    @Sendable
    func getNetwork(req: Request) async throws -> NetworkResponse {
        let user = try req.auth.require(User.self)
        let network = try await fetchNetworkWithPermission(req: req, user: user, permission: "read")
        let count = try await attachedInterfaceCount(for: network, on: req.db)
        return NetworkResponse(from: network, attachedInterfaceCount: count)
    }

    // MARK: - Update Network

    /// Update a network. Name and subnet may only change while no VM interface
    /// references the network; the gateway may change anytime but only affects
    /// future allocations (existing NICs carry a denormalized copy).
    /// PUT /api/networks/:networkId
    @Sendable
    func updateNetwork(req: Request) async throws -> NetworkResponse {
        let user = try req.auth.require(User.self)
        let network = try await fetchNetworkWithPermission(req: req, user: user, permission: "update")
        let request = try req.content.decodeValidated(UpdateNetworkRequest.self)

        let interfaceCount = try await attachedInterfaceCount(for: network, on: req.db)

        // Renaming an in-use network is safe since issue #765: NICs, addresses
        // and the agent's OVN objects all key on the row id, so the name is a
        // display label nothing resolves through.
        //
        // Set only when the name actually changes, so an unrelated edit that
        // echoes the current name back doesn't get held to the collision guard.
        var renamedTo: String?
        if let newName = request.name, newName != network.name {
            // Renaming *into* a collision is the same hazard as creating one;
            // the guard runs with the save, under the name lock. Trimmed and
            // bounded already by `UpdateNetworkRequest.validate()`.
            network.name = newName
            renamedTo = newName
        }

        // Track changes that alter how agents realize the network's L3, so the
        // generation is bumped (and agents accept the new desired network state).
        let originalSubnet = network.subnet
        let originalGateway = network.gateway
        let originalSubnet6 = network.subnet6
        let originalGateway6 = network.gateway6
        let originalExternalAccess = network.externalAccess

        if let newSubnet = request.subnet, newSubnet != network.subnet {
            guard interfaceCount == 0 else {
                throw Abort(
                    .conflict,
                    reason:
                        "Network is in use by \(interfaceCount) interface(s); changing the subnet would invalidate their addresses"
                )
            }
            network.subnet = newSubnet
        }

        if let newGateway = request.gateway, newGateway != network.gateway {
            // The gateway is the L3 router-port address AND the denormalized
            // gateway existing NICs already carry into their guests. Changing it
            // while VMs are attached re-addresses the OVN router port but leaves
            // those guests pointing at the old gateway, breaking their L3 — so
            // reject it in use, like a subnet change (issue #342).
            guard interfaceCount == 0 else {
                throw Abort(
                    .conflict,
                    reason:
                        "Network is in use by \(interfaceCount) interface(s); changing the gateway would break their L3 configuration"
                )
            }
            network.gateway = newGateway
        }

        // Re-validate the resulting subnet/gateway combination as a whole.
        let (subnet, gateway) = try Self.validateAddressing(subnet: network.subnet, gateway: network.gateway)
        network.subnet = subnet
        network.gateway = gateway

        // IPv6: enable (explicit /64 or generated ULA), change, or remove.
        // The in-use guard counts allocated v6 addresses, not interfaces — a
        // network full of pre-IPv6 NICs has no v6 addresses to invalidate, so
        // *adding* IPv6 is always safe; existing NICs simply stay v4.
        let networkID = try network.requireID()
        let v6AddressCount =
            try await VMInterfaceAddress.query(on: req.db)
            .filter(\.$logicalNetwork.$id == networkID)
            .filter(\.$family == IPFamily.ipv6.rawValue)
            .count()
            + (try await SandboxInterfaceAddress.query(on: req.db)
                .filter(\.$logicalNetwork.$id == networkID)
                .filter(\.$family == IPFamily.ipv6.rawValue)
                .count())

        if request.ipv6Enabled == false {
            guard request.subnet6 == nil, request.gateway6 == nil else {
                throw Abort(.badRequest, reason: "subnet6/gateway6 cannot be combined with ipv6Enabled=false")
            }
            if network.subnet6 != nil {
                guard v6AddressCount == 0 else {
                    throw Abort(
                        .conflict,
                        reason:
                            "Network has \(v6AddressCount) allocated IPv6 address(es); removing IPv6 would invalidate them"
                    )
                }
                network.subnet6 = nil
                network.gateway6 = nil
            }
        } else if request.subnet6 != nil || request.gateway6 != nil || request.ipv6Enabled == true {
            let newPair: (subnet6: String, gateway6: String)
            if let requestedSubnet6 = request.subnet6 {
                newPair = try Self.validateAddressing6(subnet6: requestedSubnet6, gateway6: request.gateway6)
            } else if let currentSubnet6 = network.subnet6 {
                // Gateway-only change (or a no-op ipv6Enabled=true).
                newPair = try Self.validateAddressing6(
                    subnet6: currentSubnet6, gateway6: request.gateway6 ?? network.gateway6)
            } else {
                // Enabling with no explicit prefix: generate a ULA (a caller
                // gateway6 makes no sense against a prefix it cannot know).
                guard request.gateway6 == nil else {
                    throw Abort(.badRequest, reason: "gateway6 requires subnet6 (or an existing IPv6 subnet)")
                }
                let generated = IPv6Address.makeULASubnet64()
                newPair = (generated.description, generated.firstHost.description)
            }

            if newPair.subnet6 != network.subnet6 {
                // Same rule as v4 subnet changes, scoped to v6 allocations;
                // adding IPv6 to a v4-only network passes (no v6 addresses).
                guard network.subnet6 == nil || v6AddressCount == 0 else {
                    throw Abort(
                        .conflict,
                        reason:
                            "Network has \(v6AddressCount) allocated IPv6 address(es); changing the IPv6 subnet would invalidate them"
                    )
                }
            } else if newPair.gateway6 != network.gateway6 {
                // Same rule as v4 gateway changes: guests carry the old value.
                guard v6AddressCount == 0 else {
                    throw Abort(
                        .conflict,
                        reason:
                            "Network has \(v6AddressCount) allocated IPv6 address(es); changing the IPv6 gateway would break their L3 configuration"
                    )
                }
            }
            network.subnet6 = newPair.subnet6
            network.gateway6 = newPair.gateway6
        }

        if network.subnet != originalSubnet || network.subnet6 != originalSubnet6 {
            try await Self.assertNoSubnetOverlap(
                subnet: network.subnet, subnet6: network.subnet6, projectId: network.$project.id,
                excluding: network.id, on: req.db)
        }

        if let externalAccess = request.externalAccess {
            // Turning egress off pulls the router's uplink, which is what
            // every floating IP on the network NATs through — the planner
            // would silently drop their dnat_and_snat rules while the API kept
            // reporting the addresses as attached (issue #344). Make the
            // dependency explicit: detach first.
            if !externalAccess && network.externalAccess {
                let attachedFloatingIPs = try await Self.attachedFloatingIPCount(
                    networkID: networkID, on: req.db)
                guard attachedFloatingIPs == 0 else {
                    throw Abort(
                        .conflict,
                        reason:
                            "Network has \(attachedFloatingIPs) attached floating IP(s); detach them before disabling external access"
                    )
                }
            }
            network.externalAccess = externalAccess
        }

        // Bump the realization generation only when an L3-affecting field
        // actually changed, so agents treat this as a newer network desired
        // state; DHCP/DNS-only edits leave it untouched.
        if network.subnet != originalSubnet
            || network.gateway != originalGateway
            || network.subnet6 != originalSubnet6
            || network.gateway6 != originalGateway6
            || network.externalAccess != originalExternalAccess
        {
            network.generation += 1
        }

        // DHCP/DNS settings — validated then applied.
        if let dhcpEnabled = request.dhcpEnabled {
            network.dhcpEnabled = dhcpEnabled
        }
        if let dnsServers = request.dnsServers {
            network.dnsServers = try Self.validatedDNS(dnsServers)
        }
        if let domainName = request.domainName {
            network.domainName = try Self.validatedDomainName(domainName)
        }
        if let leaseTime = request.leaseTime {
            try Self.validateLeaseTime(leaseTime)
            network.leaseTime = leaseTime
        }

        // Applied below the generation bump, deliberately: the metadata port is
        // converged level-triggered on every network reconcile (like the DHCP
        // rows), so bumping the generation here would buy nothing and would make
        // agents treat legitimately concurrent syncs as stale.
        if let metadataEnabled = request.metadataEnabled {
            network.metadataEnabled = metadataEnabled
        }

        // The zone this network's VMs register into (issue #770). Only ever a
        // zone already attached to the network — attachment is what grants
        // resolution, and registering into a zone the network cannot resolve
        // would publish names its own VMs can't look up.
        if request.clearPrimaryDnsZone == true {
            guard request.primaryDnsZoneId == nil else {
                throw Abort(
                    .badRequest,
                    reason: "primaryDnsZoneId cannot be combined with clearPrimaryDnsZone=true")
            }
            network.$primaryDNSZone.id = nil
        } else if let zoneID = request.primaryDnsZoneId, zoneID != network.$primaryDNSZone.id {
            guard let zone = try await DNSZone.find(zoneID, on: req.db) else {
                throw Abort(.badRequest, reason: "DNS zone \(zoneID) does not exist")
            }
            let attached = try await DNSZoneNetwork.query(on: req.db)
                .filter(\.$zone.$id == zoneID)
                .filter(\.$logicalNetwork.$id == networkID)
                .count()
            guard attached > 0 else {
                throw Abort(
                    .conflict,
                    reason: "DNS zone '\(zone.name)' is not attached to this network; attach it first")
            }
            let allowed = try await req.can("update", on: "dns_zone", id: zoneID.uuidString)
            guard allowed else {
                throw Abort(.forbidden, reason: "You don't have permission to modify this DNS zone")
            }
            try await DNSZoneService.assertPrimaryZoneAssignable(
                zone: zone, networkID: networkID, on: req.db)
            network.$primaryDNSZone.id = zoneID
        }

        do {
            let pendingRename = renamedTo
            try await req.db.transaction { db in
                // A rename into a cross-project collision needs the same
                // in-transaction check under the same name lock as create.
                if let renamedTo = pendingRename {
                    try await LogicalNetworkService.lockName(renamedTo, on: db)
                    try await Self.assertNameSafeForFleet(
                        name: renamedTo, projectId: network.$project.id, siteId: network.$site.id, on: db)
                }
                try await network.save(on: db)
            }
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "A network named '\(network.name)' already exists")
        }

        // Push the new DHCP config to the fleet: agents reprogram OVN's
        // DHCP_Options for the subnet, and running guests pick up new DNS/lease
        // on their next renew. Level-triggered and cluster-wide, so a network
        // shared across agents converges everywhere; a lost nudge is caught by
        // the periodic sync timer.
        await req.application.agentService.syncDesiredStateToFleet()

        req.logger.info(
            "Network updated",
            metadata: [
                "networkId": .string(network.id!.uuidString),
                "name": .string(network.name),
            ])

        return NetworkResponse(from: network, attachedInterfaceCount: interfaceCount)
    }

    // MARK: - Delete Network

    /// Delete a network. Networks with attached VM or sandbox interfaces are
    /// rejected with 409 — and the NIC foreign key (`ON DELETE RESTRICT`)
    /// backstops the check at the database.
    /// DELETE /api/networks/:networkId
    @Sendable
    func deleteNetwork(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let network = try await fetchNetworkWithPermission(req: req, user: user, permission: "delete")

        let interfaceCount = try await attachedInterfaceCount(for: network, on: req.db)
        guard interfaceCount == 0 else {
            throw Abort(
                .conflict,
                reason: "Network is in use by \(interfaceCount) interface(s); detach them first"
            )
        }

        try await req.db.transaction { db in
            try await network.delete(on: db)
            // Bindings have no FK to the resources they protect, so drop
            // them with the node.
            try await RoleBindingService.revokeAll(
                nodeType: .network, nodeID: network.id!, on: db)
        }

        req.logger.info(
            "Network deleted",
            metadata: [
                "networkId": .string(network.id!.uuidString),
                "name": .string(network.name),
            ])

        return .noContent
    }

    // MARK: - Helper Methods

    /// How many floating IPs are attached to NICs on the network.
    ///
    /// Joined rather than intersected in Swift: the set this counts is a
    /// handful of rows, but the reduction used to load every NIC on the
    /// network and the whole `floating_ips` table to find them.
    static func attachedFloatingIPCount(networkID: UUID, on db: Database) async throws -> Int {
        try await FloatingIP.query(on: db)
            .join(parent: \.$interface)
            .filter(VMNetworkInterface.self, \.$logicalNetwork.$id == networkID)
            .count()
    }

    /// Refuses a network name that another project already uses, when any agent
    /// that would realize it is too old to tell the two apart.
    ///
    /// A pre-v21 agent keys its managed `DHCP_Options` rows on
    /// `(network-name, cidr)` rather than on the network's id, so two
    /// same-named networks would share one row: DNS or lease edits on one would
    /// land on the other, and disabling DHCP on one would delete the other's.
    /// The check lives at *create* rather than at VM placement because topology
    /// convergence programs DHCP for every network the authority realizes,
    /// whether or not a VM ever lands on it.
    ///
    /// Scoped to the fleet that could realize the network: its site's agents
    /// when pinned, otherwise every agent (an unpinned network can be realized
    /// on any host a VM lands on).
    ///
    /// This is one half of the guard. It cannot see an agent that joins *later*
    /// — a rollback to an older binary, or a newly-enrolled one — so
    /// `AgentService.registerAgent` runs the mirror check and refuses such a
    /// registration.
    static func assertNameSafeForFleet(
        name: String, projectId: UUID, siteId: UUID?, on db: Database
    ) async throws {
        let collides = try await LogicalNetwork.query(on: db)
            .filter(\.$name == name)
            .filter(\.$project.$id != projectId)
            .count()
        guard collides > 0 else { return }

        var query = Agent.query(on: db)
        if let siteId { query = query.filter(\.$site.$id == siteId) }
        let stale = try await query.all()
            .filter { !WireProtocol.supportsProjectNetworkIsolation($0.wireProtocolVersion ?? 0) }
        guard let oldest = stale.min(by: { ($0.wireProtocolVersion ?? 0) < ($1.wireProtocolVersion ?? 0) })
        else { return }

        throw Abort(
            .conflict,
            reason: "Another project already has a network named '\(name)', and agent "
                + "'\(oldest.name)' speaks protocol v\(oldest.wireProtocolVersion ?? 0) — too old to keep "
                + "two same-named networks' DHCP configuration apart (needs "
                + "v\(WireProtocol.projectNetworkIsolationMinimumVersion)). Upgrade the agent or choose "
                + "a different name.")
    }

    /// Whether two CIDRs overlap. For CIDRs, ranges are either disjoint or one
    /// contains the other, so masking both to the shorter prefix and comparing
    /// the network addresses detects any overlap. Family-aware: different
    /// families never overlap. Unparsable input fails closed (treated as
    /// overlapping) — every stored subnet was validated at write time, so an
    /// unparsable one is corrupt data, and declaring it disjoint would let a
    /// duplicate slide through silently.
    static func subnetsOverlap(_ a: String, _ b: String) -> Bool {
        let a4 = IPv4CIDR(a)
        let b4 = IPv4CIDR(b)
        if let a4, let b4 { return a4.overlaps(b4) }
        let a6 = IPv6CIDR(a)
        let b6 = IPv6CIDR(b)
        if let a6, let b6 { return a6.overlaps(b6) }
        if (a4 != nil || a6 != nil) && (b4 != nil || b6 != nil) { return false }
        return true
    }

    /// Rejects a subnet that overlaps another network in the same project.
    /// Project networks share one per-project logical router, so overlapping
    /// router-port `networks` would give OVN ambiguous connected routes (and
    /// exact duplicates collide on the SNAT `logical_ip`) — issue #342. Global
    /// (project-less) networks each get their own router, so they're exempt.
    /// Each family is checked against its own sibling column.
    static func assertNoSubnetOverlap(
        subnet: String, subnet6: String? = nil, projectId: UUID?, excluding networkId: UUID?,
        on db: any Database
    ) async throws {
        guard let projectId else { return }
        var query = LogicalNetwork.query(on: db).filter(\.$project.$id == projectId)
        if let networkId {
            query = query.filter(\.$id != networkId)
        }
        let siblings = try await query.all()
        if let clash = siblings.first(where: { subnetsOverlap($0.subnet, subnet) }) {
            throw Abort(
                .conflict,
                reason:
                    "Subnet \(subnet) overlaps network '\(clash.name)' (\(clash.subnet)) in the same project; networks sharing a project share one router and must use disjoint subnets"
            )
        }
        if let subnet6,
            let clash = siblings.first(where: { sibling in
                sibling.subnet6.map { subnetsOverlap($0, subnet6) } ?? false
            })
        {
            throw Abort(
                .conflict,
                reason:
                    "IPv6 subnet \(subnet6) overlaps network '\(clash.name)' (\(clash.subnet6 ?? "")) in the same project; networks sharing a project share one router and must use disjoint subnets"
            )
        }
    }

    /// Validates a subnet/gateway pair, defaulting a missing gateway to the
    /// subnet's first host address. Mirrors the seeding validation in the
    /// `CreateLogicalNetwork` migration.
    static func validateAddressing(subnet: String, gateway: String?) throws -> (subnet: String, gateway: String) {
        let trimmedSubnet = subnet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (base, prefix) = IPAMService.parseCIDR(trimmedSubnet),
            IPAMService.allocatablePrefixRange.contains(prefix)
        else {
            throw Abort(
                .badRequest,
                reason:
                    "Invalid subnet '\(subnet)': must be CIDR notation with a prefix between /8 and /30"
            )
        }

        let mask: UInt32 = ~UInt32(0) << (32 - prefix)
        let networkAddress = base & mask

        let resolvedGateway: String
        if let gateway, !gateway.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmedGateway = gateway.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let gatewayValue = IPAMService.parseIPv4(trimmedGateway) else {
                throw Abort(.badRequest, reason: "Invalid gateway address '\(gateway)'")
            }
            let broadcastAddress = networkAddress | ~mask
            guard gatewayValue > networkAddress, gatewayValue < broadcastAddress else {
                throw Abort(
                    .badRequest,
                    reason: "Gateway '\(trimmedGateway)' is not a host address inside subnet '\(trimmedSubnet)'"
                )
            }
            resolvedGateway = trimmedGateway
        } else {
            guard let firstHost = IPAMService.firstHostAddress(inSubnet: trimmedSubnet) else {
                throw Abort(.badRequest, reason: "Invalid subnet '\(subnet)'")
            }
            resolvedGateway = firstHost
        }

        return (trimmedSubnet, resolvedGateway)
    }

    /// Resolves a create request's IPv6 addressing: an explicit /64, a
    /// generated ULA when nothing was specified (the dual-stack default), or
    /// nil for an explicit `ipv6Enabled: false` opt-out.
    static func resolveIPv6Addressing(
        subnet6: String?, gateway6: String?, ipv6Enabled: Bool?
    ) throws -> (subnet6: String, gateway6: String)? {
        let trimmedSubnet6 = subnet6?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if ipv6Enabled == false {
            guard trimmedSubnet6 == nil, gateway6?.nilIfEmpty == nil else {
                throw Abort(.badRequest, reason: "subnet6/gateway6 cannot be combined with ipv6Enabled=false")
            }
            return nil
        }
        if let trimmedSubnet6 {
            return try validateAddressing6(subnet6: trimmedSubnet6, gateway6: gateway6)
        }
        guard gateway6?.nilIfEmpty == nil else {
            throw Abort(.badRequest, reason: "gateway6 requires an explicit subnet6")
        }
        let generated = IPv6Address.makeULASubnet64()
        return (generated.description, generated.firstHost.description)
    }

    /// Validates an IPv6 subnet/gateway pair, canonicalizing both (the
    /// database compares addresses as strings, so exactly one spelling may
    /// exist) and defaulting a missing gateway to the subnet's first host.
    /// Only /64 tenant prefixes are accepted: wider or narrower buys nothing
    /// today and would complicate SLAAC/EUI-64 compatibility forever.
    static func validateAddressing6(
        subnet6: String, gateway6: String?
    ) throws -> (subnet6: String, gateway6: String) {
        let trimmed = subnet6.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cidr = IPv6CIDR(trimmed), cidr.prefix == 64 else {
            throw Abort(
                .badRequest,
                reason: "Invalid IPv6 subnet '\(subnet6)': must be CIDR notation with a /64 prefix")
        }
        let base = cidr.networkAddress
        guard !base.isMulticast, !base.isLinkLocal, !base.isLoopback, !base.isUnspecified else {
            throw Abort(
                .badRequest,
                reason: "Invalid IPv6 subnet '\(subnet6)': multicast, link-local, loopback, and "
                    + "unspecified prefixes are not routable tenant networks")
        }

        let resolvedGateway: IPv6Address
        if let gateway6, let trimmedGateway = gateway6.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            guard let parsed = IPv6Address(trimmedGateway) else {
                throw Abort(.badRequest, reason: "Invalid IPv6 gateway address '\(gateway6)'")
            }
            guard cidr.contains(parsed), parsed != base else {
                throw Abort(
                    .badRequest,
                    reason: "IPv6 gateway '\(trimmedGateway)' is not a host address inside subnet '\(trimmed)'")
            }
            resolvedGateway = parsed
        } else {
            resolvedGateway = cidr.firstHost
        }

        return (cidr.description, resolvedGateway.description)
    }

    /// Validates a list of DNS resolver addresses, dropping blanks. Either
    /// family is accepted (the list stays mixed on the wire; the agent splits
    /// it when programming DHCPv4 vs DHCPv6). IPv6 entries are canonicalized.
    static func validatedDNS(_ servers: [String]) throws -> [String] {
        var cleaned: [String] = []
        for server in servers {
            let trimmed = server.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if IPAMService.parseIPv4(trimmed) != nil {
                cleaned.append(trimmed)
            } else if let canonical = IPv6Address.canonicalize(trimmed) {
                cleaned.append(canonical)
            } else {
                throw Abort(.badRequest, reason: "DNS server is not an IP address: '\(server)'")
            }
        }
        return cleaned
    }

    /// Validates the network's DHCP search domain. Absent or blank clears it;
    /// anything else must be a sequence of RFC 1123 labels.
    ///
    /// Held to a real grammar rather than trimmed free text (issue #876)
    /// because the value is not carried as a string anywhere it lands: the
    /// agent interpolates it into the guest's netplan `network-config` and into
    /// OVN's DHCP option map, where a newline authors netplan *keys* and a
    /// quote ends an OVN option early. That makes an unvalidated domain a
    /// structural edit to a file the VM configures itself from — a `routes:`
    /// block smuggled through this field would give every statically addressed
    /// NIC on the network an attacker-chosen default route.
    ///
    /// A single label is allowed, unlike a zone name: `internal` and `lan` are
    /// legitimate search domains, and netplan's `search` list and OVN's
    /// `domain_name` both take them. The safety property above comes from the
    /// label grammar, which a one-label name satisfies just as well.
    static func validatedDomainName(_ raw: String?) throws -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return try DNSName.normalizedZoneName(raw, field: "Domain name", minimumLabels: 1)
    }

    static func validateLeaseTime(_ leaseTime: Int?) throws {
        guard let leaseTime else { return }
        guard leaseTime > 0 else {
            throw Abort(.badRequest, reason: "leaseTime must be a positive number of seconds")
        }
    }

    /// Number of interfaces attached to the network, VM and sandbox alike —
    /// the in-use check for subnet changes and delete. Both kinds count: a
    /// sandbox NIC holds an address from the same pool, so a network carrying
    /// only sandboxes is not idle.
    private func attachedInterfaceCount(for network: LogicalNetwork, on db: Database) async throws -> Int {
        let networkID = try network.requireID()
        let vmInterfaces = try await VMNetworkInterface.query(on: db)
            .filter(\.$logicalNetwork.$id == networkID)
            .count()
        let sandboxInterfaces = try await SandboxNetworkInterface.query(on: db)
            .filter(\.$logicalNetwork.$id == networkID)
            .count()
        return vmInterfaces + sandboxInterfaces
    }

    /// Fetch a network and check permission. Access derives entirely from the
    /// owning project: every network has one (issue #765), so the evaluator
    /// resolves the network's parent scope and the bindings there decide.
    private func fetchNetworkWithPermission(req: Request, user: User, permission: String) async throws
        -> LogicalNetwork
    {
        guard let networkIdString = req.parameters.get("networkId"),
            let networkId = UUID(uuidString: networkIdString)
        else {
            throw Abort(.badRequest, reason: "Invalid network ID")
        }

        guard let network = try await LogicalNetwork.find(networkId, on: req.db) else {
            throw Abort(.notFound, reason: "Network not found")
        }

        let hasPermission = try await req.can(permission, on: "network", id: networkId.uuidString)

        guard hasPermission else {
            throw Abort(.forbidden, reason: "You don't have '\(permission)' permission on this network")
        }

        return network
    }

}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
