import ControlPlanePostgres
import Fluent
import Vapor

/// Project-scoped native OVN L4 load balancers (STR-28). The resource and its
/// membership are synchronous database mutations; the level-triggered fleet
/// sync is the retryable delivery mechanism, so no ResourceOperation is needed.
struct LoadBalancerController: RouteCollection {
    let iam: IAMPersistence
    let projects: ProjectsPersistence
    func boot(routes: RoutesBuilder) throws {
        let loadBalancers = routes.grouped("api", "load-balancers").grouped(User.guardMiddleware())
        loadBalancers.get(use: list)
        loadBalancers.post(use: create)
        loadBalancers.get(":loadBalancerId", use: get)
        loadBalancers.put(":loadBalancerId", use: update)
        loadBalancers.delete(":loadBalancerId", use: delete)

        loadBalancers.get(":loadBalancerId", "listeners", use: listListeners)
        loadBalancers.post(":loadBalancerId", "listeners", use: createListener)
        loadBalancers.put(":loadBalancerId", "listeners", ":listenerId", use: updateListener)
        loadBalancers.delete(":loadBalancerId", "listeners", ":listenerId", use: deleteListener)

        loadBalancers.get(":loadBalancerId", "backends", use: listBackends)
        loadBalancers.post(":loadBalancerId", "backends", use: createBackend)
        loadBalancers.delete(":loadBalancerId", "backends", ":backendId", use: deleteBackend)
    }

    // MARK: - CRUD

    @Sendable
    func list(req: Request) async throws -> PagedResponse<LoadBalancerResponse> {
        _ = try req.auth.require(User.self)
        let paging = try ListPaging.decode(from: req)
        let requestedProjectId = req.query[String.self, at: "project_id"].flatMap(UUID.init(uuidString:))

        var projectIDs: [UUID]?
        var visibility: ProjectVisibility?
        if let requestedProjectId {
            guard try await req.can("project:read", on: IAMNode(type: .project, id: requestedProjectId)) else {
                throw Abort(.forbidden, reason: "You don't have access to this project")
            }
            projectIDs = [requestedProjectId]
        } else {
            let resolved = try await ProjectVisibility.resolve(on: req, using: iam, projects: projects)
            guard !resolved.reachesNoProject else { return paging.page([]) }
            projectIDs = resolved.candidateProjectIDs
            visibility = resolved
        }

        var rows = try await LegacyLoadBalancerStore.rows(projectIDs: projectIDs, on: req.db)
        if let visibility {
            rows = try await visibility.readableRows(rows, projectID: \.projectID, on: req)
        }
        var responses: [LoadBalancerResponse] = []
        for row in rows {
            responses.append(try await response(for: row, on: req.db))
        }
        return paging.page(responses)
    }

    @Sendable
    func create(req: Request) async throws -> LoadBalancerResponse {
        let user = try req.auth.require(User.self)
        let request = try req.content.decodeValidated(CreateLoadBalancerRequest.self)
        let name = request.name
        let healthCheck = request.healthCheck ?? .disabled
        try healthCheck.validate()

        let project = try await req.authorizedProjectForCreate(
            requested: request.projectId,
            action: "loadbalancer:create",
            resourceKind: "load balancers")
        let projectID = try project.requireID()
        let network = try await LogicalNetworkService.resolveForWorkloadCreate(
            requestedID: request.logicalNetworkId,
            requestedName: nil,
            projectID: projectID,
            on: req.db)

        let creatorID = try user.requireID()
        let loadBalancer: LoadBalancerSnapshot
        do {
            loadBalancer = try await req.db.transaction { db in
                try await QuotaEnforcementService.reserveLoadBalancer(for: project, on: db)
                let allocation = try await IPAMService.allocateIP(for: network, on: db)
                let row = try await LegacyLoadBalancerStore.insert(
                    name: name,
                    projectID: projectID,
                    logicalNetworkID: try network.requireID(),
                    vip: allocation.ipAddress,
                    protocolName: request.protocol,
                    healthCheck: healthCheck,
                    createdByID: creatorID,
                    on: db)
                try await RoleBindingService.grant(
                    principalType: .user,
                    principalID: creatorID,
                    role: .admin,
                    nodeType: .loadBalancer,
                    nodeID: row.id,
                    createdBy: creatorID,
                    on: db)
                return row
            }
        } catch let error as IPAMService.IPAMError {
            throw Abort(.conflict, reason: error.localizedDescription)
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "A load balancer named '\(name)' already exists in this project")
        }

