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
        on db: Database
    ) async throws -> ResourceOperation {
        try await ResourceOperation.begin(
            kind,
            resourceKind: .sandbox,
            resourceID: sandbox.requireID(),
            userID: user.requireID(),
            on: db
        ) { db in
            if let desiredStatus {
                sandbox.setDesiredStatus(desiredStatus)
                try await sandbox.save(on: db)
            }
        }
    }

    /// Whether the sandbox's owning agent is online somewhere in the cluster.
    /// False for unplaced sandboxes.
    static func agentIsOnline(sandbox: Sandbox, app: Application) async -> Bool {
        guard let agentId = sandbox.hypervisorId else { return false }
        guard let agent = await app.agentService.getAgentInfo(agentId) else { return false }
        return agent.status == .online
    }

    /// Push the freshly written desired state to the sandbox's agent, exactly
    /// like the VM path: directly when this replica holds its socket, via a
    /// pub/sub nudge otherwise, with the periodic sync timer as the backstop.
    /// A sandbox with no agent — or an offline one — has nowhere to converge:
    /// fail the operation immediately instead of waiting out the sweep budget.
    private static func dispatchStateSync(_ operation: ResourceOperation, sandbox: Sandbox, app: Application) {
        guard let operationId = operation.id else { return }
        let sandboxID = operation.resourceID

        guard let agentId = sandbox.hypervisorId else {
            app.backgroundTasks.spawn {
                await completeOperation(
                    operationId, sandboxID: sandboxID, as: .failed,
                    error: "Sandbox \(sandboxID.uuidString) is not placed on any agent",
                    settingSandboxStatus: nil, app: app)
            }
            return
        }
        app.backgroundTasks.spawn {
            guard let agent = await app.agentService.getAgentInfo(agentId), agent.status == .online else {
                await completeOperation(
                    operationId, sandboxID: sandboxID, as: .failed,
                    error: "Agent \(agentId) is offline; the sandbox cannot converge to the requested state",
                    settingSandboxStatus: nil, app: app)
                return
            }
            await app.agentService.syncDesiredState(agentId: agentId)
        }
    }

    /// `202 Accepted` carrying the operation record for the client to poll.
    static func accepted(_ operation: ResourceOperation) throws -> Response {
        let response = Response(status: .accepted)
        try response.content.encode(OperationResponse(from: operation))
        return response
    }

    /// Records a verdict on the operation row and resolves the sandbox status
    /// it left in flight. Gated on the operation still being pending, so this
    /// path and the stuck-operation sweep cannot overwrite each other.
    static func completeOperation(
        _ operationId: UUID,
        sandboxID: UUID,
        as status: VMOperationStatus,
        error: String?,
        settingSandboxStatus sandboxStatus: SandboxStatus?,
        app: Application
    ) async {
        do {
            guard let operation = try await ResourceOperation.find(operationId, on: app.db),
                try await operation.completeIfPending(as: status, error: error, on: app.db)
            else { return }

            if status == .failed {
                app.logger.warning(
                    "Sandbox operation failed",
                    metadata: [
                        "operationId": .string(operationId.uuidString),
                        "sandboxId": .string(sandboxID.uuidString),
                        "kind": .string(operation.kind.rawValue),
                        "error": .string(error ?? "unknown"),
                    ])
            }

            if let sandbox = try await Sandbox.find(sandboxID, on: app.db) {
                var changed = false
                if let sandboxStatus {
                    sandbox.setStatus(sandboxStatus)
                    changed = true
                }
                // A failed operation's intent was not achieved and the user
                // has been told — realign desired state with observed reality
                // so the divergence doesn't replay later.
                if status == .failed, sandbox.revertDesiredToObserved() {
                    changed = true
                }
                if changed {
                    try await sandbox.save(on: app.db)
                }
            }
        } catch {
            app.logger.error(
                "Failed to record sandbox operation completion: \(error)",
                metadata: ["operationId": .string(operationId.uuidString)])
        }
    }

    // MARK: - Reads

    /// GET /api/sandboxes
    /// Query params: organization_id (optional) — narrows to one org's hierarchy.
    func index(req: Request) async throws -> [SandboxDetailResponse] {
        guard let user = req.auth.get(User.self) else {
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
            let hasPermission = try await req.spicedb.checkPermission(
                subject: user.id?.uuidString ?? "",
                permission: "read",
                resource: "sandbox",
                resourceId: sandbox.id?.uuidString ?? ""
            )
            if hasPermission {
                authorized.append(SandboxDetailResponse(from: sandbox))
            }
        }

        return authorized
    }

    /// Fetch a sandbox by its :sandboxID route parameter and enforce a SpiceDB
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
            let image: String
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
        }

        let createRequest = try req.content.decode(CreateSandboxRequest.self)

        let imageRef = createRequest.image.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !imageRef.isEmpty else {
            throw Abort(.badRequest, reason: "'image' must be a non-empty OCI image reference")
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
        let canCreate = try await req.spicedb.checkPermission(
            subject: user.id?.uuidString ?? "",
            permission: "create_resources",
            resource: "project",
            resourceId: projectId.uuidString
        )
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

        let cpus = createRequest.cpus ?? 1
        let memory = createRequest.memory ?? Int64(1024 * 1024 * 1024)
        guard cpus > 0 else {
            throw Abort(.badRequest, reason: "'cpus' must be positive")
        }
        guard memory > 0 else {
            throw Abort(.badRequest, reason: "'memory' must be positive")
        }
        if let ttl = createRequest.ttlSeconds, ttl <= 0 {
            throw Abort(.badRequest, reason: "'ttlSeconds' must be positive")
        }

        let sandbox = Sandbox(
            name: createRequest.name,
            projectID: projectId,
            environment: environment,
            image: imageRef,
            cpus: cpus,
            memory: memory,
            entrypoint: createRequest.entrypoint,
            cmd: createRequest.cmd,
            env: createRequest.env ?? [:],
            workingDir: createRequest.workingDir,
            ttlSeconds: createRequest.ttlSeconds
        )

        let userID = try user.requireID()

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
                    try await QuotaEnforcementService.reserveSandbox(
                        for: project,
                        environment: environment,
                        vcpus: sandbox.cpus,
                        memory: sandbox.memory,
                        on: db
                    )

                    try await sandbox.save(on: db)
                    let sandboxID = try sandbox.requireID()

                    // Desired state for a fresh sandbox: exists but not running.
                    // The bump to generation 1 distinguishes "never confirmed by
                    // any agent" (observed_generation 0) from "confirmed".
                    sandbox.setDesiredStatus(.stopped)
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

        // Ownership relationships in SpiceDB, mirroring VMs: owner (creator)
        // and project (org/OU admins reach the sandbox transitively via
        // sandbox#project → project#parent).
        try await req.spicedb.writeRelationship(
            entity: "sandbox",
            entityId: sandboxID.uuidString,
            relation: "owner",
            subject: "user",
            subjectId: userID.uuidString
        )
        try await req.spicedb.writeRelationship(
            entity: "sandbox",
            entityId: sandboxID.uuidString,
            relation: "project",
            subject: "project",
            subjectId: projectId.uuidString
        )

        // Place the sandbox in the background: the scheduler selects a
        // Firecracker-capable agent and persists hypervisorId, and the
        // desired-state sync carries the sandbox to its agent. Observed-state
        // reports — not this request — decide the operation's verdict.
        Self.runSandboxCreation(operation, sandbox: sandbox, app: req.application)

        req.logger.info(
            "Sandbox creation accepted",
            metadata: [
                "sandbox_id": .string(sandboxID.uuidString),
                "operation_id": .string(operation.id?.uuidString ?? ""),
                "image": .string(imageRef),
            ])

        return try Self.accepted(operation)
    }

    /// Allocates and persists the sandbox's single NIC on the default logical
    /// network (issue #416), reusing the VM NIC's MAC generation and IPAM. Must
    /// run inside the create transaction so the address is reserved before the
    /// `202` returns and before placement. A missing default-network row
    /// degrades to an address-less NIC (matching the VM implicit-default
    /// behavior on pre-migration data); the NIC row itself is always created so
    /// the sandbox has a stable device name to attach.
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

    /// Background half of `create`: scheduling and the placement write happen
    /// here, after the `202` went out. A failure — no schedulable agent,
    /// placement write error — lands on the operation record and marks the
    /// sandbox `.error` so it never poses as healthy with no backing.
    private static func runSandboxCreation(
        _ operation: ResourceOperation,
        sandbox: Sandbox,
        app: Application
    ) {
        guard let operationId = operation.id else { return }
        let sandboxID = operation.resourceID

        app.backgroundTasks.spawn {
            do {
                try await app.agentService.createSandbox(sandbox: sandbox, db: app.db)
            } catch {
                await completeOperation(
                    operationId, sandboxID: sandboxID, as: .failed, error: error.localizedDescription,
                    settingSandboxStatus: .error, app: app)
            }
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

        let operation = try await beginOperation(
            .boot, sandbox: sandbox, user: user,
            settingDesiredStatus: .running,
            on: req.db)

        Self.dispatchStateSync(operation, sandbox: sandbox, app: req.application)

        return try Self.accepted(operation)
    }

    func stop(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let sandbox = try await fetchSandboxWithPermission(req: req, permission: "stop")

        guard sandbox.canStop else {
            throw Abort(
                .badRequest, reason: "Sandbox cannot be stopped in current state: \(sandbox.status.rawValue)")
        }

        let operation = try await beginOperation(
            .shutdown, sandbox: sandbox, user: user,
            settingDesiredStatus: .stopped,
            on: req.db)

        Self.dispatchStateSync(operation, sandbox: sandbox, app: req.application)

        return try Self.accepted(operation)
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
        let operation = try await beginOperation(
            .reboot, sandbox: sandbox, user: user,
            settingDesiredStatus: .running,
            on: req.db)

        Self.dispatchStateSync(operation, sandbox: sandbox, app: req.application)

        return try Self.accepted(operation)
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
        guard req.application.websocketManager.getConnection(agentName: agent.name) != nil else {
            throw Abort(
                .serviceUnavailable,
                reason:
                    "Agent '\(agent.name)' is not connected to this control-plane replica; exec requires the replica holding the agent socket"
            )
        }

        let session = req.sandboxExecSessionManager.createPendingSession(
            sandboxId: sandboxID.uuidString,
            agentName: agent.name,
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
        let agentOnline = await Self.agentIsOnline(sandbox: sandbox, app: req.application)
        let operation = try await beginOperation(
            .delete, sandbox: sandbox, user: user, settingDesiredStatus: .absent, on: req.db)

        if agentOnline {
            Self.dispatchStateSync(operation, sandbox: sandbox, app: req.application)
        } else {
            Self.runDirectSandboxDeletion(operation, sandbox: sandbox, app: req.application)
        }
        return try Self.accepted(operation)
    }

    /// Background half of `delete` for sandboxes whose agent is gone (never
    /// placed, or offline cluster-wide): remove the record directly without
    /// agent teardown. If the agent ever comes back still carrying the
    /// sandbox, its observed-state report surfaces it for operator attention.
    ///
    /// Internal rather than private because the expiry sweep (issue #424)
    /// deletes down this same path, so a TTL-driven deletion releases quota
    /// exactly like a user-initiated one.
    static func runDirectSandboxDeletion(
        _ operation: ResourceOperation, sandbox: Sandbox, app: Application
    ) {
        guard let operationId = operation.id else { return }
        let sandboxID = operation.resourceID

        app.backgroundTasks.spawn {
            if sandbox.hypervisorId != nil {
                app.logger.warning(
                    "Deleting sandbox record without agent teardown; agent is offline",
                    metadata: ["sandbox_id": .string(sandboxID.uuidString)])
            }

            do {
                // If the sweep already failed this operation, stop here:
                // removing the row under a failed operation would contradict it.
                guard let current = try await ResourceOperation.find(operationId, on: app.db),
                    current.status == .pending
                else { return }

                try await app.db.transaction { db in
                    try await sandbox.delete(on: db)
                    try await QuotaEnforcementService.release(for: sandbox, on: db)
                }
                await completeOperation(
                    operationId, sandboxID: sandboxID, as: .succeeded, error: nil,
                    settingSandboxStatus: nil, app: app)
            } catch {
                await completeOperation(
                    operationId, sandboxID: sandboxID, as: .failed,
                    error: "Failed to delete sandbox record: \(error.localizedDescription)",
                    settingSandboxStatus: nil, app: app)
            }
        }
    }
}
