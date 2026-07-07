import Fluent
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
        let dnsServers = try Self.validatedDNS(request.dnsServers ?? [])
        try Self.validateLeaseTime(request.leaseTime)

        let network = LogicalNetwork(
            name: name,
            subnet: subnet,
            gateway: gateway,
            projectID: projectId,
            createdByID: user.id!,
            dhcpEnabled: request.dhcpEnabled ?? true,
            dnsServers: dnsServers,
            domainName: request.domainName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            leaseTime: request.leaseTime
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

        if let newGateway = request.gateway {
            network.gateway = newGateway
        }

        // Re-validate the resulting subnet/gateway combination as a whole.
        let (subnet, gateway) = try Self.validateAddressing(subnet: network.subnet, gateway: network.gateway)
        network.subnet = subnet
        network.gateway = gateway

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

    /// Validates a list of DNS resolver addresses, dropping blanks. Each must be
    /// a valid IPv4 address.
    static func validatedDNS(_ servers: [String]) throws -> [String] {
        var cleaned: [String] = []
        for server in servers {
            let trimmed = server.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard IPAMService.parseIPv4(trimmed) != nil else {
                throw Abort(.badRequest, reason: "DNS server is not an IPv4 address: '\(server)'")
            }
            cleaned.append(trimmed)
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