        await req.application.agentService.syncDesiredStateToFleet()
        return try await response(for: loadBalancer, on: req.db)
    }

    @Sendable
    func get(req: Request) async throws -> LoadBalancerResponse {
        let loadBalancer = try await find(req, action: "loadbalancer:read")
        return try await response(for: loadBalancer, on: req.db)
    }

    @Sendable
    func update(req: Request) async throws -> LoadBalancerResponse {
        let loadBalancer = try await find(req, action: "loadbalancer:update")
        let request = try req.content.decodeValidated(UpdateLoadBalancerRequest.self)
        let id = loadBalancer.id

        if request.name == nil, request.protocol == nil, request.healthCheck == nil {
            return try await response(for: loadBalancer, on: req.db)
        }
        let name = request.name
        try request.healthCheck?.validate()

        do {
            try await req.db.transaction { db in
                guard let current = try await LegacyLoadBalancerStore.locked(id: id, on: db) else {
                    throw Abort(.notFound, reason: "Load balancer no longer exists")
                }
                guard try await LegacyLoadBalancerStore.updateDefinition(
                    id: id,
                    name: name ?? current.name,
                    protocolName: request.protocol ?? current.protocolName,
                    healthCheck: request.healthCheck ?? current.healthCheck,
                    on: db) != nil
                else { throw Abort(.notFound, reason: "Load balancer no longer exists") }
                try await Self.bumpGeneration(of: id, on: db)
            }
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(
                .conflict, reason: "A load balancer named '\(name ?? loadBalancer.name)' already exists in this project"
            )
        }
        await req.application.agentService.syncDesiredStateToFleet()
        guard let refreshed = try await LegacyLoadBalancerStore.find(id: id, on: req.db) else {
            throw Abort(.notFound)
        }
        return try await response(for: refreshed, on: req.db)
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        let loadBalancer = try await find(req, action: "loadbalancer:delete")
        let id = loadBalancer.id
        let networkID = loadBalancer.logicalNetworkID
        try await req.db.transaction { db in
            // FloatingIP.load_balancer_id is SET NULL: deleting the load
            // balancer withdraws external exposure without releasing the
            // project's reserved floating address.
            _ = try await LegacyLoadBalancerStore.delete(id: id, on: db)
            // The LB and its cascading floating-IP detach both disappear from
            // this network's authoritative desired state. Advance the network
            // ordering key in the same transaction so an older payload cannot
            // recreate either OVN row after this deletion commits.
            switch try await DesiredStateGenerationWriter.advance(
                schema: LogicalNetwork.schema, id: networkID, on: db)
            {
            case .applied:
                break
            case .missing:
                throw Abort(.notFound, reason: "Network no longer exists")
            case .superseded:
                throw Abort(.internalServerError, reason: "Network generation did not advance")
            }
            try await RoleBindingService.revokeAll(nodeType: .loadBalancer, nodeID: id, on: db)
            try await QuotaEnforcementService.releaseLoadBalancer(projectID: loadBalancer.projectID, on: db)
        }
        await req.application.agentService.syncDesiredStateToFleet()
        return .noContent
    }

    // MARK: - Listeners

    @Sendable
    func listListeners(req: Request) async throws -> [LoadBalancerListenerResponse] {
        let loadBalancer = try await find(req, action: "loadbalancer:read")
        return try await LegacyLoadBalancerTargetStore.listeners(
            loadBalancerID: loadBalancer.id, on: req.db
        )
            .map(LoadBalancerListenerResponse.init(from:))
    }

    @Sendable
    func createListener(req: Request) async throws -> LoadBalancerListenerResponse {
        let loadBalancer = try await find(req, action: "loadbalancer:update")
        let request = try req.content.decode(CreateLoadBalancerListenerRequest.self)
        try Self.validatePort(request.port, name: "Listener")
        try Self.validatePort(request.backendPort, name: "Backend")
        let loadBalancerID = loadBalancer.id
        let listener: LoadBalancerListenerSnapshot
        do {
            listener = try await req.db.transaction { db in
                let listener = try await LegacyLoadBalancerTargetStore.insertListener(
                    loadBalancerID: loadBalancerID,
                    port: request.port,
                    backendPort: request.backendPort,
                    on: db)
                try await Self.markPendingAndBump(loadBalancerID, on: db)
                return listener
            }
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "Listener port \(request.port) already exists on this load balancer")
        }
        await req.application.agentService.syncDesiredStateToFleet()
        return LoadBalancerListenerResponse(from: listener)
    }

    @Sendable
    func updateListener(req: Request) async throws -> LoadBalancerListenerResponse {
        let loadBalancer = try await find(req, action: "loadbalancer:update")
        let request = try req.content.decode(UpdateLoadBalancerListenerRequest.self)
        try Self.validatePort(request.port, name: "Listener")
        try Self.validatePort(request.backendPort, name: "Backend")
        let loadBalancerID = loadBalancer.id
        let existing = try await findListener(req, loadBalancerID: loadBalancerID)
        let listener: LoadBalancerListenerSnapshot
        do {
            listener = try await req.db.transaction { db in
                guard let listener = try await LegacyLoadBalancerTargetStore.updateListener(
                    id: existing.id,
                    loadBalancerID: loadBalancerID,
                    port: request.port,
                    backendPort: request.backendPort,
                    on: db)
                else { throw Abort(.notFound, reason: "Listener not found on this load balancer") }
                try await Self.markPendingAndBump(loadBalancerID, on: db)
                return listener
            }
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "Listener port \(request.port) already exists on this load balancer")
        }
        await req.application.agentService.syncDesiredStateToFleet()
        return LoadBalancerListenerResponse(from: listener)
    }

    @Sendable
    func deleteListener(req: Request) async throws -> HTTPStatus {
        let loadBalancer = try await find(req, action: "loadbalancer:update")
        let loadBalancerID = loadBalancer.id
        let listener = try await findListener(req, loadBalancerID: loadBalancerID)
        try await req.db.transaction { db in
            guard try await LegacyLoadBalancerTargetStore.deleteListener(
                id: listener.id, loadBalancerID: loadBalancerID, on: db) != nil
            else { throw Abort(.notFound, reason: "Listener not found on this load balancer") }
            try await Self.markPendingAndBump(loadBalancerID, on: db)
        }
        await req.application.agentService.syncDesiredStateToFleet()
        return .noContent
    }

    // MARK: - Backends

    @Sendable
    func listBackends(req: Request) async throws -> [LoadBalancerBackendResponse] {
        let loadBalancer = try await find(req, action: "loadbalancer:read")
        return try await backendResponses(loadBalancerID: loadBalancer.id, on: req.db)
    }

    @Sendable
    func createBackend(req: Request) async throws -> LoadBalancerBackendResponse {
        let loadBalancer = try await find(req, action: "loadbalancer:update")
        let request = try req.content.decode(CreateLoadBalancerBackendRequest.self)
        let loadBalancerID = loadBalancer.id
        let target = try await resolveBackend(request, for: loadBalancer, on: req)
        let backend: LoadBalancerBackendSnapshot
        do {
            backend = try await req.db.transaction { db in
                let backend = try await LegacyLoadBalancerTargetStore.insertBackend(
                    loadBalancerID: loadBalancerID,
                    interfaceID: target.interface?.id,
                    address: target.address,
                    on: db)
                try await Self.markPendingAndBump(loadBalancerID, on: db)
                return backend
            }
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "This backend is already attached to the load balancer")
        }
        await req.application.agentService.syncDesiredStateToFleet()
        return LoadBalancerBackendResponse(from: backend, interface: target.interface)
    }

    @Sendable
    func deleteBackend(req: Request) async throws -> HTTPStatus {
        let loadBalancer = try await find(req, action: "loadbalancer:update")
        let loadBalancerID = loadBalancer.id
        guard let backendID = req.parameters.get("backendId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid backend ID")
        }
        guard try await LegacyLoadBalancerTargetStore.backend(
            id: backendID, loadBalancerID: loadBalancerID, on: req.db) != nil
        else { throw Abort(.notFound, reason: "Backend not found on this load balancer") }
        try await req.db.transaction { db in
            guard try await LegacyLoadBalancerTargetStore.deleteBackend(
                id: backendID, loadBalancerID: loadBalancerID, on: db) != nil
            else { throw Abort(.notFound, reason: "Backend not found on this load balancer") }
            try await Self.markPendingAndBump(loadBalancerID, on: db)
        }
        await req.application.agentService.syncDesiredStateToFleet()
        return .noContent
    }

    // MARK: - Helpers

    private func find(_ req: Request, action: String) async throws -> LoadBalancerSnapshot {
        guard let id = req.parameters.get("loadBalancerId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid load balancer ID")
        }
        return try await req.authorizedLoadBalancer(id, action: action)
    }

    private func findListener(
        _ req: Request,
        loadBalancerID: UUID
    ) async throws -> LoadBalancerListenerSnapshot {
        guard let listenerID = req.parameters.get("listenerId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid listener ID")
        }
        guard let listener = try await LegacyLoadBalancerTargetStore.listener(
            id: listenerID, loadBalancerID: loadBalancerID, on: req.db)
        else { throw Abort(.notFound, reason: "Listener not found on this load balancer") }
        return listener
    }

    private struct ResolvedBackend {
        let interface: VMNetworkInterface?
        let address: String?
    }

    private func resolveBackend(
        _ request: CreateLoadBalancerBackendRequest,
        for loadBalancer: LoadBalancerSnapshot,
        on req: Request
    ) async throws -> ResolvedBackend {
        let namesVM = request.vmId != nil || request.nicIndex != nil
        if namesVM == (request.ipAddress != nil) {
            throw Abort(.badRequest, reason: "Specify either vmId with nicIndex, or ipAddress")
        }
        if let address = request.ipAddress {
            guard let parsed = IPAMService.parseIPv4(address) else {
                throw Abort(.badRequest, reason: "Backend IP address is not valid IPv4")
            }
            return ResolvedBackend(interface: nil, address: IPAMService.formatIPv4(parsed))
        }
        guard let vmID = request.vmId, let nicIndex = request.nicIndex, nicIndex >= 0 else {
            throw Abort(.badRequest, reason: "vmId and a non-negative nicIndex are required together")
        }
        let vm = try await req.reachableVM(vmID, action: "vm:update")
        try ProjectContainment.require(
            "VM", in: vm.projectID,
            sameProjectAs: "the load balancer", in: loadBalancer.projectID)
        guard let interface = try await LegacyVMNetworkInterfaceStore.interface(
            vmID: vmID, orderIndex: nicIndex, on: req.db)
        else { throw Abort(.notFound, reason: "VM interface at nicIndex \(nicIndex) not found") }
        guard let loadedInterface = try await LegacyInterfaceAddressStore.loading(
            [interface], on: req.db).first
        else {
            throw Abort(.internalServerError, reason: "Could not load backend interface addresses")
        }
        guard loadedInterface.ipv4Address != nil else {
            throw Abort(.conflict, reason: "Backend interface has no IPv4 address")
        }
        guard
            let loadBalancerNetwork = try await LogicalNetwork.find(
                loadBalancer.logicalNetworkID, on: req.db),
            let backendNetwork = try await LogicalNetwork.find(
                interface.logicalNetworkID, on: req.db)
        else {
            throw Abort(.conflict, reason: "Load balancer or backend network no longer exists")
        }
        guard loadBalancerNetwork.siteID == backendNetwork.siteID else {
            throw Abort(
                .conflict,
                reason:
                    "Backend interface network '\(backendNetwork.name)' is pinned to a different site than load balancer network '\(loadBalancerNetwork.name)'"
            )
        }
        return ResolvedBackend(interface: loadedInterface, address: nil)
    }

    private func response(
        for loadBalancer: LoadBalancerSnapshot, on db: Database
    ) async throws -> LoadBalancerResponse {
        let listeners = try await LegacyLoadBalancerTargetStore.listeners(
            loadBalancerID: loadBalancer.id, on: db)
        let backends = try await loadedBackends(loadBalancerID: loadBalancer.id, on: db)
        return LoadBalancerResponse(from: loadBalancer, listeners: listeners, backends: backends)
    }

    private func backendResponses(loadBalancerID: UUID, on db: Database) async throws
        -> [LoadBalancerBackendResponse]
    {
        try await loadedBackends(loadBalancerID: loadBalancerID, on: db).map {
            LoadBalancerBackendResponse(from: $0.0, interface: $0.1)
        }
    }

    private func loadedBackends(loadBalancerID: UUID, on db: Database) async throws
        -> [(LoadBalancerBackendSnapshot, VMNetworkInterface?)]
    {
        let backends = try await LegacyLoadBalancerTargetStore.backends(
            loadBalancerID: loadBalancerID, on: db)
        let interfaceIDs = backends.compactMap(\.interfaceID)
        let interfaces = interfaceIDs.isEmpty
            ? []
            : try await LegacyVMNetworkInterfaceStore.interfaces(ids: interfaceIDs, on: db)
        let loadedInterfaces = try await LegacyInterfaceAddressStore.loading(interfaces, on: db)
        let byID = Dictionary(uniqueKeysWithValues: loadedInterfaces.compactMap { interface in
            interface.id.map { ($0, interface) }
        })
        return backends.map { ($0, $0.interfaceID.flatMap { byID[$0] }) }
    }

    private static func validatePort(_ port: Int, name: String) throws {
        guard (1...65_535).contains(port) else {
            throw Abort(.badRequest, reason: "\(name) port must be 1-65535")
        }
    }

    private static func markPendingAndBump(_ id: UUID, on db: Database) async throws {
        guard try await LegacyLoadBalancerStore.markPending(id: id, on: db) != nil else {
            throw Abort(.notFound, reason: "Load balancer no longer exists")
        }
        try await bumpGeneration(of: id, on: db)
    }

    private static func bumpGeneration(of id: UUID, on db: Database) async throws {
        switch try await DesiredStateGenerationWriter.advance(
            schema: LoadBalancer.schema, id: id, on: db)
        {
        case .applied:
            return
        case .missing:
            throw Abort(.notFound, reason: "Load balancer no longer exists")
        case .superseded:
            throw Abort(.internalServerError, reason: "Load balancer generation did not advance")
        }
    }
}
