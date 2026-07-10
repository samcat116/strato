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
    /// Query params: project_id (optional)
    @Sendable
    func listNetworks(req: Request) async throws -> [NetworkResponse] {
        let user = try req.auth.require(User.self)

        let projectScope: [UUID]
        if let projectIdString = req.query[String.self, at: "project_id"],
            let projectId = UUID(uuidString: projectIdString)
        {
            let hasAccess = try await req.spicedb.checkPermission(
                subject: user.id!.uuidString,
                permission: "view_project",
                resource: "project",
                resourceId: projectId.uuidString
            )

            guard hasAccess else {
                throw Abort(.forbidden, reason: "You don't have access to this project")
            }

            projectScope = [projectId]
        } else {
            projectScope = try await getAccessibleProjects(for: user, on: req)
        }

        let networks =
            try await LogicalNetwork.query(on: req.db)
            .group(.or) { group in
                group.filter(\.$project.$id == nil)
                group.filter(\.$project.$id ~~ projectScope)
            }
            .sort(\.$createdAt, .descending)
            .all()

        var responses: [NetworkResponse] = []
        for network in networks {
            let count = try await attachedInterfaceCount(for: network, on: req.db)
            responses.append(NetworkResponse(from: network, attachedInterfaceCount: count))
        }
        return responses
    }

    /// Whether a site's owning scope contains a project: an org-scoped site
    /// serves every project whose root org matches; an OU-scoped site serves
    /// only projects under that OU (directly or via a descendant OU). Legacy
    /// unscoped sites serve nothing until an operator assigns them an owner.
    static func siteScopeContains(project: Project, site: Site, on db: Database) async throws -> Bool {
        switch site.organizationScope {
        case .organization(let siteOrgID):
            return try await project.getRootOrganizationId(on: db) == siteOrgID
        case .organizationalUnit(let siteOUID):
            // Walk the project's OU ancestry; bounded by OU nesting depth.
            var current = project.$organizationalUnit.id
            while let ouID = current {
                if ouID == siteOUID { return true }
                current = try await OrganizationalUnit.find(ouID, on: db)?.$parentOU.id
            }
            return false
        case nil:
            return false
        }
    }

    // MARK: - Create Network

    /// Create a new project-scoped network
    /// POST /api/networks
    @Sendable
    func createNetwork(req: Request) async throws -> NetworkResponse {
        let user = try req.auth.require(User.self)
        let request = try req.content.decode(CreateNetworkRequest.self)

        // Determine project (same resolution as volumes)
        let projectId: UUID
        if let requestProjectId = request.projectId {
            projectId = requestProjectId
        } else if let currentOrgId = user.currentOrganizationId {
            guard
                let defaultProject = try await Project.query(on: req.db)
                    .filter(\.$organization.$id == currentOrgId)
                    .first()
            else {
                throw Abort(.badRequest, reason: "No project specified and no default project found")
            }
            projectId = defaultProject.id!
        } else {
            throw Abort(.badRequest, reason: "No project specified and user has no current organization")
        }

        let hasPermission = try await req.spicedb.checkPermission(
            subject: user.id!.uuidString,
            permission: "create_network",
            resource: "project",
            resourceId: projectId.uuidString
        )

        guard hasPermission else {
            throw Abort(.forbidden, reason: "You don't have permission to create networks in this project")
        }

        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw Abort(.badRequest, reason: "Network name must not be empty")
        }

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
            guard let project = try await Project.find(projectId, on: req.db),
                try await Self.siteScopeContains(project: project, site: site, on: req.db)
            else {
                throw Abort(
                    .badRequest,
                    reason: "Site \(siteId) does not serve the network's project")
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
            domainName: request.domainName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            leaseTime: request.leaseTime,
            externalAccess: request.externalAccess ?? true,
            siteID: request.siteId
        )

        do {
            try await network.save(on: req.db)
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "A network named '\(name)' already exists")
        }

        // Create SpiceDB relationships
        try await req.spicedb.writeRelationship(
            entity: "network",
            entityId: network.id!.uuidString,
            relation: "owner",
            subject: "user",
            subjectId: user.id!.uuidString
        )

        try await req.spicedb.writeRelationship(
            entity: "network",
            entityId: network.id!.uuidString,
            relation: "project",
            subject: "project",
            subjectId: projectId.uuidString
        )

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
        let request = try req.content.decode(UpdateNetworkRequest.self)

        let interfaceCount = try await attachedInterfaceCount(for: network, on: req.db)

        if let newName = request.name, newName != network.name {
            guard network.name != LogicalNetwork.defaultNetworkName else {
                throw Abort(.conflict, reason: "The default network cannot be renamed")
            }
            guard interfaceCount == 0 else {
                throw Abort(
                    .conflict,
                    reason:
                        "Network is in use by \(interfaceCount) interface(s); renaming would orphan them"
                )
            }
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw Abort(.badRequest, reason: "Network name must not be empty")
            }
            network.name = trimmed
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
        let v6AddressCount = try await VMInterfaceAddress.query(on: req.db)
            .filter(\.$network == network.name)
            .filter(\.$family == IPFamily.ipv6.rawValue)
            .count()

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
            network.domainName = domainName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        if let leaseTime = request.leaseTime {
            try Self.validateLeaseTime(leaseTime)
            network.leaseTime = leaseTime
        }

        do {
            try await network.save(on: req.db)
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "A network named '\(network.name)' already exists")
        }

        // Push the new DHCP config to the fleet: agents reprogram OVN's
        // DHCP_Options for the subnet, and running guests pick up new DNS/lease
        // on their next renew. Level-triggered and cluster-wide, so a network
        // shared across agents converges everywhere; a lost nudge is caught by
        // the periodic sync timer.
        await req.application.agentService.syncDesiredStateToAllAgents()

        req.logger.info(
            "Network updated",
            metadata: [
                "networkId": .string(network.id!.uuidString),
                "name": .string(network.name),
            ])

        return NetworkResponse(from: network, attachedInterfaceCount: interfaceCount)
    }

    // MARK: - Delete Network

    /// Delete a network. The default network is never deletable; networks with
    /// attached VM interfaces are rejected with 409.
    /// DELETE /api/networks/:networkId
    @Sendable
    func deleteNetwork(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let network = try await fetchNetworkWithPermission(req: req, user: user, permission: "delete")

        guard network.name != LogicalNetwork.defaultNetworkName else {
            throw Abort(.conflict, reason: "The default network cannot be deleted")
        }

        let interfaceCount = try await attachedInterfaceCount(for: network, on: req.db)
        guard interfaceCount == 0 else {
            throw Abort(
                .conflict,
                reason: "Network is in use by \(interfaceCount) interface(s); detach them first"
            )
        }

        // Delete SpiceDB relationships
        if let createdById = network.$createdBy.id {
            try await req.spicedb.deleteRelationship(
                entity: "network",
                entityId: network.id!.uuidString,
                relation: "owner",
                subject: "user",
                subjectId: createdById.uuidString
            )
        }

        if let projectId = network.$project.id {
            try await req.spicedb.deleteRelationship(
                entity: "network",
                entityId: network.id!.uuidString,
                relation: "project",
                subject: "project",
                subjectId: projectId.uuidString
            )
        }

        try await network.delete(on: req.db)

        req.logger.info(
            "Network deleted",
            metadata: [
                "networkId": .string(network.id!.uuidString),
                "name": .string(network.name),
            ])

        return .noContent
    }

    // MARK: - Helper Methods

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

    static func validateLeaseTime(_ leaseTime: Int?) throws {
        guard let leaseTime else { return }
        guard leaseTime > 0 else {
            throw Abort(.badRequest, reason: "leaseTime must be a positive number of seconds")
        }
    }

    /// Number of VM interfaces attached to the network. NICs reference networks
    /// by name string (no FK), so this is the in-use check for delete/rename.
    private func attachedInterfaceCount(for network: LogicalNetwork, on db: Database) async throws -> Int {
        try await VMNetworkInterface.query(on: db)
            .filter(\.$network == network.name)
            .count()
    }

    /// Fetch a network and check permission. Global networks (no project) are
    /// readable by all authenticated users but only mutable by system admins.
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

        // System admins bypass permission checks
        if user.isSystemAdmin {
            return network
        }

        // Global networks have no project to derive permissions from: everyone
        // may read them (they are the VM-create fallback), nobody but system
        // admins may change them.
        if network.$project.id == nil {
            if permission == "read" {
                return network
            }
            throw Abort(.forbidden, reason: "Only system administrators can modify global networks")
        }

        let hasPermission = try await req.spicedb.checkPermission(
            subject: user.id!.uuidString,
            permission: permission,
            resource: "network",
            resourceId: networkId.uuidString
        )

        guard hasPermission else {
            throw Abort(.forbidden, reason: "You don't have '\(permission)' permission on this network")
        }

        return network
    }

    /// Get all project IDs the user has access to
    private func getAccessibleProjects(for user: User, on req: Request) async throws -> [UUID] {
        let allProjects = try await Project.query(on: req.db).all()
        var accessibleProjectIds: [UUID] = []

        for project in allProjects {
            let hasAccess = try await req.spicedb.checkPermission(
                subject: user.id!.uuidString,
                permission: "view_project",
                resource: "project",
                resourceId: project.id!.uuidString
            )
            if hasAccess {
                accessibleProjectIds.append(project.id!)
            }
        }

        return accessibleProjectIds
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
