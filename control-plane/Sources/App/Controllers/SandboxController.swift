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

    /// Sandbox-flavored front of `ResourceOperation.begin`: creates the pending
    /// operation record and applies the sandbox's desired-state change in one
    /// transaction, rejecting with `409 Conflict` when any operation is already
    /// pending for the sandbox. Internal (not private) because the snapshot
    /// handlers in SandboxSnapshotController.swift share it.
    func beginOperation(
        _ kind: VMOperationKind,
        sandbox: Sandbox,
        user: User,
        settingDesiredStatus desiredStatus: DesiredSandboxStatus? = nil,
        on db: Database,
        preparing mutation: @escaping @Sendable (any Database) async throws -> Void = { _ in }
    ) async throws -> ResourceOperation {
        try await ResourceOperation.begin(
            kind,
            resourceKind: .sandbox,
            resourceID: sandbox.requireID(),
            userID: user.requireID(),
            on: db
        ) { db in
            try await mutation(db)
            if let desiredStatus {
                sandbox.setDesiredStatus(desiredStatus)
                try await sandbox.save(on: db)
            }
        }
    }

    /// Records an operation verdict through the shared
    /// `ResourceOperationCoordinator` and, when this path won the verdict race,
    /// stamps a caller-supplied terminal sandbox status (e.g. a restore's
    /// `.running`). The snapshot and transfer controllers drive their own
    /// bespoke agent dispatch and call this to close the operation.
    static func completeOperation(
        _ operationId: UUID,
        sandboxID: UUID,
        as status: VMOperationStatus,
        error: String?,
        settingSandboxStatus sandboxStatus: SandboxStatus?,
        app: Application
    ) async {
        let won = await app.resourceOperationCoordinator.recordVerdict(
            operationID: operationId, as: status, error: error, on: app)
        // A terminal status applies only when we won the race and Fluent is
        // still up; a lost race means the sweep already resolved the sandbox.
        guard won, let sandboxStatus, !Task.isCancelled, let db = app.liveDB else { return }
        if let sandbox = try? await Sandbox.find(sandboxID, on: db) {
            sandbox.setStatus(sandboxStatus)
            try? await sandbox.save(on: db)
        }
    }

    // MARK: - Reads

    /// GET /api/sandboxes
    /// Query params: organization_id (optional) — narrows to one org's hierarchy.
    func index(req: Request) async throws -> [SandboxDetailResponse] {
        guard req.auth.has(User.self) else {
            throw Abort(.unauthorized)
        }

        // Scoped through the sandbox's project, as in VMController.index.
        var query = Sandbox.query(on: req.db)
        if let orgFilter = try await OrganizationAccessService.organizationListFilter(on: req) {
            let projectIDs = try await orgFilter.projectIDs(on: req.db)
            if projectIDs.isEmpty { return [] }
            query = query.filter(\.$project.$id ~~ projectIDs)
        }

        let allSandboxes = try await query.all()
        var authorized: [SandboxDetailResponse] = []

        for sandbox in allSandboxes {
            let hasPermission = try await req.can("read", on: "sandbox", id: sandbox.id?.uuidString ?? "")
            if hasPermission {
                authorized.append(SandboxDetailResponse(from: sandbox))
            }
        }

        return authorized
    }

    /// Fetch a sandbox by its :sandboxID route parameter and enforce a
    /// permission on it (per-handler defense in depth over the middleware).
    func fetchSandboxWithPermission(req: Request, permission: String) async throws -> Sandbox {
        guard let sandboxID = req.parameters.get("sandboxID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid sandbox ID")
        }

        return try await req.authorizedSandbox(sandboxID, permission: permission)
    }

    func show(req: Request) async throws -> SandboxDetailResponse {
        _ = try req.auth.require(User.self)
        let sandbox = try await fetchSandboxWithPermission(req: req, permission: "read")
        return SandboxDetailResponse(from: sandbox)
    }

    func status(req: Request) async throws -> SandboxDetailResponse {
        _ = try req.auth.require(User.self)
        let sandbox = try await fetchSandboxWithPermission(req: req, permission: "read")

        // The database row *is* the observed state: the owning agent's
        // periodic observed-state reports keep it fresh, so no agent
        // round-trip happens here (replica-independent, like VMs).
        return SandboxDetailResponse(from: sandbox)
    }

    func listOperations(req: Request) async throws -> [OperationResponse] {
        _ = try req.auth.require(User.self)
        let sandbox = try await fetchSandboxWithPermission(req: req, permission: "read")
        let sandboxID = try sandbox.requireID()

        let requestedLimit: Int = req.query["limit"] ?? 20
        let limit = min(max(requestedLimit, 1), 100)

        let operations = try await ResourceOperation.query(on: req.db)
            .filter(\.$resourceKind == .sandbox)
            .filter(\.$resourceID == sandboxID)
            .sort(\.$createdAt, .descending)
            .limit(limit)
            .all()

        return operations.map { OperationResponse(from: $0) }
    }

    // MARK: - Create

    func create(req: Request) async throws -> Response {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

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

        // Resolve the project context, mirroring VM creation: an explicit
        // project must belong to the caller's current organization; otherwise
        // fall back to the organization's default project.
        let projectId: UUID
        if let requestedProjectId = createRequest.projectId {
            guard let project = try await Project.find(requestedProjectId, on: req.db) else {
                throw Abort(.badRequest, reason: "Project not found")
            }

            let rootOrgId = try await project.getRootOrganizationId(on: req.db)
            guard let orgId = rootOrgId, user.currentOrganizationId == orgId else {
                throw Abort(.forbidden, reason: "Access denied to project")
            }

            projectId = requestedProjectId
        } else {
            guard let currentOrgId = user.currentOrganizationId else {
                throw Abort(.badRequest, reason: "No current organization set. Please specify a project.")
            }

            let defaultProject = try await Project.query(on: req.db)
                .filter(\Project.$organization.$id, .equal, currentOrgId)
                .filter(\Project.$name, .equal, "Default Project")
                .first()

            guard let project = defaultProject else {
                throw Abort(.badRequest, reason: "No default project found. Please specify a project.")
            }
            projectId = project.id!
        }

        guard let project = try await Project.find(projectId, on: req.db) else {
            throw Abort(.internalServerError, reason: "Project not found")
        }

        // Require create permission on the target project. Org membership
        // alone is not enough: `sandbox.create` resolves to
        // `project->create_resources`, same as VMs.
        let canCreate = try await req.can("create_resources", on: "project", id: projectId.uuidString)
        guard canCreate else {
            throw Abort(.forbidden, reason: "You don't have permission to create sandboxes in this project")
        }

        let environment = createRequest.environment ?? project.defaultEnvironment
        if !project.hasEnvironment(environment) {
            throw Abort(
                .badRequest,
                reason:
                    "Environment '\(environment)' not available in project. Available: \(project.environments.joined(separator: ", "))"
            )
        }

        let imageRef =
            restoreSource?.image
            ?? (createRequest.image ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cpus = restoreSource?.cpus ?? createRequest.cpus ?? 1
        let memory = restoreSource?.memory ?? createRequest.memory ?? Int64(1024 * 1024 * 1024)
        guard cpus > 0 else {
            throw Abort(.badRequest, reason: "'cpus' must be positive")
        }
        guard memory > 0 else {
            throw Abort(.badRequest, reason: "'memory' must be positive")
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
        // initial desired-state bump, and the pending create operation commit
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
        let operation: ResourceOperation
        do {
            let initialGeneration = sandbox.generation
            operation = try await VMController.retryingOnConstraintFailure {
                // A retried attempt reuses this model after its insert was
                // rolled back: reset the id/exists/generation so every attempt
                // starts as a fresh insert (see the VM create path).
                sandbox.id = nil
                sandbox.$id.exists = false
                sandbox.generation = initialGeneration
                return try await req.db.transaction { db -> ResourceOperation in
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
                    try await sandbox.update(on: db)

                    // One NIC on the default logical network, IPAM-allocated by
                    // the control plane (issue #416). A missing default-network
                    // row (pre-migration data) degrades to an address-less NIC,
                    // matching the VM implicit-default path.
                    try await Self.attachDefaultNIC(to: sandboxID, on: db)

                    let operation = ResourceOperation(
                        sandboxID: sandboxID, userID: userID, kind: .create)
                    try await operation.save(on: db)

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

                    return operation
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
        // reports — not this request — decide the operation's verdict.
        req.resourceOperationCoordinator.dispatch(
            operation, resourceKind: .sandbox, resourceID: sandboxID, hypervisorId: nil,
            dispatch: .placement { @Sendable [app = req.application] db in
                try await app.agentService.createSandbox(sandbox: sandbox, db: db)
            }, app: req.application)

        req.logger.info(
            "Sandbox creation accepted",
            metadata: [
                "sandbox_id": .string(sandboxID.uuidString),
                "operation_id": .string(operation.id?.uuidString ?? ""),
                "image": .string(imageRef),
            ])

        return try operation.acceptedResponse()
    }

    /// Allocates and persists the sandbox's single NIC on the default logical
    /// network (issue #416), reusing the VM NIC's MAC generation and IPAM. Must
    /// run inside the create transaction so the address is reserved before the
    /// `202` returns and before placement. A missing default-network row
    /// degrades to an address-less NIC (matching the VM implicit-default
    /// behavior on pre-migration data); the NIC row itself is always created so
    /// the sandbox has a stable device name to attach. Until guest networking
    /// lands the NIC is a control-plane-side reservation only — sync assembly
    /// deliberately omits it from the wire spec (see
    /// `SandboxSpecBuilder.guestNetworkingSupported`), because agents reject
    /// networked sandbox specs.
    private static func attachDefaultNIC(to sandboxID: UUID, on db: Database) async throws {
        let networkName = LogicalNetwork.defaultNetworkName

        var allocation: IPAMService.Allocation?
        var allocation6: IPAMService.Allocation6?
        var networkGateway: String?
        var networkGateway6: String?
        if let logicalNetwork = try await LogicalNetwork.query(on: db)
            .filter(\.$name == networkName)
            .first()
        {
            allocation = try await IPAMService.allocateIP(for: logicalNetwork, on: db)
            networkGateway = logicalNetwork.gateway
            // Dual-stack network: the NIC gets one address per family.
            allocation6 = try await IPAMService.allocateIPv6(for: logicalNetwork, on: db)
            networkGateway6 = logicalNetwork.gateway6
        }

        let networkInterface = SandboxNetworkInterface(
            sandboxID: sandboxID,
            network: networkName,
            macAddress: VMNetworkInterface.generateMACAddress()
        )
        try await networkInterface.save(on: db)
        let interfaceID = try networkInterface.requireID()

        if let allocation {
            let address = SandboxInterfaceAddress(
                interfaceID: interfaceID,
                network: networkName,
                family: .ipv4,
                address: allocation.ipAddress,
                prefixLength: allocation.prefixLength,
                gateway: networkGateway
            )
            try await address.save(on: db)
        }
        if let allocation6 {
            let address6 = SandboxInterfaceAddress(
                interfaceID: interfaceID,
                network: networkName,
                family: .ipv6,
                address: allocation6.ipAddress,
                prefixLength: allocation6.prefixLength,
                gateway: networkGateway6
            )
            try await address6.save(on: db)
        }
    }

    // MARK: - Update

    func update(req: Request) async throws -> SandboxDetailResponse {
        _ = try req.auth.require(User.self)
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
        return SandboxDetailResponse(from: sandbox)
    }

    // MARK: - Lifecycle

    func start(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let sandbox = try await fetchSandboxWithPermission(req: req, permission: "start")

        guard sandbox.canStart else {
            throw Abort(
                .badRequest, reason: "Sandbox cannot be started in current state: \(sandbox.status.rawValue)")
        }

        let sandboxID = try sandbox.requireID()
        let userID = try user.requireID()
        let operation = try await req.resourceOperationCoordinator.perform(
            .boot, resourceKind: .sandbox, resourceID: sandboxID, userID: userID,
            hypervisorId: sandbox.hypervisorId, dispatch: .stateSync, on: req.db, app: req.application
        ) { @Sendable db in
            sandbox.setDesiredStatus(.running)
            try await sandbox.save(on: db)
        }

        return try operation.acceptedResponse()
    }

    func stop(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let sandbox = try await fetchSandboxWithPermission(req: req, permission: "stop")

        guard sandbox.canStop else {
            throw Abort(
                .badRequest, reason: "Sandbox cannot be stopped in current state: \(sandbox.status.rawValue)")
        }

        let sandboxID = try sandbox.requireID()
        let userID = try user.requireID()
        let operation = try await req.resourceOperationCoordinator.perform(
            .shutdown, resourceKind: .sandbox, resourceID: sandboxID, userID: userID,
            hypervisorId: sandbox.hypervisorId, dispatch: .stateSync, on: req.db, app: req.application
        ) { @Sendable db in
            sandbox.setDesiredStatus(.stopped)
            try await sandbox.save(on: db)
        }

        return try operation.acceptedResponse()
    }

    func restart(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let sandbox = try await fetchSandboxWithPermission(req: req, permission: "restart")

        guard sandbox.isRunning else {
            throw Abort(
                .badRequest,
                reason: "Sandbox must be running to restart. Current state: \(sandbox.status.rawValue)")
        }

        // Restart is expressed as a fresh desired-running generation: the
        // generation bump is what obliges the agent to act (there is no
        // imperative sandbox reboot message on the wire). The agent-side
        // interpretation lands with the sandbox runtime (issue #421); until
        // an agent acknowledges the new generation the operation stays
        // pending and the sweep budget backstops it.
        let sandboxID = try sandbox.requireID()
        let userID = try user.requireID()
        let operation = try await req.resourceOperationCoordinator.perform(
            .reboot, resourceKind: .sandbox, resourceID: sandboxID, userID: userID,
            hypervisorId: sandbox.hypervisorId, dispatch: .stateSync, on: req.db, app: req.application
        ) { @Sendable db in
            sandbox.setDesiredStatus(.running)
            try await sandbox.save(on: db)
        }

        return try operation.acceptedResponse()
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
        let user = try req.auth.require(User.self)

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
        let user = try req.auth.require(User.self)
        let sandbox = try await fetchSandboxWithPermission(req: req, permission: "delete")

        // Deletion via state sync, exactly like VMs: desired becomes
        // `.absent`, the agent tears the sandbox down on its next sync, and
        // the row is removed only once a report confirms absence. Unplaced
        // sandboxes and offline agents keep a direct database path.
        let sandboxID = try sandbox.requireID()
        let userID = try user.requireID()
        let app = req.application
        let agentOnline: Bool
        if let hypervisorId = sandbox.hypervisorId {
            agentOnline = await app.agentService.agentIsOnline(agentId: hypervisorId)
        } else {
            agentOnline = false
        }

        let strategy: ResourceOperationCoordinator.Strategy =
            agentOnline
            ? .stateSync
            : .directResolution { @Sendable db in
                try await Self.performDirectDeletion(sandbox: sandbox, on: db, app: app)
            }

        let operation = try await req.resourceOperationCoordinator.perform(
            .delete, resourceKind: .sandbox, resourceID: sandboxID, userID: userID,
            hypervisorId: sandbox.hypervisorId, dispatch: strategy, on: req.db, app: app
        ) { @Sendable db in
            try await Self.requireSnapshotLineageDeletable(for: sandboxID, on: db)
            sandbox.setDesiredStatus(.absent)
            try await sandbox.save(on: db)
        }
        return try operation.acceptedResponse()
    }

    /// The direct-removal work for a sandbox whose agent is gone (never placed,
    /// or offline cluster-wide) or that is being expired: clean up exported
    /// snapshot objects, then remove the record and release its quota in one
    /// transaction. Wrapped by the coordinator's `.directResolution` dispatch,
    /// which supplies the still-pending guard and records the verdict. If the
    /// agent ever comes back still carrying the sandbox, its observed-state
    /// report surfaces it for operator attention.
    ///
    /// Internal rather than private because the expiry sweep (issue #424)
    /// deletes down this same path, so a TTL-driven deletion releases quota
    /// exactly like a user-initiated one.
    static func performDirectDeletion(sandbox: Sandbox, on db: any Database, app: Application) async throws {
        let sandboxID = try sandbox.requireID()
        if sandbox.hypervisorId != nil {
            app.logger.warning(
                "Deleting sandbox record without agent teardown; agent is offline",
                metadata: ["sandbox_id": .string(sandboxID.uuidString)])
        }

        // Exported snapshot objects first: the snapshot rows cascade with the
        // sandbox row below (issue #428).
        await Self.cleanUpExportedSnapshotObjects(for: sandboxID, app: app)

        guard !Task.isCancelled else { return }
        do {
            try await db.transaction { db in
                try await sandbox.delete(on: db)
                try await QuotaEnforcementService.release(for: sandbox, on: db)
            }
        } catch {
            throw ResourceOperationCoordinator.WorkError(
                "Failed to delete sandbox record: \(error.localizedDescription)")
        }
    }
}
