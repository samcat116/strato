import ControlPlanePostgres
import Fluent
import StratoShared
import Vapor

struct NetworkController: RouteCollection {
    let iam: IAMPersistence
    let projects: ProjectsPersistence
    let networks: NetworksPersistence
    let sites: SitesPersistence
    let hierarchy: HierarchyPersistence

    init(
        iam: IAMPersistence,
        projects: ProjectsPersistence,
        networks: NetworksPersistence,
        sites: SitesPersistence,
        hierarchy: HierarchyPersistence
    ) {
        self.iam = iam
        self.projects = projects
        self.networks = networks
        self.sites = sites
        self.hierarchy = hierarchy
    }
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
            let hasAccess = try await req.can("project:read", on: IAMNode(type: .project, id: projectId))

            guard hasAccess else {
                throw Abort(.forbidden, reason: "You don't have access to this project")
            }

            projectScope = [projectId]
        } else {
            // Narrow to the projects the caller could reach, then let the
            // evaluator decide the ones that carry rows (`ProjectVisibility`).
            let resolved = try await ProjectVisibility.resolve(on: req, using: iam, projects: projects)
            visibility = resolved
            projectScope = resolved.candidateProjectIDs
        }

        let networkRows: [NetworkOverview]
        if let projectScope {
            networkRows = try await networks.networks(projectIDs: projectScope)
        } else {
            networkRows = try await networks.allNetworks()
        }

        var visible = networkRows
        if let visibility {
            let readable = try await visibility.readableProjects(
                among: networkRows.map { $0.network.projectID }, on: req)
            visible = networkRows.filter { readable.contains($0.network.projectID) }
        }
        return visible.map { overview in
            NetworkResponse(
                from: overview,
                zoneResolutionWarning: Self.zoneResolutionWarning(for: overview)
            )
        }
    }

    /// Whether a site's owning scope contains a project: an org-scoped site
    /// serves every project whose root org matches; an OU-scoped site serves
    /// only projects under that OU (directly or via a descendant OU). Legacy
    /// unscoped sites serve nothing until an operator assigns them an owner.
    func siteScopeContains(project: ProjectSnapshot, site: SiteSnapshot) async throws -> Bool {
        if let organizationID = site.organizationID {
            return project.rootOrganizationID == organizationID
        }
        guard let siteFolderID = site.organizationalUnitID,
            let projectFolderID = project.organizationalUnitID
        else { return false }
        let ancestors = try await hierarchy.organizationalUnitAncestors(id: projectFolderID)
        return ancestors.contains { $0.id == siteFolderID }
    }

    private func requireUsableNetworkAuthority(site: SiteSnapshot, req: Request) async throws {
        let consequence = "a network pinned to it would be realized nowhere"
        guard let controller = site.controller else {
            // An empty site may be pre-provisioned; its first capable member
            // claims topology authority when it enrolls.
            guard try await sites.agentCount(siteID: site.id) > 0 else { return }
            throw Abort(
                .conflict,
                reason: "Site '\(site.name)' has no network controller, so \(consequence). "
                    + "Designate one of the site's OVN-capable agents with PUT "
                    + "/api/sites/\(site.id.uuidString) "
                    + #"{"networkControllerAgentId": "<agentId>"}"#
            )
        }

        let fault: (phrase: String, remedy: String)?
        if !controller.supportsInterVMNetworking {
            fault = (
                "re-registered without overlay (OVN) networking capability",
                "Restore its OVN networking configuration"
            )
        } else if let heartbeat = controller.lastHeartbeat {
            let staleFor = Date().timeIntervalSince(heartbeat)
            let grace = req.controlPlaneConfiguration.double(.siteControllerOfflineGraceSeconds)
            fault = staleFor > grace
                ? (
                    "is offline (no heartbeat for \(SiteNetworkAuthority.compactAge(staleFor)))",
                    "Bring it back online"
                )
                : nil
        } else {
            fault = (
                "is offline (it has never sent a heartbeat)",
                "Bring it back online"
            )
        }
        guard let fault else { return }
        throw Abort(
            .conflict,
            reason: "Site '\(site.name)' network controller '\(controller.name)' \(fault.phrase), "
                + "so \(consequence). \(fault.remedy), or designate another of the site's "
                + "OVN-capable agents with PUT /api/sites/\(site.id.uuidString) "
                + #"{"networkControllerAgentId": "<agentId>"}"#
        )
    }

    // MARK: - Create Network

    /// Create a new project-scoped network
    /// POST /api/networks
    @Sendable
    func createNetwork(req: Request) async throws -> NetworkResponse {
        let user = try req.auth.require(User.self)
        let request = try req.content.decodeValidated(CreateNetworkRequest.self)

        guard let projectId = request.projectId else {
            throw Request.projectIsRequired("networks")
        }
        guard try await req.can("network:create", on: IAMNode(type: .project, id: projectId)) else {
            throw Abort(
                .forbidden,
                reason: "You don't have permission to create networks in this project"
            )
        }
        guard let project = try await projects.project(id: projectId) else {
            throw Abort(.badRequest, reason: "Project \(projectId) does not exist")
        }

        // Trimmed and bounded by `CreateNetworkRequest.validate()`.
        let name = request.name

        let (subnet, gateway) = try Self.validateAddressing(subnet: request.subnet, gateway: request.gateway)
        // Dual-stack by default: absent an explicit /64 (or an explicit
        // opt-out), every new network gets a generated unique-local /64.
        let addressing6 = try Self.resolveIPv6Addressing(
            subnet6: request.subnet6, gateway6: request.gateway6, ipv6Enabled: request.ipv6Enabled)
        try Self.assertNoSubnetOverlap(
            subnet: subnet,
            subnet6: addressing6?.subnet6,
            siblings: try await networks.networks(projectIDs: [projectId]).map(\.network)
        )
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
        let siteId = request.siteId
        guard let site = try await sites.site(id: siteId) else {
            throw Abort(.badRequest, reason: "Site \(siteId) does not exist")
        }
        guard try await siteScopeContains(project: project, site: site) else {
            throw Abort(
                .badRequest,
                reason: "Site \(siteId) does not serve the network's project"
            )
        }
        try await requireUsableNetworkAuthority(site: site, req: req)

        guard let creatorID = user.id else {
            throw Abort(.internalServerError, reason: "Authenticated user missing ID")
        }
        let write = NetworkCreateWrite(
            name: name,
            subnet: subnet,
            gateway: gateway,
            subnet6: addressing6?.subnet6,
            gateway6: addressing6?.gateway6,
            projectID: projectId,
            creatorID: creatorID,
            administratorRoleID: IAMRole.admin.seededID,
            dhcpEnabled: request.dhcpEnabled ?? true,
            dnsServers: dnsServers,
            domainName: try Self.validatedDomainName(request.domainName),
            leaseTime: request.leaseTime,
            externalAccess: request.externalAccess ?? true,
            metadataEnabled: request.metadataEnabled ?? true,
            resolverEnabled: request.resolverEnabled ?? true,
            siteID: siteId
        )

        let overview: NetworkOverview
        switch try await networks.create(write) {
        case .created(let created):
            overview = created
        case .projectNotFound:
            throw Abort(.badRequest, reason: "Project \(projectId) does not exist")
        case .siteNotFound:
            throw Abort(.badRequest, reason: "Site \(siteId) does not exist")
        case .duplicateName:
            throw Abort(.conflict, reason: "A network named '\(name)' already exists")
        case .quotaExceeded(let quotaName, let limit):
            throw Abort(
                .forbidden,
                reason: "Quota '\(quotaName)' exceeded: Network limit reached: \(limit) networks allowed"
            )
        case .resolverAddressExhausted(let capacity):
            throw Abort(
                .conflict,
                reason: "No link-local resolver address is free: all \(capacity) addresses in "
                    + "\(NetworkResolverEndpoint.v4Space) are in use. Disable the resolver on "
                    + "networks that no longer need one to free them."
            )
        }

        req.logger.info(
            "Network created",
            metadata: [
                "networkId": .string(overview.network.id.uuidString),
                "name": .string(overview.network.name),
                "subnet": .string(overview.network.subnet),
                "projectId": .string(projectId.uuidString),
            ])

        // Nil rather than computed: a network created a moment ago has no zone
        // attached to it, so there is nothing it can be failing to resolve.
        return NetworkResponse(from: overview, zoneResolutionWarning: nil)
    }

    // MARK: - Get Network

    /// Get a specific network by ID
    /// GET /api/networks/:networkId
    @Sendable
    func getNetwork(req: Request) async throws -> NetworkResponse {
        _ = try req.auth.require(User.self)
        guard let networkID = req.parameters.get("networkId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid network ID")
        }
        guard let overview = try await networks.network(id: networkID) else {
            throw Abort(.notFound, reason: "Network not found")
        }
        guard try await req.can("network:read", on: IAMNode(type: .network, id: networkID)) else {
            throw Abort(.forbidden, reason: "You don't have 'network:read' access on this network")
        }
        return NetworkResponse(
            from: overview,
            zoneResolutionWarning: Self.zoneResolutionWarning(for: overview)
        )
    }

    // MARK: - Update Network

    /// Update a network. Name and subnet may only change while no VM interface
    /// references the network; the gateway may change anytime but only affects
    /// future allocations (existing NICs carry a denormalized copy).
    /// PUT /api/networks/:networkId
    @Sendable
    func updateNetwork(req: Request) async throws -> NetworkResponse {
        let user = try req.auth.require(User.self)
        var network = try await fetchNetworkWithAction(req: req, user: user, action: "network:update")
        let request = try req.content.decodeValidated(UpdateNetworkRequest.self)

        var interfaceCount = try await attachedInterfaceCount(for: network, on: req.db)

        // Renaming an in-use network is safe since issue #765: NICs, addresses
        // and the agent's OVN objects all key on the row id, so the name is a
        // display label nothing resolves through.
        //
        if let newName = request.name, newName != network.name {
            // Renaming *into* a collision is the same hazard as creating one;
            // the guard runs with the save, under the name lock. Trimmed and
            // bounded already by `UpdateNetworkRequest.validate()`.
            network = network.replacing(name: newName)
        }

        // Track changes that alter how agents realize the network's L3, so the
        // generation is bumped (and agents accept the new desired network state).
        let originalSubnet = network.subnet
        if let newSubnet = request.subnet, newSubnet != network.subnet {
            guard interfaceCount == 0 else {
                throw Abort(
                    .conflict,
                    reason:
                        "Network is in use by \(interfaceCount) interface(s); changing the subnet would invalidate their addresses"
                )
            }
            network = network.replacing(subnet: newSubnet)
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
            network = network.replacing(gateway: .some(newGateway))
        }

        // Re-validate the resulting subnet/gateway combination as a whole.
        let (subnet, gateway) = try Self.validateAddressing(subnet: network.subnet, gateway: network.gateway)
        network = network.replacing(subnet: subnet, gateway: .some(gateway))

        let networkID = try network.requireID()
        // Reject the contradictory shape before entering the transaction. The
        // requested IPv6 result itself is derived from the locked row below:
        // an enable/no-op must preserve a subnet or gateway committed after
        // this request's initial read.
        if request.ipv6Enabled == false {
            guard request.subnet6 == nil, request.gateway6 == nil else {
                throw Abort(.badRequest, reason: "subnet6/gateway6 cannot be combined with ipv6Enabled=false")
            }
        }

        if network.subnet != originalSubnet {
            try await Self.assertNoSubnetOverlap(
                subnet: network.subnet, subnet6: network.subnet6, projectId: network.projectID,
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
            network = network.replacing(externalAccess: externalAccess)
        }

        // DHCP/DNS settings — validated then applied.
        if let dhcpEnabled = request.dhcpEnabled {
            network = network.replacing(dhcpEnabled: dhcpEnabled)
        }
        if let dnsServers = request.dnsServers {
            network = network.replacing(dnsServers: try Self.validatedDNS(dnsServers))
        }
        // Captured, not just applied: an explicit `domainName` in this request
        // outranks the one the primary-zone block below would derive, and the
        // two are only distinguishable here — once applied, an operator's value
        // and a derived one are the same column (STR-201).
        let domainNameExplicit = request.domainName != nil
        if let domainName = request.domainName {
            network = network.replacing(
                domainName: .some(try Self.validatedDomainName(domainName)))
        }
        if let leaseTime = request.leaseTime {
            try Self.validateLeaseTime(leaseTime)
            network = network.replacing(leaseTime: .some(leaseTime))
        }

        // Applied below the generation bump, deliberately: the metadata port is
        // converged level-triggered on every network reconcile (like the DHCP
        // rows), so bumping the generation here would buy nothing and would make
        // agents treat legitimately concurrent syncs as stale.
        if let metadataEnabled = request.metadataEnabled {
            network = network.replacing(metadataEnabled: metadataEnabled)
        }
        if let resolverEnabled = request.resolverEnabled {
            network = network.replacing(resolverEnabled: resolverEnabled)
        }
        // Allocated on the way *on* and kept on the way off, so re-enabling never
        // moves a live address — moving one would change what guests were told
        // over DHCP and strand every lease until it renewed. Deferred to the
        // save transaction below rather than done here: the allocator's advisory
        // lock is transaction-scoped, so allocating on `req.db` would release it
        // before the chosen index was durable and let two concurrent enables
        // pick the same one.
        // The zone this network's VMs register into (issue #770). Only ever a
        // zone already attached to the network — attachment is what grants
        // resolution, and registering into a zone the network cannot resolve
        // would publish names its own VMs can't look up.
        //
        // Both branches also move the search domain, which follows the primary
        // zone while the operator has not claimed it (STR-201) — see
        // `DNSZoneService.searchDomainFollowingPrimaryZone`.
        let requestedPrimaryZoneName: String?
        if request.clearPrimaryDnsZone == true {
            guard request.primaryDnsZoneId == nil else {
                throw Abort(
                    .badRequest,
                    reason: "primaryDnsZoneId cannot be combined with clearPrimaryDnsZone=true")
            }
            requestedPrimaryZoneName = nil
            network = network.replacing(primaryDNSZoneID: .some(nil))
        } else if let zoneID = request.primaryDnsZoneId {
            guard let zone = try await LegacyDNSZoneStore.find(id: zoneID, on: req.db) else {
                throw Abort(.badRequest, reason: "DNS zone \(zoneID) does not exist")
            }
            requestedPrimaryZoneName = zone.name
            let attached = try await DNSZoneNetworkStore.count(
                zoneID: zoneID, networkID: networkID, on: req.db)
            guard attached > 0 else {
                throw Abort(
                    .conflict,
                    reason: "DNS zone '\(zone.name)' is not attached to this network; attach it first")
            }
            let allowed = try await req.can("dns:update", on: IAMNode(type: .dnsZone, id: zoneID))
            guard allowed else {
                throw Abort(.forbidden, reason: "You don't have permission to modify this DNS zone")
            }
            try await DNSZoneService.assertPrimaryZoneAssignable(
                zone: zone, networkID: networkID, on: req.db)
            network = network.replacing(primaryDNSZoneID: .some(zoneID))
        } else {
            requestedPrimaryZoneName = nil
        }

        do {
            // Everything above prepares and authorizes the requested values.
            // The row is reloaded under lock here so two updates that began
            // from the same HTTP snapshot merge onto committed state and mint
            // successive generations instead of saving one stale model over
            // the other.
            let prepared = network
            let committed = try await req.db.transaction { db -> (LogicalNetwork, Int) in
                switch try await DesiredStateGenerationWriter.lockCurrent(
                    schema: LogicalNetwork.schema, id: networkID, expectedGeneration: nil, on: db)
                {
                case .applied:
                    break
                case .missing:
                    throw Abort(.notFound, reason: "Network no longer exists")
                case .superseded:
                    throw Abort(
                        .internalServerError,
                        reason: "Network generation could not be locked")
                }
                guard var current = try await LogicalNetwork.find(networkID, on: db) else {
                    throw Abort(.notFound, reason: "Network no longer exists")
                }
                let oldSubnet = current.subnet
                let oldGateway = current.gateway
                let oldSubnet6 = current.subnet6
                let oldGateway6 = current.gateway6
                let oldExternalAccess = current.externalAccess

                let currentInterfaceCount = try await attachedInterfaceCount(for: current, on: db)
                let changesSubnet = request.subnet != nil && prepared.subnet != current.subnet
                let changesGateway = request.gateway != nil && prepared.gateway != current.gateway
                if changesSubnet || changesGateway {
                    guard currentInterfaceCount == 0 else {
                        let field = changesSubnet ? "subnet" : "gateway"
                        throw Abort(
                            .conflict,
                            reason:
                                "Network is in use by \(currentInterfaceCount) interface(s); changing the \(field) would break their L3 configuration"
                        )
                    }
                }

                if request.name != nil { current = current.replacing(name: prepared.name) }
                if request.subnet != nil { current = current.replacing(subnet: prepared.subnet) }
                if request.gateway != nil {
                    current = current.replacing(gateway: .some(prepared.gateway))
                }

                if let requestedIPv6 = try Self.requestedIPv6Addressing(
                    request: request, currentSubnet6: current.subnet6,
                    currentGateway6: current.gateway6)
                {
                    let currentV6AddressCount =
                        try await LegacyInterfaceAddressStore.count(
                            kind: .vm,
                            logicalNetworkID: networkID,
                            family: .ipv6,
                            on: db)
                        + (try await LegacyInterfaceAddressStore.count(
                            kind: .sandbox,
                            logicalNetworkID: networkID,
                            family: .ipv6,
                            on: db))
                    if requestedIPv6.subnet6 != current.subnet6 {
                        guard current.subnet6 == nil || currentV6AddressCount == 0 else {
                            throw Abort(
                                .conflict,
                                reason:
                                    "Network has \(currentV6AddressCount) allocated IPv6 address(es); changing IPv6 would invalidate them"
                            )
                        }
                    } else if requestedIPv6.gateway6 != current.gateway6 {
                        guard currentV6AddressCount == 0 else {
                            throw Abort(
                                .conflict,
                                reason:
                                    "Network has \(currentV6AddressCount) allocated IPv6 address(es); changing the IPv6 gateway would break their L3 configuration"
                            )
                        }
                    }
                    current = current.replacing(
                        subnet6: .some(requestedIPv6.subnet6),
                        gateway6: .some(requestedIPv6.gateway6))
                }

                let validated = try Self.validateAddressing(
                    subnet: current.subnet, gateway: current.gateway)
                current = current.replacing(
                    subnet: validated.subnet, gateway: .some(validated.gateway))
                if let subnet6 = current.subnet6 {
                    let validated6 = try Self.validateAddressing6(
                        subnet6: subnet6, gateway6: current.gateway6)
                    current = current.replacing(
                        subnet6: .some(validated6.subnet6),
                        gateway6: .some(validated6.gateway6))
                }
                if changesSubnet || current.subnet6 != oldSubnet6 {
                    try await Self.assertNoSubnetOverlap(
                        subnet: current.subnet, subnet6: current.subnet6,
                        projectId: current.projectID, excluding: current.id, on: db)
                }

                if let externalAccess = request.externalAccess {
                    if !externalAccess && current.externalAccess {
                        let attachedFloatingIPs = try await Self.attachedFloatingIPCount(
                            networkID: networkID, on: db)
                        guard attachedFloatingIPs == 0 else {
                            throw Abort(
                                .conflict,
                                reason:
                                    "Network has \(attachedFloatingIPs) attached floating IP(s); detach them before disabling external access"
                            )
                        }
                    }
                    current = current.replacing(externalAccess: externalAccess)
                }

                if request.dhcpEnabled != nil {
                    current = current.replacing(dhcpEnabled: prepared.dhcpEnabled)
                }
                if request.dnsServers != nil {
                    current = current.replacing(dnsServers: prepared.dnsServers)
                }
                if request.domainName != nil {
                    current = current.replacing(domainName: .some(prepared.domainName))
                }
                if request.leaseTime != nil {
                    current = current.replacing(leaseTime: .some(prepared.leaseTime))
                }
                if request.metadataEnabled != nil {
                    current = current.replacing(metadataEnabled: prepared.metadataEnabled)
                }
                if request.resolverEnabled != nil {
                    current = current.replacing(resolverEnabled: prepared.resolverEnabled)
                }
                if request.clearPrimaryDnsZone == true || request.primaryDnsZoneId != nil {
                    let outgoing =
                        domainNameExplicit
                        ? nil : try await DNSZoneService.primaryZoneName(of: current, on: db)
                    current = current.replacing(
                        domainName: .some(Self.searchDomainAfterPrimaryZoneChange(
                            currentDomain: current.domainName,
                            previousZoneName: outgoing,
                            nextZoneName: requestedPrimaryZoneName,
                            domainNameExplicit: domainNameExplicit)),
                        primaryDNSZoneID: .some(request.primaryDnsZoneId))
                }

                let l3Changed =
                    current.subnet != oldSubnet
                    || current.gateway != oldGateway
                    || current.subnet6 != oldSubnet6
                    || current.gateway6 != oldGateway6
                    || current.externalAccess != oldExternalAccess
                if l3Changed {
                    switch try await DesiredStateGenerationWriter.advance(
                        schema: LogicalNetwork.schema, id: networkID,
                        expectedGeneration: Int64(current.generation), on: db)
                    {
                    case .applied(let generation):
                        guard let generation = Int(exactly: generation) else {
                            throw Abort(
                                .internalServerError,
                                reason: "Network generation exceeds the model's integer range")
                        }
                        current = current.replacing(generation: generation)
                    case .missing:
                        throw Abort(.notFound, reason: "Network no longer exists")
                    case .superseded:
                        throw Abort(
                            .internalServerError,
                            reason: "Network generation did not advance")
                    }
                }
                if current.resolverEnabled && current.resolverIndex == nil {
                    let index = try await ResolverAddressAllocator.ensureIndex(for: current, on: db)
                    current = current.replacing(resolverIndex: .some(index))
                }
                try await current.save(on: db)
                return (current, currentInterfaceCount)
            }
            network = committed.0
            interfaceCount = committed.1
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "A network named '\(network.name)' already exists")
        }

        // Ring the fleet for the new DHCP config: agents reprogram OVN's
        // DHCP_Options for the subnet, and running guests pick up new DNS/lease
        // on their next renew. Level-triggered and cluster-wide, so a network
        // shared across agents converges everywhere; a lost doorbell is caught
        // by the agents' unconditional refetches.
        await req.application.agentService.syncDesiredStateToFleet()

        req.logger.info(
            "Network updated",
            metadata: [
                "networkId": .string(network.id!.uuidString),
                "name": .string(network.name),
            ])

        return NetworkResponse(
            from: network, attachedInterfaceCount: interfaceCount,
            zoneResolutionWarning: try await zoneResolutionWarning(for: network, on: req.db))
    }

    // MARK: - Delete Network

    /// Delete a network. Networks with attached VM or sandbox interfaces are
    /// rejected with 409 — and the NIC foreign key (`ON DELETE RESTRICT`)
    /// backstops the check at the database.
    /// DELETE /api/networks/:networkId
    @Sendable
    func deleteNetwork(req: Request) async throws -> HTTPStatus {
        _ = try req.auth.require(User.self)
        guard let networkID = req.parameters.get("networkId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid network ID")
        }
        guard try await networks.network(id: networkID) != nil else {
            throw Abort(.notFound, reason: "Network not found")
        }
        guard try await req.can("network:delete", on: IAMNode(type: .network, id: networkID)) else {
            throw Abort(
                .forbidden,
                reason: "You don't have 'network:delete' access on this network"
            )
        }

        let deleted: NetworkSnapshot
        switch try await networks.deleteIfUnused(id: networkID) {
        case .deleted(let network):
            deleted = network
        case .notFound:
            throw Abort(.notFound, reason: "Network not found")
        case .hasInterfaces(let interfaceCount):
            throw Abort(
                .conflict,
                reason: "Network is in use by \(interfaceCount) interface(s); detach them first"
            )
        case .hasLoadBalancers(let loadBalancerCount):
            throw Abort(
                .conflict,
                reason: "Network is in use by \(loadBalancerCount) load balancer(s); delete them first"
            )
        }

        req.logger.info(
            "Network deleted",
            metadata: [
                "networkId": .string(deleted.id.uuidString),
                "name": .string(deleted.name),
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
        try await LegacyFloatingIPStore.attachedInterfaceCount(networkID: networkID, on: db)
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
        let siblings = try await LegacyLogicalNetworkStore.networks(
            projectID: projectId, excludingID: networkId, on: db)
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

    static func assertNoSubnetOverlap(
        subnet: String,
        subnet6: String?,
        siblings: [NetworkSnapshot]
    ) throws {
        if let clash = siblings.first(where: { subnetsOverlap($0.subnet, subnet) }) {
            throw Abort(
                .conflict,
                reason: "Subnet \(subnet) overlaps network '\(clash.name)' (\(clash.subnet)) in "
                    + "the same project; networks sharing a project share one router and must "
                    + "use disjoint subnets"
            )
        }
        if let subnet6,
            let clash = siblings.first(where: { sibling in
                sibling.subnet6.map { subnetsOverlap($0, subnet6) } ?? false
            })
        {
            throw Abort(
                .conflict,
                reason: "IPv6 subnet \(subnet6) overlaps network '\(clash.name)' "
                    + "(\(clash.subnet6 ?? "")) in the same project; networks sharing a project "
                    + "share one router and must use disjoint subnets"
            )
        }
    }

    /// Validates a subnet/gateway pair, defaulting a missing gateway to the
    /// subnet's first host address.
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
        // The v4 metadata address is link-local and can never collide with a
        // tenant subnet; its v6 counterpart is a ULA drawn from the same space
        // tenant subnets are (STR-186). A network overlapping it would publish
        // the service localport inside its own address space and — worse —
        // inherit the metadata and resolver security-group carve-outs, which
        // sit above every rule-derived ACL, as non-overridable allows to a
        // *tenant* address. Reject the whole documented `/32` rather than the
        // containing /64: it is how the space is described everywhere else,
        // and it covers the per-network resolvers as well.
        if NetworkResolverEndpoint.v6SpaceCIDR.overlaps(cidr) {
            throw Abort(
                .badRequest,
                reason: "IPv6 subnet '\(trimmed)' overlaps \(NetworkResolverEndpoint.v6Space), which is "
                    + "reserved for Strato's own link-local services (instance metadata at "
                    + "\(InstanceMetadataEndpoint.addressV6) and the per-network DNS resolvers); "
                    + "choose a different ULA prefix, or omit subnet6 to have one generated")
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

    /// Derives an IPv6 edit from the row held under lock, not from the model
    /// loaded before the transaction. In particular, `ipv6Enabled: true` is a
    /// no-op for an already-enabled network and must preserve an IPv6 pair that
    /// a concurrent request committed while this request was waiting.
    static func requestedIPv6Addressing(
        request: UpdateNetworkRequest, currentSubnet6: String?, currentGateway6: String?
    ) throws -> (subnet6: String?, gateway6: String?)? {
        guard request.ipv6Enabled != nil || request.subnet6 != nil || request.gateway6 != nil else {
            return nil
        }
        if request.ipv6Enabled == false {
            guard request.subnet6 == nil, request.gateway6 == nil else {
                throw Abort(.badRequest, reason: "subnet6/gateway6 cannot be combined with ipv6Enabled=false")
            }
            return (nil, nil)
        }
        if let requestedSubnet6 = request.subnet6 {
            let requested = try validateAddressing6(
                subnet6: requestedSubnet6, gateway6: request.gateway6)
            return (requested.subnet6, requested.gateway6)
        }
        if let currentSubnet6 {
            let requested = try validateAddressing6(
                subnet6: currentSubnet6, gateway6: request.gateway6 ?? currentGateway6)
            return (requested.subnet6, requested.gateway6)
        }

        guard request.gateway6 == nil else {
            throw Abort(.badRequest, reason: "gateway6 requires subnet6 (or an existing IPv6 subnet)")
        }
        let generated = IPv6Address.makeULASubnet64()
        return (generated.description, generated.firstHost.description)
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

    /// Applies primary-zone following semantics to the domain value reloaded
    /// under the network row lock. A concurrent explicit domain edit is then
    /// visible here and is not replaced by a value derived before the lock.
    static func searchDomainAfterPrimaryZoneChange(
        currentDomain: String?, previousZoneName: String?, nextZoneName: String?,
        domainNameExplicit: Bool
    ) -> String? {
        guard !domainNameExplicit else { return currentDomain }
        return DNSZoneService.searchDomainFollowingPrimaryZone(
            current: currentDomain, previousZoneName: previousZoneName,
            nextZoneName: nextZoneName)
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
        let vmInterfaces = try await LegacyVMNetworkInterfaceStore.count(
            logicalNetworkID: networkID, on: db)
        let sandboxInterfaces = try await LegacySandboxNetworkInterfaceStore.count(
            logicalNetworkID: networkID, on: db)
        return vmInterfaces + sandboxInterfaces
    }

    /// The zone-resolution warning for one network (STR-201), for the handlers
    /// that answer with a single row.
    ///
    /// The zone count is asked first and short-circuits everything else: a
    /// network with no attached zone cannot be failing to deliver one, and that
    /// is the overwhelming majority of networks, so the capability read is only
    /// paid for by the ones the answer could be about.
    private func zoneResolutionWarning(for network: LogicalNetwork, on db: any Database) async throws
        -> String?
    {
        let networkID = try network.requireID()
        let zoneCount = try await DNSZoneNetworkStore.count(networkID: networkID, on: db)
        guard zoneCount > 0 else { return nil }
        let capability = try await ResolverCapability.index(on: db)
        return ResolverCapability.zoneResolutionWarning(
            network: network, attachedZoneCount: zoneCount,
            incapableAgentNames: capability.incapableAgentNames(forSite: network.siteID))
    }

    private static func zoneResolutionWarning(for overview: NetworkOverview) -> String? {
        guard overview.attachedZoneCount > 0 else { return nil }
        let network = overview.network
        let zones = overview.attachedZoneCount == 1
            ? "its attached DNS zone"
            : "its \(overview.attachedZoneCount) attached DNS zones"
        if !network.resolverEnabled {
            return "This network's resolver is off, so guests are given its DNS servers directly "
                + "and will not resolve \(zones). Enable the resolver, or point dnsServers at a "
                + "server that already serves the zone."
        }
        if !overview.resolverIncapableAgentNames.isEmpty {
            let hosts = overview.resolverIncapableAgentNames.joined(separator: ", ")
            return "The resolver is withheld because \(hosts) cannot run it, so guests are given "
                + "this network's DNS servers directly and will not resolve \(zones). Install "
                + "CoreDNS on those hosts and restart their agents, or delete the rows of any that "
                + "are decommissioned."
        }
        if network.resolverIndex == nil {
            return "This network's resolver has no address allocated yet, so guests are given its "
                + "DNS servers directly and will not resolve \(zones). Updating the network "
                + "allocates one."
        }
        return nil
    }

    /// Fetch a network and check a canonical action. Access derives entirely from the
    /// owning project: every network has one (issue #765), so the evaluator
    /// resolves the network's parent scope and the bindings there decide.
    private func fetchNetworkWithAction(req: Request, user: User, action: String) async throws
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

        let hasPermission = try await req.can(action, on: IAMNode(type: .network, id: networkId))

        guard hasPermission else {
            throw Abort(.forbidden, reason: "You don't have '\(action)' access on this network")
        }

        return network
    }

}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
