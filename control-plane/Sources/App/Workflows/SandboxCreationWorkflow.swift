import Fluent
import Foundation
import Vapor
import StratoShared

/// Owns sandbox creation and fork admission as one use case. The controller
/// remains responsible only for HTTP routing while this workflow coordinates
/// validation, quota reservation, transactional persistence, and placement.
enum SandboxCreationWorkflow {
    static func create(req: Request) async throws -> Response {
        let user = try req.requireActingUser("Creating a sandbox")

        struct CreateSandboxRequest: Content, ValidatedRequestBody {
            var name: String
            /// OCI image reference, e.g. `ghcr.io/acme/worker:v3`.
            let image: String?
            /// Ready sandbox snapshot to restore into a new identity (issue
            /// #427). Mutually exclusive with image/machine/process fields.
            let restoreFrom: UUID?
            /// Required by project resolution; optional at decode time so the API can
            /// return a useful error.
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
            let canReadSnapshot = try await req.can(
                "sandbox:read", on: IAMNode(type: .sandboxSnapshot, id: snapshotID))
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
            guard pinnedAgent != nil || snapshot.isExported else {
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
                snapshot.guestControlProtocolVersion
                    == SandboxGuestControlProtocol.currentVersion
            else {
                throw Abort(
                    .conflict,
                    reason:
                        "Snapshot uses unsupported guest control protocol "
                        + "\(snapshot.guestControlProtocolVersion.map(String.init) ?? "missing"); "
                        + "version \(SandboxGuestControlProtocol.currentVersion) is required. "
                        + "Delete this snapshot and recapture it after upgrading the sandbox guest image."
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
            action: "sandbox:create",
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
                    let acceptedAt = try await ClusterClock.read(on: db)
                    try await IdempotencyService.reserve(
                        req.idempotencyContext, actor: .user(userID), on: db)
                    if let restoreSnapshotID {
                        try await SandboxController.requireSnapshotAvailableForFork(
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
                    guard
                        case .applied = try await sandbox.advanceDesiredStateGeneration(
                            expectedGeneration: 0, on: db)
                    else {
                        throw Abort(
                            .internalServerError,
                            reason: "Failed to initialize the sandbox desired-state generation")
                    }
                    // How long the create has to converge before the
                    // stuck-convergence sweep marks the sandbox degraded
                    // (STR-147), stamped with the insert for the reason the VM
                    // create path stamps its own.
                    sandbox.extendConvergenceDeadline(
                        by: OperationResourceKind.sandbox.completionBudgetSeconds(for: .create),
                        from: acceptedAt)
                    // Fluent stamps `created_at` from the process clock on
                    // insert. Rewrite it in the same transaction so the
                    // sandbox TTL derives from PostgreSQL time as well.
                    sandbox.createdAt = acceptedAt.date
                    try await sandbox.update(on: db)

                    // One NIC on the requested logical network, IPAM-allocated by
                    // the control plane (issue #416); no NIC when the caller
                    // named no network (issue #765).
                    try await SandboxController.attachNIC(
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

                    let accepted = ResourceMutation.Accepted(
                        mutationID: try event.requireID(), targetGeneration: sandbox.generation)
                    try await IdempotencyService.complete(
                        req.idempotencyContext,
                        actor: .user(userID),
                        resourceKind: .sandbox,
                        resourceID: sandboxID,
                        accepted: accepted,
                        on: db)
                    return accepted
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
            .create, resourceType: Sandbox.self, resourceID: sandboxID,
            targetGeneration: accepted.targetGeneration, agentIDs: [],
            strategy: .placement { @Sendable [app = req.application] db in
                try await app.workloadPlacement.createSandbox(sandbox: sandbox, db: db)
            }, app: req.application)

        req.logger.info(
            "Sandbox creation accepted",
            metadata: [
                "sandbox_id": .string(sandboxID.uuidString),
                "mutation_id": .string(accepted.mutationID.uuidString),
                "image": .string(imageRef),
            ])

        return try await SandboxController.acceptedResponse(for: sandbox, accepted, on: req)
    }
}
