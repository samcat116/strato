import Fluent
import Foundation
import Vapor
import StratoShared

/// `/api/sandboxes`: the API surface for OCI-image Firecracker microVMs
/// (issue #413). Deliberately parallel to `VMController` — same 202-Accepted
/// async-operation pattern (issue #412), same desired-state mutation contract —
/// but its own resource: sandboxes have no volumes, consoles, or hypervisor
/// choice, and reference images by OCI ref rather than the `Image` model.
struct SandboxController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let sandboxes = routes.grouped("api", "sandboxes")
        sandboxes.get(use: index)
        sandboxes.post(use: create)
        sandboxes.group(":sandboxID") { sandbox in
            sandbox.get(use: show)
            sandbox.put(use: update)
            sandbox.delete(use: delete)
            sandbox.post("start", use: start)
            sandbox.post("stop", use: stop)
            sandbox.post("restart", use: restart)
            sandbox.get("status", use: status)
            sandbox.get("operations", use: listOperations)
            sandbox.post("exec", use: exec)
            // Snapshots / checkpoint-resume (issue #426); handlers live in
            // SandboxSnapshotController.swift.
            sandbox.post("snapshots", use: createSnapshot)
            sandbox.get("snapshots", use: listSnapshots)
            sandbox.group("snapshots", ":snapshotID") { snapshot in
                snapshot.delete(use: deleteSnapshot)
                snapshot.post("restore", use: restoreSnapshot)
                // Snapshot mobility (issue #428); handlers live in
                // SandboxSnapshotTransferController.swift. The artifact
                // routes are signed agent routes (streamed bodies, no
                // session — see the AuthorizationMiddleware carve-out).
                snapshot.post("export", use: exportSnapshot)
                snapshot.on(.PUT, "artifacts", ":artifactKind", body: .stream, use: uploadSnapshotArtifact)
                snapshot.get("artifacts", ":artifactKind", use: downloadSnapshotArtifact)
            }
        }
    }

    // MARK: - Async operation plumbing

    /// The `202` body every accepted sandbox lifecycle mutation answers with
    /// (STR-147) — the sandbox as the mutation left it, plus the generation its
    /// `conditions.observedGeneration` has to reach. Sandbox counterpart of
    /// `VMController.acceptedResponse`.
    /// Internal, not private: the snapshot handlers in
    /// `SandboxSnapshotController.swift` extend this same type from another file
    /// and answer a restore with the sandbox's own accepted-mutation shape
    /// (STR-151).
    static func acceptedResponse(
        for sandbox: Sandbox, _ accepted: ResourceMutation.Accepted, on req: Request
    ) async throws -> Response {
        return try AcceptedMutation(await detailResponse(for: sandbox, on: req), accepted).acceptedResponse()
    }

    // MARK: - Reads

    /// GET /api/sandboxes
    /// Query params: organization_id (optional) — narrows to one org's hierarchy;
    /// limit/offset (optional) — select the page.
    func index(req: Request) async throws -> PagedResponse<SandboxDetailResponse> {
        let paging = try ListPaging.decode(from: req)
        let sandboxes = try await visibleSandboxes(req: req)
        return paging.page(sandboxes)
    }

    /// Every sandbox the caller may read, newest first, ready for slicing.
    func visibleSandboxes(req: Request) async throws -> [SandboxDetailResponse] {
        // Any authenticated principal, as in VMController.visibleVMs — which
        // sandboxes it may see is the `canFilter` answer below (issue #495).
        _ = try req.requireActingPrincipal()

        // Scoped through the sandbox's project, as in VMController.index.
        var query = Sandbox.query(on: req.db)
            // The response reports each NIC's network, addresses and security
            // groups (STR-34, STR-102). Fluent batches children one `IN` query
            // per relation, so this is three extra queries for the whole page,
            // not three per sandbox.
            .with(\.$networkInterfaces) {
                $0.with(\.$securityGroupMemberships).with(\.$addresses).with(\.$logicalNetwork)
            }
            .sort(\.$createdAt, .descending)
            .sort(\.$id, .descending)
        if let orgFilter = try await OrganizationAccessService.organizationListFilter(on: req) {
            let projectIDs = try await orgFilter.projectIDs(on: req.db)
            if projectIDs.isEmpty { return [] }
            query = query.filter(\.$project.$id ~~ projectIDs)
        }

        // One batched decision for the whole page, as in VMController.index.
        let allSandboxes = try await query.all()
        let nodes = allSandboxes.compactMap { $0.id.map { IAMNode(type: .sandbox, id: $0) } }
        let readable = try await req.canFilter("sandbox:read", on: nodes)

        let visible = allSandboxes.filter { sandbox in
            sandbox.id.map { readable.contains(IAMNode(type: .sandbox, id: $0)) } ?? false
        }
        // Batched, like the VM list: since STR-103 the enforcement verdict reads
        // the host row (it needs the sandbox-networking capability), so a
        // per-row call would be one query per sandbox plus a site lookup each.
        let enforcedBySandbox = try await SecurityGroupService.enforcementBySandbox(
            visible,
            offlineGrace: req.controlPlaneConfiguration.double(.siteControllerOfflineGraceSeconds),
            on: req.db)
        return visible.map { sandbox in
            SandboxDetailResponse(
                from: sandbox,
                securityGroupsEnforced: sandbox.id.flatMap { enforcedBySandbox[$0] })
        }
    }

    /// Fetch a sandbox by its :sandboxID route parameter and enforce a
    /// permission on it (per-handler defense in depth over the middleware).
    func fetchSandboxWithAction(req: Request, action: String) async throws -> Sandbox {
        guard let sandboxID = req.parameters.get("sandboxID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid sandbox ID")
        }

        return try await req.authorizedSandbox(sandboxID, action: action)
    }

    /// Loads the NIC and everything the response reports about it: its
    /// addresses, its logical network (for the display name), and its
    /// security-group memberships. Without this `securityGroupIds` is nil,
    /// which reads as "no NIC" — so every handler that returns a detail
    /// response calls it.
    private static func loadNICDetail(_ sandbox: Sandbox, on db: Database) async throws {
        try await sandbox.$networkInterfaces.load(on: db)
        for interface in sandbox.networkInterfaces {
            try await interface.$securityGroupMemberships.load(on: db)
            try await interface.$addresses.load(on: db)
            try await interface.$logicalNetwork.load(on: db)
        }
    }

    /// The detail response for one sandbox, with its NIC loaded and its
    /// enforcement verdict resolved. Single-sandbox only — the list path uses
    /// `enforcementBySandbox`, which memoizes the host and site lookups this
    /// makes per call.
    static func detailResponse(
        for sandbox: Sandbox, on req: Request, database: (any Database)? = nil
    ) async throws
        -> SandboxDetailResponse
    {
        let database = database ?? req.db
        try await loadNICDetail(sandbox, on: database)
        return SandboxDetailResponse(
            from: sandbox,
            securityGroupsEnforced: try await SecurityGroupService.sandboxEnforcement(
                for: sandbox,
                offlineGrace: req.controlPlaneConfiguration.double(.siteControllerOfflineGraceSeconds),
                on: database))
    }

    func show(req: Request) async throws -> SandboxDetailResponse {
        _ = try req.requireActingPrincipal()
        let sandbox = try await fetchSandboxWithAction(req: req, action: "sandbox:read")
        return try await Self.detailResponse(for: sandbox, on: req)
    }

    func status(req: Request) async throws -> SandboxDetailResponse {
        _ = try req.requireActingPrincipal()
        let sandbox = try await fetchSandboxWithAction(req: req, action: "sandbox:read")

        // The database row *is* the observed state: the owning agent's
        // periodic observed-state reports keep it fresh, so no agent
        // round-trip happens here (replica-independent, like VMs).
        return try await Self.detailResponse(for: sandbox, on: req)
    }

    func listOperations(req: Request) async throws -> [OperationResponse] {
        let sandbox = try await fetchSandboxWithAction(req: req, action: "sandbox:read")
        let sandboxID = try sandbox.requireID()

        let limit = try req.intQuery("limit", default: 20, in: 1...100)

        return try await OperationFacade.history(
            resourceKind: .sandbox, resourceID: sandboxID, limit: limit, on: req.db)
    }

    // MARK: - Create

    func create(req: Request) async throws -> Response {
        try await SandboxCreationWorkflow.create(req: req)
    }
    /// Allocates and persists the sandbox's single NIC (issue #416), reusing the
    /// VM NIC's MAC generation and IPAM. Must run inside the create transaction
    /// so the address is reserved before the `202` returns and before placement.
    ///
    /// A named network is resolved within the sandbox's own project, exactly as
    /// VM create resolves it (issue #765). Naming none is not an error the way
    /// it is for a VM — the sandbox is simply created **with no NIC**, except
    /// for a fork, whose caller passes the source's network here because the
    /// restore cannot drop the checkpointed device (STR-104). The NIC
    /// pins where the sandbox can be placed: since STR-103 a NIC constrains the
    /// sandbox to a host that advertises sandbox networking (and, if the network
    /// is site-pinned, to that site), and placement is refused rather than
    /// degraded when none is available. Refusing the create for naming *no*
    /// network, or silently picking one on the caller's behalf, would both be
    /// worse than reserving nothing.
    ///
    /// The NIC joins its security groups here too (STR-34, STR-102), the
    /// project's default when the caller named none — the same ≥1-group
    /// invariant VM create establishes, and the reason a sandbox is never even
    /// briefly unfiltered once its port does exist: the memberships are written
    /// in this same transaction, long before the sandbox is placeable, so the
    /// agent's port create has them in hand and joins the drop group before the
    /// veth goes live. Conditional on a NIC existing, unlike the VM path: a
    /// network-less sandbox has nothing to attach groups to.
    static func attachNIC(
        to sandboxID: UUID, projectID: UUID, requestedNetworkID: UUID?, requestedNetworkName: String?,
        securityGroupIDs: [UUID], on db: Database
    ) async throws {
        guard requestedNetworkID != nil || requestedNetworkName != nil else { return }

        let logicalNetwork = try await LogicalNetworkService.resolveForWorkloadCreate(
            requestedID: requestedNetworkID,
            requestedName: requestedNetworkName,
            projectID: projectID,
            on: db
        )
        let logicalNetworkID = try logicalNetwork.requireID()
        let allocation = try await IPAMService.allocateIP(for: logicalNetwork, on: db)
        // Dual-stack network: the NIC gets one address per family.
        let allocation6 = try await IPAMService.allocateIPv6(for: logicalNetwork, on: db)

        let interfaceID = UUID()
        let macAddress = try await MACAllocator.allocate(
            for: .sandboxInterface, ownerID: interfaceID, on: db)
        let networkInterface = SandboxNetworkInterface(
            id: interfaceID,
            sandboxID: sandboxID,
            logicalNetworkID: logicalNetworkID,
            macAddress: macAddress.description
        )
        try await networkInterface.save(on: db)

        let groupIDs: [UUID]
        if securityGroupIDs.isEmpty {
            groupIDs = [try await SecurityGroupService.ensureDefaultGroup(projectID: projectID, on: db).requireID()]
        } else {
            groupIDs = securityGroupIDs
        }
        for groupID in groupIDs {
            try await SandboxInterfaceSecurityGroup(interfaceID: interfaceID, securityGroupID: groupID)
                .save(on: db)
        }

        let address = SandboxInterfaceAddress(
            interfaceID: interfaceID,
            logicalNetworkID: logicalNetworkID,
            family: .ipv4,
            address: allocation.ipAddress,
            prefixLength: allocation.prefixLength,
            gateway: logicalNetwork.gateway
        )
        try await address.save(on: db)
        if let allocation6 {
            let address6 = SandboxInterfaceAddress(
                interfaceID: interfaceID,
                logicalNetworkID: logicalNetworkID,
                family: .ipv6,
                address: allocation6.ipAddress,
                prefixLength: allocation6.prefixLength,
                gateway: logicalNetwork.gateway6
            )
            try await address6.save(on: db)
        }
    }

    // MARK: - Update

    func update(req: Request) async throws -> SandboxDetailResponse {
        _ = try req.requireActingPrincipal()
        let sandbox = try await fetchSandboxWithAction(req: req, action: "sandbox:update")

        struct UpdateSandboxRequest: Content, ValidatedRequestBody {
            var name: String?
            let ttlSeconds: Int?

            mutating func validate() throws {
                name = try Validate.name(name)
            }
        }

        let updateRequest = try req.content.decodeValidated(UpdateSandboxRequest.self)

        // Only metadata is updatable: image/resources/process changes would
        // need a re-converge story that phase 1 doesn't have.
        if let name = updateRequest.name {
            sandbox.name = name
        }
        if let ttl = updateRequest.ttlSeconds {
            guard ttl > 0 else {
                throw Abort(.badRequest, reason: "'ttlSeconds' must be positive")
            }
            sandbox.ttlSeconds = ttl
        }

        try await sandbox.save(on: req.db)
        return try await Self.detailResponse(for: sandbox, on: req)
    }

    // MARK: - Lifecycle

    func start(req: Request) async throws -> Response {
        let user = try req.requireActingUser("Mutating a sandbox")
        let sandbox = try await fetchSandboxWithAction(req: req, action: "sandbox:start")

        guard sandbox.canStart else {
            throw Abort(
                .badRequest, reason: "Sandbox cannot be started in current state: \(sandbox.status.rawValue)")
        }

        let userID = try user.requireID()
        let accepted = try await req.resourceMutation.accept(
            .boot, on: sandbox, actor: .user(userID), dispatch: .stateSync,
            on: req.db, app: req.application
        ) { @Sendable _ in
            sandbox.setDesiredStatus(.running)
        }

        return try await Self.acceptedResponse(for: sandbox, accepted, on: req)
    }

    func stop(req: Request) async throws -> Response {
        let user = try req.requireActingUser("Mutating a sandbox")
        let sandbox = try await fetchSandboxWithAction(req: req, action: "sandbox:stop")

        guard sandbox.canStop else {
            throw Abort(
                .badRequest, reason: "Sandbox cannot be stopped in current state: \(sandbox.status.rawValue)")
        }

        let userID = try user.requireID()
        let accepted = try await req.resourceMutation.accept(
            .shutdown, on: sandbox, actor: .user(userID), dispatch: .stateSync,
            on: req.db, app: req.application
        ) { @Sendable _ in
            sandbox.setDesiredStatus(.stopped)
        }

        return try await Self.acceptedResponse(for: sandbox, accepted, on: req)
    }

    func restart(req: Request) async throws -> Response {
        let user = try req.requireActingUser("Mutating a sandbox")
        let sandbox = try await fetchSandboxWithAction(req: req, action: "sandbox:restart")

        guard sandbox.isRunning else {
            throw Abort(
                .badRequest,
                reason: "Sandbox must be running to restart. Current state: \(sandbox.status.rawValue)")
        }

        // Restart is expressed as a fresh desired-running generation: the
        // generation bump is what obliges the agent to act (there is no
        // imperative sandbox reboot message on the wire). The agent-side
        // interpretation lands with the sandbox runtime (issue #421); until an
        // agent acknowledges the new generation the sandbox reads as
        // unconverged and the convergence deadline backstops it. Unlike the
        // VM's reboot — an imperative RPC with no generation to converge on,
        // and so still an operation until STR-151 — this one already rides the
        // desired-state sync, which is why it converts with the rest.
        let userID = try user.requireID()
        let accepted = try await req.resourceMutation.accept(
            .reboot, on: sandbox, actor: .user(userID), dispatch: .stateSync,
            on: req.db, app: req.application
        ) { @Sendable _ in
            sandbox.setDesiredStatus(.running)
        }

        return try await Self.acceptedResponse(for: sandbox, accepted, on: req)
    }

    // MARK: - Exec (issue #423)

    /// `POST /api/sandboxes/:id/exec`: mint an exec session inside a running
    /// sandbox. Returns `201 Created` with the session id and the WebSocket
    /// attach path; the actual exec starts when the browser attaches.
    ///
    /// Exec is relayed over the agent's WebSocket, so it requires the
    /// control-plane replica that holds the agent socket (console parity;
    /// the single-replica limitation is documented in
    /// `docs/architecture/sandboxes.md`).
    func exec(req: Request) async throws -> Response {
        let user = try req.requireActingUser("Mutating a sandbox")

        let execRequest = try req.content.decode(GuestExecRequest.self)
        try execRequest.validate()

        let sandbox = try await fetchSandboxWithAction(req: req, action: "sandbox:exec")
        let sandboxID = try sandbox.requireID()

        guard sandbox.isRunning else {
            throw Abort(
                .badRequest,
                reason: "Sandbox must be running to exec. Current state: \(sandbox.status.rawValue)")
        }

        guard let agentIdString = sandbox.hypervisorId,
            let agentId = UUID(uuidString: agentIdString)
        else {
            throw Abort(.conflict, reason: "Sandbox is not placed on any agent")
        }

        guard let agent = try await Agent.find(agentId, on: req.db) else {
            throw Abort(.internalServerError, reason: "Agent not found for sandbox")
        }

        // Exec frames flow over the agent's WebSocket, which only this
        // process can write to. If another replica holds the socket the
        // client must retry against that replica (console parity).
        guard req.application.websocketManager.getConnection(agentKey: agent.identity.key) != nil else {
            throw Abort(
                .serviceUnavailable,
                reason:
                    "Agent '\(agent.name)' is not connected to this control-plane replica; exec requires the replica holding the agent socket"
            )
        }

        let session = req.guestExecSessionManager.createPendingSession(
            resourceKind: .sandbox,
            resourceId: sandboxID.uuidString,
            agentKey: agent.identity.key,
            userId: try user.requireID().uuidString,
            command: execRequest.command,
            env: execRequest.env,
            workingDir: execRequest.workingDir,
            tty: execRequest.tty ?? false,
            rows: execRequest.rows,
            cols: execRequest.cols,
            outputMode: execRequest.outputMode ?? .raw
        )

        let response = Response(status: .created)
        try response.content.encode(
            GuestExecSessionResponse(
                sessionId: session.sessionId,
                websocketPath: "/api/sandboxes/\(sandboxID.uuidString)/exec/\(session.sessionId)/attach",
                expiresAt: session.expiresAt,
                outputMode: session.outputMode
            ))
        return response
    }

    // MARK: - Delete

    func delete(req: Request) async throws -> Response {
        let user = try req.requireActingUser("Mutating a sandbox")
        let sandbox = try await fetchSandboxWithAction(req: req, action: "sandbox:delete")

        // Deletion via state sync, exactly like VMs: desired becomes
        // `.absent`, the sandbox is stamped with the finalizers its teardown
        // owes, the agent tears the sandbox down on its next sync, and the row
        // is removed only once the last finalizer clears. Unplaced sandboxes
        // and offline agents keep a direct path.
        let sandboxID = try sandbox.requireID()
        let userID = try user.requireID()
        let app = req.application
        let agentOnline: Bool
        if let hypervisorId = sandbox.hypervisorId {
            agentOnline = await app.agentService.agentIsOnline(agentId: hypervisorId)
        } else {
            agentOnline = false
        }

        let strategy: ResourceMutation.Dispatch =
            agentOnline
            ? .stateSync
            : .directResolution { @Sendable db in
                try await Self.performDirectDeletion(sandbox: sandbox, on: db, app: app)
            }

        let accepted = try await req.resourceMutation.accept(
            .delete, on: sandbox, actor: .user(userID), dispatch: strategy,
            on: req.db, app: app,
            idempotencyResponseBody: { @Sendable sandbox, accepted, db in
                try await AcceptedMutation(
                    Self.detailResponse(for: sandbox, on: req, database: db), accepted
                ).encodedBody()
            }
        ) { @Sendable db in
            try await Self.requireSnapshotLineageDeletable(for: sandboxID, on: db)
            // Stamp before the mark — see the VM delete path for why.
            try await ResourceFinalizerService.stampForDeletion(sandbox, on: db)
            sandbox.setDesiredStatus(.absent)
        }
        if let response = accepted.cachedResponse() { return response }
        return try await Self.acceptedResponse(for: sandbox, accepted, on: req)
    }

    /// The direct-removal work for a sandbox whose agent is gone (never placed,
    /// or offline cluster-wide) or that is being expired: nothing will ever
    /// confirm teardown, so the agent's finalizer is force-cleared, which reaps
    /// the row (exported snapshot objects, bindings, record, quota) since it is
    /// the only participant today. Returns whether the row is gone — false when
    /// another participant still holds a finalizer, in which case the delete is
    /// under way rather than done and the reap that eventually removes the row
    /// is what appends the terminal event. Wrapped by `ResourceMutation`'s
    /// `.directResolution` dispatch. If the agent ever comes back still
    /// carrying the sandbox, its observed-state report surfaces it for operator
    /// attention.
    ///
    /// Internal rather than private because the expiry sweep (issue #424)
    /// deletes down this same path, so a TTL-driven deletion releases quota
    /// exactly like a user-initiated one.
    @discardableResult
    static func performDirectDeletion(
        sandbox: Sandbox, on db: any Database, app: Application
    ) async throws -> Bool {
        let sandboxID = try sandbox.requireID()
        if sandbox.hypervisorId != nil {
            app.logger.warning(
                "Deleting sandbox record without agent teardown; agent is offline",
                metadata: ["strato.sandbox.id": .string(sandboxID.uuidString)])
        }

        let outcome: ResourceFinalizerService.ClearOutcome
        do {
            outcome = try await ResourceFinalizerService.clear(
                .agentAbsent, from: sandbox, on: db, app: app)
        } catch {
            throw ResourceMutation.WorkError(
                "Failed to delete sandbox record: \(error.localizedDescription)")
        }
        // Another participant still owes cleanup: the delete is under way, not
        // done, so nothing terminal is recorded here.
        if case .held(let remaining) = outcome {
            app.logger.info(
                "Sandbox delete is waiting on finalizers other than the agent's",
                metadata: [
                    "strato.sandbox.id": .string(sandboxID.uuidString),
                    "finalizers": .string(remaining.joined(separator: ",")),
                ])
        }
        return outcome.isRemoved
    }
}
