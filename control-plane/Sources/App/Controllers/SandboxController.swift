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
        return try AcceptedMutation(await detailResponse(for: sandbox, on: req.db), accepted).acceptedResponse()
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
        let enforcedBySandbox = try await SecurityGroupService.enforcementBySandbox(visible, on: req.db)
        return visible.map { sandbox in
            SandboxDetailResponse(
                from: sandbox,
                securityGroupsEnforced: sandbox.id.flatMap { enforcedBySandbox[$0] })
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
    private static func detailResponse(for sandbox: Sandbox, on db: Database) async throws
        -> SandboxDetailResponse
    {
        try await loadNICDetail(sandbox, on: db)
        return SandboxDetailResponse(
            from: sandbox,
            securityGroupsEnforced: try await SecurityGroupService.sandboxEnforcement(for: sandbox, on: db))
    }

    func show(req: Request) async throws -> SandboxDetailResponse {
        _ = try req.requireActingPrincipal()
        let sandbox = try await fetchSandboxWithPermission(req: req, permission: "read")
        return try await Self.detailResponse(for: sandbox, on: req.db)
    }

    func status(req: Request) async throws -> SandboxDetailResponse {
        _ = try req.requireActingPrincipal()
        let sandbox = try await fetchSandboxWithPermission(req: req, permission: "read")

        // The database row *is* the observed state: the owning agent's
        // periodic observed-state reports keep it fresh, so no agent
        // round-trip happens here (replica-independent, like VMs).
        return try await Self.detailResponse(for: sandbox, on: req.db)
    }

    func listOperations(req: Request) async throws -> [OperationResponse] {
        let sandbox = try await fetchSandboxWithPermission(req: req, permission: "read")
        let sandboxID = try sandbox.requireID()

        let limit = try req.intQuery("limit", default: 20, in: 1...100)

        return try await OperationFacade.history(
            resourceKind: .sandbox, resourceID: sandboxID, limit: limit, on: req.db)
    }

    // MARK: - Create

    func create(req: Request) async throws -> Response {
        let user = try req.requireActingUser("Creating a sandbox")

        struct CreateSandboxRequest: Content, ValidatedRequestBody {
            var name: String
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
            /// both means no NIC, and a NIC is still a control-plane address
            /// reservation only until STR-103 (see `attachNIC`).
            let networkId: UUID?
            let networkName: String?
            /// Security groups for the sandbox's NIC (STR-34, STR-102).
            /// Omitted means the project's default group — never "no groups".
            /// Only meaningful alongside a network, since without one there is
            /// no NIC to attach them to.
            let securityGroupIds: [UUID]?

            mutating func validate() throws {
                name = try Validate.name(name)
                try Validate.text(image, "image", max: Self.maxImageReferenceLength)
                try Validate.text(cpuTemplate, "cpuTemplate", max: Validate.nameLength)
                try Validate.text(workingDir, "workingDir")
                // The process fields ride the desired-state sync to the agent
                // and become the guest's argv and environment, so they get the
                // same treatment as the names — bounded in cardinality *and*
                // per element, since either dimension alone leaves the total
                // open-ended.
                try Validate.stringList(entrypoint, "entrypoint", maxEntries: Self.maxProcessArguments)
                try Validate.stringList(cmd, "cmd", maxEntries: Self.maxProcessArguments)
                try Validate.stringMap(env, "env", maxEntries: Self.maxEnvironmentVariables)
                try validateProcessConfigurationSize()
                try Validate.list(securityGroupIds, "securityGroupIds", max: SecurityGroup.maxGroupsPerNIC)
            }

            /// Bounds the process fields *together*, not just individually.
            ///
            /// Per-element and per-count ceilings alone leave the product
            /// unbounded: 256 arguments of 4096 characters is a megabyte, and so
            /// is the environment beside it. That matters more here than at any
            /// other create site, because unlike a name this payload is not
            /// written once and read on demand — it rides `DesiredStateMessage`
            /// to the agent on every reconcile, for the life of the sandbox.
            private func validateProcessConfigurationSize() throws {
                func length(of strings: [String]) -> Int {
                    strings.reduce(into: 0) { $0 += Validate.length($1) }
                }
                var total = length(of: entrypoint ?? [])
                total += length(of: cmd ?? [])
                for (key, value) in env ?? [:] {
                    total += Validate.length(key) + Validate.length(value)
                }
                guard total <= Self.maxProcessConfigurationLength else {
                    throw Abort(
                        .badRequest,
                        reason: "'entrypoint', 'cmd' and 'env' must total "
                            + "\(Self.maxProcessConfigurationLength) characters or fewer")
                }
            }

            /// An OCI reference is bounded by its own spec well below this —
            /// 255 for a repository path, 128 for a tag, plus a registry host
            /// and an optional digest — so this refuses only what no registry
            /// could resolve anyway.
            static let maxImageReferenceLength = 512

            /// Generous enough that no real entrypoint or environment hits
            /// them, small enough that one create cannot hand an agent an
            /// unbounded argv.
            static let maxProcessArguments = 256
            static let maxEnvironmentVariables = 256

            /// Combined ceiling on the process configuration. 64 KiB is far
            /// past any real container's argv and environment and far under the
            /// 1 MiB request body, so the field bound — not the transport — is
            /// what decides.
            static let maxProcessConfigurationLength = 64 * 1024
        }

        let createRequest = try req.content.decodeValidated(CreateSandboxRequest.self)
        let requestedName = createRequest.name

        var restoreSnapshot: SandboxSnapshot?
        var restoreSource: Sandbox?
        /// The logical network the checkpointed sandbox's NIC sits on, when it
        /// had one. A fork inherits it (see the shape gate below).
        var restoreSourceNetworkID: UUID?
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
            // The fork's NIC shape has to match the checkpoint's (STR-104). A
            // snapshot load can repoint a network device at a different host
            // TAP but can neither add nor drop one, so a fork that disagrees
            // with its source about having a NIC is unbootable — and the
            // agent, which can prove the checkpoint's device set from the
            // archived config drive, refuses it permanently.
            //
            // Which makes the NIC part of the shape a fork *inherits*, exactly
            // like its image and vCPU/memory: naming no network gets the
            // source's, rather than dropping a device the restore cannot drop.
            // The fork still gets its own MAC and IPAM allocation — sharing
            // those with a possibly-live source is the thing `reidentify`
            // exists to prevent. Naming one explicitly still works and is the
            // only option when the fork lands in a different project, since
            // networks are project-scoped.
            restoreSourceNetworkID = try await source.$networkInterfaces.get(on: req.db)
                .first?.logicalNetworkID
            if restoreSourceNetworkID == nil,
                createRequest.networkId != nil || createRequest.networkName != nil
            {
                throw Abort(
                    .conflict,
                    reason:
                        "The snapshot's sandbox has no NIC, so the fork cannot have a network: a checkpoint's device set cannot grow one on restore"
                )
            }
            // And a networked fork needs a checkpointed guest that can take
            // the target's address, not just rotate its identity.
            if restoreSourceNetworkID != nil,
                !SandboxGuestControlProtocol.supportsNetworkReconfigure(
                    snapshot.guestControlProtocolVersion)
            {
                throw Abort(
                    .conflict,
                    reason:
                        "Snapshot's checkpointed guest cannot re-address its NIC (guest control protocol \(snapshot.guestControlProtocolVersion ?? 0), need >= \(SandboxGuestControlProtocol.networkReconfigureMinimumVersion))"
                )
            }
            // …and a *host* that can point the checkpointed network device at
            // the fork's TAP. Capture needs no such thing, so a networked
            // snapshot can exist on a host that cannot fork it; without this
            // the only place that shows up is a permanent agent-side refusal
            // the caller sees as a degraded sandbox. Same shape as the gate
            // above it: only refuse a fork that could never place anywhere,
            // and leave the per-agent filtering to the scheduler.
            if restoreSourceNetworkID != nil, !snapshot.isExported, let pinnedAgent,
                let blocker = SandboxSnapshotCompatibility.networkedForkBlocker(target: pinnedAgent)
            {
                throw Abort(.conflict, reason: blocker)
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

        // The network the fork inherits when it named none (STR-104). Only
        // within the source's own project: networks are project-scoped, so a
        // cross-project fork has to name one in the target — and saying that
        // is better than resolving the source's id against a project it does
        // not belong to and reporting it as "not found".
        let inheritedNetworkID: UUID? = try {
            guard let restoreSourceNetworkID, let restoreSource,
                createRequest.networkId == nil, createRequest.networkName == nil
            else { return nil }
            guard restoreSource.$project.id == projectId else {
                throw Abort(
                    .badRequest,
                    reason:
                        "The snapshot's sandbox has a NIC and this fork lands in a different project, so it must name a network of its own: a checkpoint's network device cannot be dropped on restore"
                )
            }
            return restoreSourceNetworkID
        }()

        // The NIC's security groups (STR-34), validated against this project
        // before anything is written. Naming groups without a network is a
        // mistake worth reporting rather than silently dropping: there would
        // be no NIC for them to land on.
        let requestedSecurityGroupIds = try await SecurityGroupService.resolveRequestedGroupIDs(
            createRequest.securityGroupIds, projectID: projectId, on: req.db)
        if !requestedSecurityGroupIds.isEmpty,
            createRequest.networkId == nil, createRequest.networkName == nil,
            inheritedNetworkID == nil
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
                        requestedNetworkID: createRequest.networkId ?? inheritedNetworkID,
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
        return try await Self.detailResponse(for: sandbox, on: req.db)
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
