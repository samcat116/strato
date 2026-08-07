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
        try await loadNICSecurityGroups(sandbox, on: req.db)
        return try AcceptedMutation(SandboxDetailResponse(from: sandbox), accepted).acceptedResponse()
    }

    // `beginOperation` and `completeOperation` — the sandbox-flavored front of
    // `ResourceOperation.begin` and its verdict half — went with the last
    // mutation that needed them. Snapshot capture, delete and export became
    // desired artifacts at wire v33 (STR-150) and restore became an edge-nonce
    // at v34 (STR-151), so every sandbox mutation now goes through
    // `ResourceMutation.accept` and answers from the sandbox's own `conditions`.

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
            // The response reports the NIC's security groups (STR-34).
            .with(\.$networkInterfaces) { $0.with(\.$securityGroupMemberships) }
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

        return allSandboxes.compactMap { sandbox in
            guard let id = sandbox.id, readable.contains(IAMNode(type: .sandbox, id: id)) else { return nil }
            return SandboxDetailResponse(from: sandbox)
        }
    }

    /// Fetch a sandbox by its :sandboxID route parameter and enforce a
    /// permission on it (per-handler defense in depth over the middleware).
    func fetchSandboxWithPermission(req: Request, permission: String) async throws -> Sandbox {
        guard let sandboxID = req.parameters.get("sandboxID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid sandbox ID")
        }

        return try await req.authorizedSandbox(sandboxID, permission: permission)
    }

    /// Loads the NIC and its security-group memberships so the response can
    /// report `securityGroupIds`. Without this the field is nil, which reads
    /// as "no NIC" — so every handler that returns a detail response calls it.
    private static func loadNICSecurityGroups(_ sandbox: Sandbox, on db: Database) async throws {
        try await sandbox.$networkInterfaces.load(on: db)
        for interface in sandbox.networkInterfaces {
            try await interface.$securityGroupMemberships.load(on: db)
        }
    }

    func show(req: Request) async throws -> SandboxDetailResponse {
        _ = try req.requireActingPrincipal()
        let sandbox = try await fetchSandboxWithPermission(req: req, permission: "read")
        try await Self.loadNICSecurityGroups(sandbox, on: req.db)
        return SandboxDetailResponse(from: sandbox)
    }

    func status(req: Request) async throws -> SandboxDetailResponse {
        _ = try req.requireActingPrincipal()
        let sandbox = try await fetchSandboxWithPermission(req: req, permission: "read")
        try await Self.loadNICSecurityGroups(sandbox, on: req.db)

        // The database row *is* the observed state: the owning agent's
        // periodic observed-state reports keep it fresh, so no agent
        // round-trip happens here (replica-independent, like VMs).
        return SandboxDetailResponse(from: sandbox)
    }

    func listOperations(req: Request) async throws -> [OperationResponse] {
        _ = try req.requireActingPrincipal()
        let sandbox = try await fetchSandboxWithPermission(req: req, permission: "read")
        let sandboxID = try sandbox.requireID()

        let limit = try req.intQuery("limit", default: 20, in: 1...100)

        return try await OperationFacade.history(
            resourceKind: .sandbox, resourceID: sandboxID, limit: limit, on: req.db)
    }

    // MARK: - Create

    func create(req: Request) async throws -> Response {
        let user = try req.requireActingUser("Creating a sandbox")

        struct CreateSandboxRequest: Content {
            let name: String
            /// OCI image reference, e.g. `ghcr.io/acme/worker:v3`.
            let image: String?
            /// Ready sandbox snapshot to restore into a new identity (issue
            /// #427). Mutually exclusive with image/machine/process fields.
            let restoreFrom: UUID?
            let projectId: UUID?
            let environment: String?
            let cpus: Int?
            /// Guest memory in bytes.
            let memory: Int64?
            let entrypoint: [String]?
            let cmd: [String]?
            let env: [String: String]?
            let workingDir: String?
            let ttlSeconds: Int?
            /// Firecracker CPU template (issue #428), decided here — at
            /// create time — because it is baked into every checkpoint's
            /// guest state: templated snapshots restore on any same-arch
            /// host, un-templated ones only on identical CPU models.
            let cpuTemplate: String?
            /// Logical network for the sandbox's NIC, within its own project
            /// (issue #765). Mutually exclusive with `networkName`; omitting
            /// both means no NIC, since sandbox guest networking does not exist
            /// yet (see `attachNIC`).
            let networkId: UUID?
            let networkName: String?
            /// Security groups for the sandbox's NIC (STR-34). Omitted means
            /// the project's default group. Only meaningful alongside a
            /// network, since without one there is no NIC to attach them to.
            let securityGroupIds: [UUID]?
        }

        let createRequest = try req.content.decode(CreateSandboxRequest.self)

        let requestedName = createRequest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedName.isEmpty else {
            throw Abort(.badRequest, reason: "'name' must be non-empty")
        }

        var restoreSnapshot: SandboxSnapshot?
        var restoreSource: Sandbox?
        if let snapshotID = createRequest.restoreFrom {
            guard createRequest.image == nil, createRequest.cpus == nil, createRequest.memory == nil,
                createRequest.entrypoint == nil, createRequest.cmd == nil, createRequest.env == nil,
                createRequest.workingDir == nil, createRequest.cpuTemplate == nil
            else {
                throw Abort(
                    .badRequest,
                    reason:
                        "'restoreFrom' cannot be combined with image, CPU, memory, or process overrides; a fork preserves the checkpointed machine shape"
                )
            }
            let canReadSnapshot = try await req.can("read", on: "sandbox_snapshot", id: snapshotID.uuidString)
            guard canReadSnapshot else {
                throw Abort(.forbidden, reason: "You don't have permission to read this snapshot")
            }
            guard let snapshot = try await SandboxSnapshot.find(snapshotID, on: req.db) else {
                throw Abort(.notFound, reason: "Restore snapshot not found")
            }
            guard snapshot.isReady else {
                throw Abort(
                    .conflict,
                    reason: "Snapshot cannot be forked in status '\(snapshot.status.rawValue)'")
            }
            guard let source = try await Sandbox.find(snapshot.$sandbox.id, on: req.db) else {
                throw Abort(.conflict, reason: "Snapshot source sandbox no longer exists")
            }
            // The fork must have at least one place to land: the snapshot's
            // own agent (local artifacts) or, once exported, any compatible
            // agent (issue #428). The scheduler applies the per-agent
            // compatibility filters at placement; this gate only rejects
            // forks that could never place anywhere.
            let pinnedAgent: Agent?
            if let pinnedAgentID = snapshot.agentId, let pinnedAgentUUID = UUID(uuidString: pinnedAgentID) {
                pinnedAgent = try await Agent.find(pinnedAgentUUID, on: req.db)
            } else {
                pinnedAgent = nil
            }
            let pinnedAgentForkCapable =
                pinnedAgent.map { WireProtocol.supportsSandboxFork($0.wireProtocolVersion ?? 0) } ?? false
            guard pinnedAgentForkCapable || snapshot.isExported else {
                if let pinnedAgent {
                    throw Abort(
                        .conflict,
                        reason:
                            "Agent '\(pinnedAgent.name)' is too old for sandbox forks (wire protocol \(pinnedAgent.wireProtocolVersion ?? 0), need >= \(WireProtocol.sandboxForkMinimumVersion)) and the snapshot is not exported"
                    )
                }
                throw Abort(
                    .conflict,
                    reason:
                        "Snapshot has no available owning agent and no exported copy; export snapshots before their agent goes away to keep them forkable"
                )
            }
            guard SandboxSnapshotForkLayout.supportsFork(snapshot.forkLayoutVersion) else {
                throw Abort(
                    .conflict,
                    reason: "Snapshot was not captured in a fork-compatible jailed layout")
            }
            guard
                SandboxGuestControlProtocol.supportsReidentify(
                    snapshot.guestControlProtocolVersion)
            else {
                throw Abort(
                    .conflict,
                    reason:
                        "Snapshot's checkpointed guest is too old for sandbox forks (guest control protocol \(snapshot.guestControlProtocolVersion ?? 0), need >= \(SandboxGuestControlProtocol.reidentifyMinimumVersion))"
                )
            }
            restoreSnapshot = snapshot
            restoreSource = source
        } else {
            let imageRef = createRequest.image?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !imageRef.isEmpty else {
                throw Abort(
                    .badRequest,
                    reason: "Exactly one of 'image' or 'restoreFrom' must be provided")
            }
        }

        // Resolve the target project and environment, mirroring VM creation via
        // the shared `req.resolveProjectForCreate` helper (issue #675).
        let (project, environment) = try await req.resolveProjectForCreate(
            requestedProjectId: createRequest.projectId,
            requestedEnvironment: createRequest.environment,
            user: user,
            resourceKind: "sandboxes"
        )
        let projectId = try project.requireID()

        // The NIC's security groups (STR-34), validated against this project
        // before anything is written. Naming groups without a network is a
        // mistake worth reporting rather than silently dropping: there would
        // be no NIC for them to land on.
        let requestedSecurityGroupIds = try await SecurityGroupService.resolveRequestedGroupIDs(
            createRequest.securityGroupIds, projectID: projectId, on: req.db)
        if !requestedSecurityGroupIds.isEmpty,
            createRequest.networkId == nil, createRequest.networkName == nil
        {
            throw Abort(
                .badRequest,
                reason: "'securityGroupIds' needs a network: without one the sandbox has no interface to attach to")
        }

        let imageRef =
            restoreSource?.image
            ?? (createRequest.image ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cpus = restoreSource?.cpus ?? createRequest.cpus ?? 1
        let memory = restoreSource?.memory ?? createRequest.memory ?? Int64(1024 * 1024 * 1024)
        // Both figures are bounded above as well as below (issue #826). A
        // sandbox has no `maxCpu`/`maxMemory` ceiling to bound it transitively
        // the way a VM's create does, so these are the only gate between a
        // caller-supplied size and the quota arithmetic it is summed into — and
        // a sandbox's memory is additionally the estimate its snapshots reserve
        // storage against. A size no host could ever satisfy is a mistake the
        // API can catch, not a workload it should commit unplaceably.
        //
        // A restore or fork sizes itself from the source snapshot, so the
        // reason names that instead of a field the caller never sent.
        let sizedFromSnapshot = restoreSource != nil
        guard cpus > 0 else {
            throw Abort(.badRequest, reason: "'cpus' must be positive")
        }
        guard cpus <= WorkloadSizeLimits.maxVCPUs else {
            throw Abort(
                .badRequest,
                reason: sizedFromSnapshot
                    ? "The source sandbox's vCPU count must not exceed \(WorkloadSizeLimits.maxVCPUs)"
                    : "'cpus' must not exceed \(WorkloadSizeLimits.maxVCPUs)")
        }
        guard memory > 0 else {
            throw Abort(.badRequest, reason: "'memory' must be positive")
        }
        guard memory <= WorkloadSizeLimits.maxMemoryBytes else {
            throw Abort(
                .badRequest,
                reason: sizedFromSnapshot
                    ? "The source sandbox's memory must not exceed \(WorkloadSizeLimits.maxMemoryBytes) bytes"
                    : "'memory' must not exceed \(WorkloadSizeLimits.maxMemoryBytes) bytes")
        }
        if let ttl = createRequest.ttlSeconds, ttl <= 0 {
            throw Abort(.badRequest, reason: "'ttlSeconds' must be positive")
        }

        // CPU template (issue #428): admission-validated against the known
        // static templates; the agent's Firecracker still rejects templates
        // its host cannot honour. A fork inherits the snapshot's recorded
        // template — the checkpointed guest state is already baked with it.
        let cpuTemplate: String?
        if let requested = createRequest.cpuTemplate?.trimmingCharacters(in: .whitespacesAndNewlines),
            !requested.isEmpty
        {
            let normalized = requested.uppercased()
            guard SandboxCPUTemplate.known.contains(normalized) else {
                throw Abort(
                    .badRequest,
                    reason:
                        "Unknown cpuTemplate '\(requested)'. Known templates: \(SandboxCPUTemplate.known.sorted().joined(separator: ", "))"
                )
            }
            cpuTemplate = normalized
        } else {
            cpuTemplate = restoreSnapshot?.cpuTemplate
        }

        let sandbox = Sandbox(
            name: requestedName,
            projectID: projectId,
            environment: environment,
            image: imageRef,
            cpus: cpus,
            memory: memory,
            entrypoint: restoreSource?.entrypoint ?? createRequest.entrypoint,
            cmd: restoreSource?.cmd ?? createRequest.cmd,
            env: restoreSource?.env ?? createRequest.env ?? [:],
            workingDir: restoreSource?.workingDir ?? createRequest.workingDir,
            ttlSeconds: createRequest.ttlSeconds,
            restoredFromSnapshotId: restoreSnapshot?.id,
            cpuTemplate: cpuTemplate
        )
        sandbox.imageDigest = restoreSource?.imageDigest

        let userID = try user.requireID()
        let restoreSnapshotID = restoreSnapshot?.id
        let initialDesiredStatus: DesiredSandboxStatus =
            restoreSnapshot == nil ? .stopped : .running

        // Quota admission check, the sandbox insert, its NIC + address rows, the
        // initial desired-state bump, and the create's attribution event commit
        // (or roll back) as one transaction, mirroring VM creation. Sandboxes
        // draw from the same vCPU/memory pools as VMs, count against the sandbox
        // count limit, and reserve no storage (issue #415).
        //
        // IPAM serializes concurrent allocations with a per-network advisory
        // lock (a VM-vs-sandbox race lands in different tables, which no
        // unique index can span); each table's unique (network, address)
        // index still backstops same-table races (issue #416). A violation
        // poisons the whole Postgres transaction, so the retry wraps the
        // transaction: the loser re-reads the used set and allocates the
        // next free address.
        let accepted: ResourceMutation.Accepted
        do {
            let initialGeneration = sandbox.generation
            accepted = try await VMController.retryingOnConstraintFailure {
                // A retried attempt reuses this model after its insert was
                // rolled back: reset the id/exists/generation so every attempt
                // starts as a fresh insert (see the VM create path).
                sandbox.id = nil
                sandbox.$id.exists = false
                sandbox.generation = initialGeneration
                return try await req.db.transaction { db -> ResourceMutation.Accepted in
                    if let restoreSnapshotID {
                        try await Self.requireSnapshotAvailableForFork(
                            restoreSnapshotID, on: db)
                    }
                    try await QuotaEnforcementService.reserveSandbox(
                        for: project,
                        environment: environment,
                        vcpus: sandbox.cpus,
                        memory: sandbox.memory,
                        on: db
                    )

                    try await sandbox.save(on: db)
                    let sandboxID = try sandbox.requireID()

                    // A cold create starts stopped. A fork resumes the captured
                    // guest during create and must be desired-running so the
                    // reconciler does not immediately pause it again.
                    // The bump to generation 1 distinguishes "never confirmed by
                    // any agent" (observed_generation 0) from "confirmed".
                    sandbox.setDesiredStatus(initialDesiredStatus)
                    // How long the create has to converge before the
                    // stuck-convergence sweep marks the sandbox degraded
                    // (STR-147), stamped with the insert for the reason the VM
                    // create path stamps its own.
                    sandbox.extendConvergenceDeadline(
                        by: OperationResourceKind.sandbox.completionBudgetSeconds(for: .create))
                    try await sandbox.update(on: db)

                    // One NIC on the requested logical network, IPAM-allocated by
                    // the control plane (issue #416); no NIC when the caller
                    // named no network (issue #765).
                    try await Self.attachNIC(
                        to: sandboxID,
                        projectID: projectId,
                        requestedNetworkID: createRequest.networkId,
                        requestedNetworkName: createRequest.networkName,
                        securityGroupIDs: requestedSecurityGroupIds,
                        on: db
                    )

                    // The create's attribution record and the client's handle on
                    // the agent work that follows (ADR 0001 stage 4), for the
                    // reason the VM create path appends its own: the retrying
                    // transaction owns this insert, not
                    // `ResourceMutation.accept`. Scope passed, not resolved,
                    // for the same reason it is there.
                    let event = try await ResourceEvent.record(
                        .create, resourceKind: .sandbox, resourceID: sandboxID,
                        actor: .user(userID),
                        scope: ResourceEvent.Scope(
                            organizationID: try await project.getRootOrganizationId(on: db),
                            projectID: projectId,
                            resourceName: sandbox.name,
                            generation: sandbox.generation),
                        on: db)

                    // IAM dual-write (issue #477): the creator's binding on the
                    // sandbox, in the create transaction (see the VM path).
                    try await RoleBindingService.grant(
                        principalType: .user,
                        principalID: userID,
                        role: .admin,
                        nodeType: .sandbox,
                        nodeID: sandboxID,
                        createdBy: userID,
                        on: db
                    )

                    return ResourceMutation.Accepted(
                        mutationID: try event.requireID(), targetGeneration: sandbox.generation)
                }
            }
        } catch let error as IPAMService.IPAMError {
            // The default network's subnet is full; the whole transaction rolled
            // back, so no sandbox was created.
            throw Abort(.conflict, reason: error.errorDescription ?? "No free IP addresses in the network")
        }

        let sandboxID = try sandbox.requireID()

        // Place the sandbox in the background: the scheduler selects a
        // Firecracker-capable agent and persists hypervisorId, and the
        // desired-state sync carries the sandbox to its agent. Observed-state
        // reports — not this request — decide whether it converged.
        req.resourceMutation.dispatch(
            .create, resourceType: Sandbox.self, resourceID: sandboxID, hypervisorId: nil,
            strategy: .placement { @Sendable [app = req.application] db in
                try await app.agentService.createSandbox(sandbox: sandbox, db: db)
            }, app: req.application)

        req.logger.info(
            "Sandbox creation accepted",
            metadata: [
                "sandbox_id": .string(sandboxID.uuidString),
                "mutation_id": .string(accepted.mutationID.uuidString),
                "image": .string(imageRef),
            ])

        return try await Self.acceptedResponse(for: sandbox, accepted, on: req)
    }

    /// Allocates and persists the sandbox's single NIC (issue #416), reusing the
    /// VM NIC's MAC generation and IPAM. Must run inside the create transaction
    /// so the address is reserved before the `202` returns and before placement.
    ///
    /// A named network is resolved within the sandbox's own project, exactly as
    /// VM create resolves it (issue #765). Naming none is not an error the way
    /// it is for a VM — the sandbox is simply created **with no NIC**. Guest
    /// networking does not exist for sandboxes yet (sync assembly omits the NIC
    /// from the wire spec, see `SandboxSpecBuilder.guestNetworkingSupported`,
    /// because agents reject networked sandbox specs), so the NIC is a pure
    /// control-plane address reservation; refusing the create, or silently
    /// picking a network on the caller's behalf, would both be worse than
    /// reserving nothing.
    ///
    /// The NIC joins its security groups here too (STR-34), the project's
    /// default when the caller named none — the same ≥1-group invariant VM
    /// create establishes, so the rows are already right when sandbox guest
    /// networking lands. Conditional on a NIC existing, unlike the VM path:
    /// a network-less sandbox has nothing to attach groups to.
    private static func attachNIC(
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

        let networkInterface = SandboxNetworkInterface(
            sandboxID: sandboxID,
            logicalNetworkID: logicalNetworkID,
            macAddress: VMNetworkInterface.generateMACAddress()
        )
        try await networkInterface.save(on: db)
        let interfaceID = try networkInterface.requireID()

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
        let sandbox = try await fetchSandboxWithPermission(req: req, permission: "update")

        struct UpdateSandboxRequest: Content {
            let name: String?
            let ttlSeconds: Int?
        }

        let updateRequest = try req.content.decode(UpdateSandboxRequest.self)

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
        try await Self.loadNICSecurityGroups(sandbox, on: req.db)
        return SandboxDetailResponse(from: sandbox)
    }

    // MARK: - Lifecycle

    func start(req: Request) async throws -> Response {
        let user = try req.requireActingUser("Mutating a sandbox")
        let sandbox = try await fetchSandboxWithPermission(req: req, permission: "start")

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
        let sandbox = try await fetchSandboxWithPermission(req: req, permission: "stop")

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
        let sandbox = try await fetchSandboxWithPermission(req: req, permission: "restart")

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

        struct ExecRequest: Content {
            let command: [String]
            let env: [String: String]?
            let workingDir: String?
            let tty: Bool?
            let rows: Int?
            let cols: Int?
        }

        let execRequest = try req.content.decode(ExecRequest.self)
        guard !execRequest.command.isEmpty else {
            throw Abort(.badRequest, reason: "'command' must be a non-empty array of strings")
        }

        let sandbox = try await fetchSandboxWithPermission(req: req, permission: "exec")
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

        let agentWireVersion = agent.wireProtocolVersion ?? 0
        guard WireProtocol.supportsSandboxExec(agentWireVersion) else {
            throw Abort(
                .conflict,
                reason:
                    "Agent '\(agent.name)' is too old for sandbox exec (wire protocol \(agentWireVersion), need >= \(WireProtocol.sandboxExecMinimumVersion)). Upgrade the agent."
            )
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

        let session = req.sandboxExecSessionManager.createPendingSession(
            sandboxId: sandboxID.uuidString,
            agentKey: agent.identity.key,
            userId: try user.requireID().uuidString,
            command: execRequest.command,
            env: execRequest.env,
            workingDir: execRequest.workingDir,
            tty: execRequest.tty ?? false,
            rows: execRequest.rows,
            cols: execRequest.cols
        )

        struct ExecSessionResponse: Content {
            let sessionId: String
            let websocketPath: String
            let expiresAt: Date
        }

        let response = Response(status: .created)
        try response.content.encode(
            ExecSessionResponse(
                sessionId: session.sessionId,
                websocketPath: "/api/sandboxes/\(sandboxID.uuidString)/exec/\(session.sessionId)/attach",
                expiresAt: session.expiresAt
            ))
        return response
    }

    // MARK: - Delete

    func delete(req: Request) async throws -> Response {
        let user = try req.requireActingUser("Mutating a sandbox")
        let sandbox = try await fetchSandboxWithPermission(req: req, permission: "delete")

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
            on: req.db, app: app
        ) { @Sendable db in
            try await Self.requireSnapshotLineageDeletable(for: sandboxID, on: db)
            // Stamp before the mark — see the VM delete path for why.
            ResourceFinalizerService.stampForDeletion(sandbox)
            sandbox.setDesiredStatus(.absent)
        }
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
                metadata: ["sandbox_id": .string(sandboxID.uuidString)])
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
                    "sandbox_id": .string(sandboxID.uuidString),
                    "finalizers": .string(remaining.joined(separator: ",")),
                ])
        }
        return outcome.isRemoved
    }
}
