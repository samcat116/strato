import Fluent
import Vapor
import StratoShared

struct VolumeController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let volumes = routes.grouped("api", "volumes")
        let volumeSnapshots = routes.grouped("api", "volume-snapshots")

        // All routes require authentication
        let protected = volumes.grouped(User.guardMiddleware())
        let protectedSnapshots = volumeSnapshots.grouped(User.guardMiddleware())

        // Volume CRUD operations
        protected.get(use: listVolumes)
        protected.post(use: createVolume)
        protected.get(":volumeId", use: getVolume)
        protected.put(":volumeId", use: updateVolume)
        protected.delete(":volumeId", use: deleteVolume)

        // Volume actions
        protected.post(":volumeId", "attach", use: attachVolume)
        protected.post(":volumeId", "detach", use: detachVolume)
        protected.post(":volumeId", "resize", use: resizeVolume)
        protected.post(":volumeId", "io-limits", use: setIOLimits)
        protected.post(":volumeId", "snapshot", use: createSnapshot)
        protected.post(":volumeId", "clone", use: cloneVolume)

        // Snapshot operations
        protected.get(":volumeId", "snapshots", use: listSnapshots)
        protected.delete(":volumeId", "snapshots", ":snapshotId", use: deleteSnapshot)
        protectedSnapshots.get(use: listProjectSnapshots)
    }

    // MARK: - List Volumes

    /// List all volumes the user has access to
    /// GET /api/volumes
    /// Query params: project_id (optional), status (optional),
    /// limit/offset (optional) — select the page.
    @Sendable
    func listVolumes(req: Request) async throws -> PagedResponse<VolumeResponse> {
        let paging = try ListPaging.decode(from: req)
        let volumes = try await visibleVolumes(req: req)
        return paging.page(volumes)
    }

    /// Every volume the caller may read, newest first, ready for slicing.
    func visibleVolumes(req: Request) async throws -> [VolumeResponse] {
        _ = try req.auth.require(User.self)

        // Build query
        var query = Volume.query(on: req.db)

        // Filter by project if specified
        var visibility: ProjectVisibility?
        if let projectIdString = req.query[String.self, at: "project_id"],
            let projectId = UUID(uuidString: projectIdString)
        {
            // Verify user has access to the project
            let hasAccess = try await req.can("project:read", on: IAMNode(type: .project, id: projectId))

            guard hasAccess else {
                throw Abort(.forbidden, reason: "You don't have access to this project")
            }

            query = query.filter(\.$project.$id == projectId)
        } else {
            // Narrow to the projects the caller could reach, then let the
            // evaluator decide the ones that carry rows (`ProjectVisibility`).
            let resolved = try await ProjectVisibility.resolve(on: req)
            guard !resolved.reachesNoProject else { return [] }
            if let candidates = resolved.candidateProjectIDs {
                query = query.filter(\.$project.$id ~~ candidates)
            }
            visibility = resolved
        }

        // Filter by status if specified
        if let statusString = req.query[String.self, at: "status"],
            let status = VolumeStatus(rawValue: statusString)
        {
            query = query.filter(\.$status == status)
        }

        // Filter by volume type if specified
        if let typeString = req.query[String.self, at: "type"],
            let volumeType = VolumeType(rawValue: typeString)
        {
            query = query.filter(\.$volumeType == volumeType)
        }

        var volumes =
            try await query
            .sort(\.$createdAt, .descending)
            .sort(\.$id, .descending)
            .all()

        if let visibility {
            volumes = try await visibility.readableRows(volumes, projectID: { $0.$project.id }, on: req)
        }

        return try await VolumeService.responses(for: volumes, on: req.db)
    }

    // MARK: - Create Volume

    /// Create a new volume
    /// POST /api/volumes
    @Sendable
    func createVolume(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let request = try req.content.decodeValidated(CreateVolumeRequest.self)

        let project = try await req.authorizedProjectForCreate(
            requested: request.projectId,
            action: "volume:create", resourceKind: "volumes")
        let projectId = try project.requireID()
        // Which of the project's environments the bytes are charged to
        // (STR-181). Volumes have never carried one, which is the structural
        // reason nothing counted them: a quota's scope predicate filters on it.
        let environment = try project.resolveEnvironment(request.environment)

        // Validate volume type. Format is pool-dependent and is resolved once
        // the selected backend is known below.
        let volumeType = try VolumeNaming.parseVolumeType(request.volumeType)
        guard volumeType == .data else {
            throw Abort(
                .badRequest,
                reason: "Boot volumes are created and owned by the VM lifecycle; create a data volume instead")
        }

        // Resolve the source image (if any) up front, so a bad image ID fails
        // the request instead of surfacing later as a failed volume.
        var sourceImage: Image?
        if let sourceImageId = request.sourceImageId {
            guard let image = try await Image.find(sourceImageId, on: req.db) else {
                throw Abort(.notFound, reason: "Source image not found")
            }

            // The caller must be able to read the image before using it as a
            // volume source: provisioning hands the agent a signed download URL
            // for it, so accepting an unauthorized image ID would let a user
            // materialize another project's image into their own volume.
            let hasImagePermission = try await req.can(
                "image:read", on: IAMNode(type: .image, id: sourceImageId))

            guard hasImagePermission else {
                throw Abort(.forbidden, reason: "Access denied to image")
            }

            guard image.status == .ready else {
                throw Abort(.badRequest, reason: "Source image is not ready (status: '\(image.status.rawValue)')")
            }
            try await image.$artifacts.load(on: req.db)
            guard image.usableDiskArtifact != nil else {
                throw Abort(
                    .badRequest,
                    reason: "Source image does not have a usable disk-image artifact")
            }
            sourceImage = image
        }

        // Validate the requested size before converting, mirroring the VM and
        // sandbox create paths: a non-positive or oversized value must return
        // 400, never reach the (now non-trapping) GiB→bytes conversion as an
        // out-of-range operand.
        guard request.sizeGB > 0 else {
            throw Abort(.badRequest, reason: "'sizeGB' must be positive")
        }
        guard request.sizeGB <= Volume.maxSizeGB else {
            throw Abort(
                .badRequest,
                reason: "'sizeGB' exceeds the maximum volume size of \(Volume.maxSizeGB) GiB")
        }
        guard let sizeBytes = request.sizeGB.gbToBytes else {
            throw Abort(.badRequest, reason: "'sizeGB' is too large")
        }

        try Self.validateIOLimits(iopsTotal: request.iopsTotal, bpsTotal: request.bpsTotal)

        // Omission preserves the historical default-local behavior exactly.
        // An explicit Ceph pool must belong to this project through its scoped
        // access row; a pool id is never an authority shortcut.
        let pool = try await StoragePool.resolveForCreate(
            requestedPoolID: request.poolId, projectID: projectId, on: req.db)
        let format: VolumeFormat
        if pool.mode == .ceph {
            format = try request.format.map(VolumeNaming.parseFormat) ?? .raw
            guard format == .raw else {
                throw Abort(.badRequest, reason: "Ceph RBD volumes require format 'raw'")
            }
        } else {
            format = try VolumeNaming.parseFormat(request.format)
        }

        // Create volume record
        let volume = Volume(
            name: request.name,
            description: request.description ?? "",
            projectID: projectId,
            environment: environment,
            size: sizeBytes,
            format: format,
            volumeType: volumeType,
            status: .creating,
            createdByID: user.id!,
            poolID: pool.id,
            sourceImageID: request.sourceImageId
        )
        // Set before the insert rather than through a follow-up mutation, so a
        // volume never exists uncapped even briefly (STR-19).
        volume.iopsTotal = request.iopsTotal
        volume.bpsTotal = request.bpsTotal

        let app = req.application
        let userID = try user.requireID()
        // Bind to a `let` so the `@Sendable` dispatch closure captures an
        // immutable copy rather than the mutable `sourceImage` var.
        let poolID = try pool.requireID()

        volume.setDesiredStatus(.present)
        volume.generation = 1

        // The first visible desired state is generation 1. Reserve storage
        // first, then commit the insert, creator binding, and attribution
        // together. Create cannot use `ResourceMutation.accept`, because that
        // service operates on a row that already exists.
        let accepted: ResourceMutation.Accepted
        do {
            accepted = try await req.db.transaction { db -> ResourceMutation.Accepted in
                try await IdempotencyService.reserve(
                    req.idempotencyContext, actor: .user(userID), on: db)
                try await QuotaEnforcementService.reserveVolume(
                    for: project, environment: environment, size: sizeBytes, on: db)
                // Stamp from PostgreSQL in the accepting transaction so the
                // insert and its convergence budget share one clock. Sample
                // after the admission locks so their wait cannot spend it.
                let acceptedAt = try await ClusterClock.read(on: db)
                volume.extendConvergenceDeadline(
                    by: OperationResourceKind.volume.completionBudgetSeconds(for: .create),
                    from: acceptedAt)
                try await volume.save(on: db)
                let volumeID = try volume.requireID()
                try await RoleBindingService.grant(
                    principalType: .user,
                    principalID: userID,
                    role: .admin,
                    nodeType: .volume,
                    nodeID: volumeID,
                    createdBy: userID,
                    on: db
                )
                let event = try await ResourceEvent.record(
                    .create, resourceKind: .volume, resourceID: volumeID,
                    actor: .user(userID), on: db)
                let accepted = ResourceMutation.Accepted(
                    mutationID: try event.requireID(), targetGeneration: volume.generation)
                try await IdempotencyService.complete(
                    req.idempotencyContext,
                    actor: .user(userID),
                    resourceKind: .volume,
                    resourceID: volumeID,
                    accepted: accepted,
                    on: db)
                return accepted
            }
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(
                .conflict,
                reason: "A volume named '\(volume.name)' already exists in this project")
        }

        let volumeId = try volume.requireID()

        // Placement is a `.placement` dispatch rather than something resolved
        // in-band, and it has to *commit* before the sync can carry the volume:
        // `DesiredStateAssembler` finds volumes through active replica rows, so
        // an unplaced one is in nobody's desired state. On throw, `dispatch`
        // degrades the volume with the reason.
        req.resourceMutation.dispatch(
            .create, resourceType: Volume.self, resourceID: volumeId,
            targetGeneration: accepted.targetGeneration, agentIDs: [],
            strategy: .placement { @Sendable db in
                let agents = await app.agentService.getAgentList()
                let instant = try await ClusterClock.read(on: db)
                guard let currentPool = try await StoragePool.find(poolID, on: db) else {
                    throw ResourceMutation.WorkError("The selected storage pool no longer exists")
                }
                switch currentPool.mode {
                case .ceph:
                    guard
                        let agentId = VolumeService.selectCephReconciler(
                            from: agents, pool: currentPool, at: instant)?.id?.uuidString
                    else {
                        throw ResourceMutation.WorkError(
                            "No configured Ceph client is online in storage pool '\(currentPool.name)'.")
                    }
                    if try await VolumeService.assignInitialCephReconciler(
                        volumeID: volumeId,
                        expectedGeneration: accepted.targetGeneration,
                        agentID: agentId,
                        on: db)
                    {
                        await app.agentService.syncDesiredState(agentId: agentId)
                    }
                case .local:
                    guard
                        let agentId = VolumeService.selectVolumeAgent(
                            from: agents, memberAgentIds: currentPool.memberAgentIds,
                            at: instant)?.id?.uuidString
                    else {
                        throw ResourceMutation.WorkError(
                            "No agent is available to host this volume: it needs an online, "
                                + "QEMU-capable agent in the volume's local pool.")
                    }
                    try await VolumeReplica(
                        volumeID: volumeId, agentId: agentId, state: .provisioning
                    ).create(on: db)
                    await app.agentService.syncDesiredState(agentId: agentId)
                case .replicated:
                    throw ResourceMutation.WorkError("Replicated storage pools are not executable")
                }
            },
            app: app)

        req.logger.info(
            "Volume creation requested",
            metadata: [
                "volumeId": .string(volumeId.uuidString),
                "name": .string(volume.name),
                "strato.project.id": .string(projectId.uuidString),
                "sizeGB": .stringConvertible(request.sizeGB),
                "sourceImageId": .string(sourceImage?.id?.uuidString ?? ""),
            ])

        return try await AcceptedMutation(
            VolumeService.response(for: volume, on: req.db), accepted
        ).acceptedResponse()
    }

    // MARK: - Get Volume

    /// Get a specific volume by ID
    /// GET /api/volumes/:volumeId
    @Sendable
    func getVolume(req: Request) async throws -> VolumeResponse {
        let volume = try await fetchVolumeWithAction(req: req, action: "volume:read")
        return try await VolumeService.response(for: volume, on: req.db)
    }

    // MARK: - Update Volume

    /// Update a volume's metadata
    /// PUT /api/volumes/:volumeId
    @Sendable
    func updateVolume(req: Request) async throws -> VolumeResponse {
        let volume = try await fetchVolumeWithAction(req: req, action: "volume:update")
        let request = try req.content.decodeValidated(UpdateVolumeRequest.self)

        if let name = request.name {
            volume.name = name
        }
        if let description = request.description {
            volume.description = description
        }

        try await volume.save(on: req.db)

        req.logger.info(
            "Volume updated",
            metadata: [
                "volumeId": .string(volume.id!.uuidString),
                "name": .string(volume.name),
            ])

        return try await VolumeService.response(for: volume, on: req.db)
    }

    // MARK: - Delete Volume

    /// Delete a volume
    /// DELETE /api/volumes/:volumeId
    @Sendable
    func deleteVolume(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let volume = try await fetchVolumeWithAction(req: req, action: "volume:delete")

        // Only an attached volume is undeletable. Every other state is fair
        // game: deletion is level-triggered now and the agent's teardown is
        // idempotent, so there is no half-finished operation a delete could
        // interrupt into an inconsistent state (which is what issue #644's
        // per-status escape hatches existed to work around).
        guard volume.canDelete else {
            throw Abort(
                .conflict,
                reason: "Volume is attached to a VM and cannot be deleted. Detach it first."
            )
        }

        // Deletion via state sync, exactly like a VM's: desired becomes
        // `.absent`, the volume is stamped with the finalizers its teardown
        // owes, the agent removes the data on its next sync, and the row goes
        // only once the observed report stops listing the volume. Snapshot rows
        // and role bindings are cleaned up by `Volume.reap` at that point, not
        // here — the row has to outlive this request.
        let volumeID = try volume.requireID()
        let userID = try user.requireID()
        let app = req.application
        let volumePool = try await VolumeService.pool(of: volume, on: req.db)
        let isCeph = volumePool?.mode == .ceph
        if isCeph, try await reachableAgentHolding(volume, req: req) == nil {
            throw Abort(.conflict, reason: "No configured Ceph client is online to delete this volume")
        }
        // Every physical copy owes teardown, regardless of replica health or
        // current agent reachability. Offline agents leave the deletion
        // pending rather than silently orphaning bytes.
        let physicalAgentIDs =
            isCeph
            ? volume.reconcilerAgentId.map { [$0] } ?? []
            : try await VolumeService.agentIDsWithPhysicalReplicas(of: volume, on: req.db)
        let strategy: ResourceMutation.Dispatch =
            !physicalAgentIDs.isEmpty
            ? .stateSync
            : .directResolution { @Sendable db in
                // The initial lookup happens outside ResourceMutation's row
                // lock. Refuse to reap if a placement raced with it, and drive
                // the newly discovered copies through desired-state teardown.
                let racedAgentIDs =
                    isCeph
                    ? volume.reconcilerAgentId.map { [$0] } ?? []
                    : try await VolumeService.agentIDsWithPhysicalReplicas(of: volume, on: db)
                if !racedAgentIDs.isEmpty {
                    for agentID in racedAgentIDs {
                        await app.agentService.syncDesiredState(agentId: agentID)
                    }
                    return
                }
                let outcome: ResourceFinalizerService.ClearOutcome
                do {
                    outcome = try await ResourceFinalizerService.clear(
                        .agentAbsent, from: volume, on: db, app: app)
                } catch {
                    throw ResourceMutation.WorkError(
                        "Failed to delete volume record: \(error.localizedDescription)")
                }
                if case .held(let remaining) = outcome {
                    app.logger.info(
                        "Volume delete is waiting on finalizers other than the agent's",
                        metadata: [
                            "volumeId": .string(volumeID.uuidString),
                            "finalizers": .string(remaining.joined(separator: ",")),
                        ])
                }
                _ = outcome.isRemoved
            }

        let accepted = try await req.resourceMutation.accept(
            .delete, on: volume, actor: .user(userID), dispatch: strategy,
            on: req.db, app: app,
            idempotencyResponseBody: { @Sendable volume, accepted, db in
                try await AcceptedMutation(
                    VolumeService.response(for: volume, on: db), accepted
                ).encodedBody()
            }
        ) { @Sendable db in
            // `accept` refreshes the model after acquiring the row lock. An
            // attach may have committed since the request's initial guard, so
            // deletion must be authorized again against that serialized state.
            guard volume.canDelete else {
                throw Abort(
                    .conflict,
                    reason: "Volume is attached to a VM and cannot be deleted. Detach it first."
                )
            }

            // Volume teardown is scoped to every physical replica, not only
            // the healthy/provisioning set used by generic placement. Stamp
            // before the mark, and never re-stamp a terminating volume: doing
            // so would resurrect a token its participants already cleared.
            if !volume.isTerminating {
                let teardownAgentIDs =
                    isCeph
                    ? volume.reconcilerAgentId.map { [$0] } ?? []
                    : try await VolumeService.agentIDsWithPhysicalReplicas(of: volume, on: db)
                volume.finalizers =
                    teardownAgentIDs.isEmpty
                    ? [] : [ResourceFinalizer.agentAbsent.rawValue]
            }
            volume.setDesiredStatus(.absent)
        }

        req.logger.info(
            "Volume deletion requested",
            metadata: ["volumeId": .string(volumeID.uuidString)])

        if let response = accepted.cachedResponse() { return response }
        return try await AcceptedMutation(
            VolumeService.response(for: volume, on: req.db), accepted
        ).acceptedResponse()
    }

    // MARK: - Attach Volume

    /// Attach a volume to a VM
    /// POST /api/volumes/:volumeId/attach
    /// Body: { "vmId": UUID, "deviceName"?: string, "bootOrder"?: int, "readonly"?: bool }
    @Sendable
    func attachVolume(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let volume = try await fetchVolumeWithAction(req: req, action: "volume:attach")
        let request = try req.content.decode(AttachVolumeRequest.self)

        guard volume.volumeType == .data else {
            throw Abort(
                .conflict,
                reason: "Boot-volume attachment is owned by the VM lifecycle")
        }

        guard volume.canAttach else {
            throw Abort(
                .conflict,
                reason: "Volume is already attached to a VM. Detach it first.")
        }

        // Attaching changes the VM, so the caller needs update on it too. An
        // unreachable VM is answered as absent whether it is missing or merely
        // forbidden — see `reachableVM` (issue #881).
        let vm = try await req.reachableVM(request.vmId, action: "vm:update")

        // Permission on both sides isn't enough: a caller holding rights in two
        // projects could otherwise move a volume's data across the project
        // boundary, leaving quota attributed to one project and the consuming
        // workload in another. Same containment rule as VM create applies to
        // networks and security groups (issue #766), answered the same way at
        // every site (issue #777).
        try ProjectContainment.require(
            "Volume", in: volume.$project.id,
            sameProjectAs: "the VM", in: vm.$project.id)

        // Environment-scoped quotas make the environment part of containment,
        // not merely display metadata (STR-181). Letting a development volume
        // attach to a production VM would keep charging the development quota
        // while production consumed the bytes.
        guard volume.environment == vm.environment else {
            throw Abort(
                .badRequest,
                reason:
                    "Volume belongs to environment '\(volume.environment)', but the VM belongs to '\(vm.environment)'. Volumes can only attach within the same environment."
            )
        }

        // IMPORTANT: Check that VM is QEMU type - volumes not supported for Firecracker
        guard vm.hypervisorType == .qemu else {
            throw Abort(
                .badRequest,
                reason:
                    "Volume operations are not supported for Firecracker VMs. Firecracker only supports a single root disk."
            )
        }

        // Pool-aware reachability guard: the VM's agent must be able to reach
        // the volume's data. For a `local` pool that means the agent holding
        // the volume's single replica — identical to the old same-hypervisor
        // check; for a `replicated` pool, any member agent.
        //
        // Enforced synchronously, at accept time, rather than left for the
        // reconciler to discover: a `400` now is a far better answer than a
        // `202` that degrades a minute later, and the same-agent constraint is
        // a fact about the request, not about convergence.
        guard let poolForAttachment = try await volume.$pool.get(on: req.db) else {
            throw Abort(.internalServerError, reason: "Volume references a missing storage pool")
        }
        // A device name from the request body becomes a hypervisor object id,
        // so it is validated here rather than at the point it would otherwise
        // fail — an opaque hot-plug rejection, or a recorded attachment that
        // breaks the guest's next boot (STR-129).
        let requestedDeviceName: VolumeDeviceName? = try request.deviceName.map {
            guard let name = VolumeDeviceName($0) else {
                throw Abort(.badRequest, reason: InvalidVolumeDeviceName(rawValue: $0).description)
            }
            return name
        }

        let userID = try user.requireID()
        let readonly = request.readonly ?? false
        let bootOrder = request.bootOrder
        let vmID = try vm.requireID()
        let project = try await volume.project(on: req.db)

        let attachmentPoolMode = poolForAttachment.mode
        let previousReconciler = volume.reconcilerAgentId
        let accepted = try await req.resourceMutation.accept(
            .attach, on: volume, actor: .user(userID), dispatch: .stateSync,
            on: req.db, app: req.application
        ) { @Sendable tx in
            // A cloned or image-backed volume is materialized at the source's
            // virtual size, which can exceed the size the caller requested.
            // Wait until the owning agent has measured it, then reserve any
            // excess before attachment gives a guest the chance to grow the
            // sparse file. Raising the desired size in the same transaction
            // also turns the agent's refused shrink into a convergent no-op.
            if volume.$sourceImage.id != nil || volume.$sourceVolume.id != nil {
                guard volume.observedSizeBytes != nil else {
                    throw Abort(
                        .conflict,
                        reason:
                            "Volume is still being materialized from its source. Wait for its size to be reported before attaching it."
                    )
                }
            }
            if let materializedSize = volume.observedSizeBytes, materializedSize > volume.size {
                guard materializedSize <= WorkloadSizeLimits.maxDiskBytes else {
                    throw Abort(
                        .conflict,
                        reason:
                            "The materialized volume is larger than the maximum supported volume size."
                    )
                }
                try await QuotaEnforcementService.reserveVolumeResize(
                    for: project, environment: volume.environment,
                    sizeDelta: materializedSize - volume.size,
                    reason: "the materialized volume", on: tx)
                volume.size = materializedSize
            }

            // The desired attachment, and nothing else. There is no
            // `.attaching` status to set and revert: the agent reports what it
            // realized, and `conditions` is what a client watches.
            //
            // Choosing the device name belongs *here*, inside the mutation's
            // transaction and under the per-VM advisory lock, not before it:
            // generating the next free `disk<N>` is a read-then-write, and two
            // attaches that read before either wrote both picked the same slot
            // (STR-129).
            try await VolumeAttachmentService.claim(
                volume, to: vm,
                deviceName: requestedDeviceName,
                bootOrder: bootOrder,
                readonly: readonly,
                on: tx)

            // `claim` locks and refreshes the VM row. Resolve reachability only
            // after that refresh: placement may have moved while this request
            // was waiting for the volume/attachment locks.
            let replicaAgentIds = try await VolumeService.agentIDs(holding: volume, on: tx)
            let instant = try await ClusterClock.read(on: tx)
            guard let currentPool = try await volume.$pool.get(on: tx) else {
                throw Abort(.internalServerError, reason: "Volume references a missing storage pool")
            }
            if let vmHypervisorID = vm.hypervisorId {
                guard let vmAgentID = UUID(uuidString: vmHypervisorID),
                    let vmAgent = try await Agent.find(vmAgentID, on: tx)
                else {
                    throw Abort(.conflict, reason: "VM's assigned agent no longer exists")
                }
                guard
                    StoragePool.agentCanReach(
                        agent: vmAgent, pool: currentPool,
                        replicaAgentIds: replicaAgentIds, at: instant)
                else {
                    throw Abort(
                        .badRequest,
                        reason:
                            "Volume is not reachable from the VM's agent. Volume is on '\(replicaAgentIds.joined(separator: ", "))', VM is on '\(vmHypervisorID)'"
                    )
                }
            } else if attachmentPoolMode == .ceph {
                throw Abort(.conflict, reason: "Ceph attachment requires a placed VM")
            }

            if attachmentPoolMode == .ceph {
                guard let vmHost = vm.hypervisorId else {
                    throw Abort(.conflict, reason: "Ceph attachment requires a placed VM")
                }
                if let currentReconciler = volume.reconcilerAgentId,
                    currentReconciler != vmHost,
                    !volume.isConverged
                {
                    throw Abort(
                        .conflict,
                        reason:
                            "The previous Ceph detach has not converged on its current client. "
                            + "Wait for the volume's observed generation before attaching it on another host.")
                }
                volume.reconcilerAgentId = vmHost
            }
        }

        if attachmentPoolMode == .ceph,
            let previousReconciler,
            previousReconciler != volume.reconcilerAgentId
        {
            await req.application.agentService.syncDesiredState(agentId: previousReconciler)
        }

        req.logger.info(
            "Volume attachment requested",
            metadata: [
                "volumeId": .string(volume.id!.uuidString),
                "strato.vm.id": .string(vmID.uuidString),
                "deviceName": .string(volume.deviceName ?? ""),
            ])

        return try await AcceptedMutation(
            VolumeService.response(for: volume, on: req.db), accepted
        ).acceptedResponse()
    }

    // MARK: - Detach Volume

    /// Detach a volume from a VM
    /// POST /api/volumes/:volumeId/detach
    @Sendable
    func detachVolume(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let volume = try await fetchVolumeWithAction(req: req, action: "volume:detach")

        guard volume.volumeType == .data else {
            throw Abort(
                .conflict,
                reason: "A VM's canonical boot volume cannot be detached independently")
        }

        guard volume.canDetach, let vmId = volume.$vm.id else {
            throw Abort(.conflict, reason: "Volume is not attached to any VM")
        }

        // Fetch the VM
        guard let vm = try await VM.find(vmId, on: req.db) else {
            throw Abort(.notFound, reason: "VM not found")
        }

        // Check that VM is QEMU type - volumes not supported for Firecracker
        guard vm.hypervisorType == .qemu else {
            throw Abort(
                .badRequest,
                reason:
                    "Volume operations are not supported for Firecracker VMs. Firecracker only supports a single root disk."
            )
        }

        let userID = try user.requireID()
        let accepted = try await req.resourceMutation.accept(
            .detach, on: volume, actor: .user(userID), dispatch: .stateSync,
            on: req.db, app: req.application
        ) { @Sendable db in
            // Every attachment column at once, through the one function that
            // owns the transition, so the row can never come to rest describing
            // half an attachment (STR-129).
            VolumeAttachmentService.clearAttachment(
                volume, at: try await ClusterClock.read(on: db))
        }

        req.logger.info(
            "Volume detachment requested",
            metadata: [
                "volumeId": .string(volume.id!.uuidString),
                "strato.vm.previous.id": .string(vmId.uuidString),
            ])

        return try await AcceptedMutation(
            VolumeService.response(for: volume, on: req.db), accepted
        ).acceptedResponse()
    }

    // MARK: - Resize Volume

    /// Resize a volume (increase size only)
    /// POST /api/volumes/:volumeId/resize
    /// Body: { "sizeGB": int }
    @Sendable
    func resizeVolume(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let volume = try await fetchVolumeWithAction(req: req, action: "volume:update")
        let request = try req.content.decode(ResizeVolumeRequest.self)

        // Grow-only, but no longer detach-only (STR-19). Whether an attached
        // volume is grown under the running guest or by the offline path is the
        // agent's decision, because only it knows whether a process holds the
        // image open. What is left to refuse here is a volume with no size to
        // converge on at all.
        guard volume.canResize else {
            throw Abort(.conflict, reason: "Volume is being deleted and cannot be resized.")
        }

        // Validate the requested size before converting, so an oversized value
        // returns 400 rather than reaching the GiB→bytes conversion as an
        // out-of-range operand. (The "must be larger" guard below only fires
        // after conversion, so it cannot be relied on to catch overflow.)
        guard request.sizeGB > 0 else {
            throw Abort(.badRequest, reason: "'sizeGB' must be positive")
        }
        guard request.sizeGB <= Volume.maxSizeGB else {
            throw Abort(
                .badRequest,
                reason: "'sizeGB' exceeds the maximum volume size of \(Volume.maxSizeGB) GiB")
        }
        guard let newSizeBytes = request.sizeGB.gbToBytes else {
            throw Abort(.badRequest, reason: "'sizeGB' is too large")
        }

        // Validate new size is larger. Shrinking truncates the guest's
        // filesystem, so the agent refuses it permanently too — this is the
        // early, legible half of that refusal.
        guard newSizeBytes > volume.size else {
            throw Abort(
                .badRequest,
                reason: "New size (\(request.sizeGB) GB) must be larger than current size (\(volume.sizeGB) GB)")
        }

        guard try await reachableAgentHolding(volume, req: req) != nil else {
            throw Abort(.conflict, reason: "Volume is not provisioned on any hypervisor")
        }

        let previousSize = volume.size
        let userID = try user.requireID()
        let project = try await volume.project(on: req.db)
        let environment = volume.environment
        let accepted = try await req.resourceMutation.accept(
            .resize, on: volume, actor: .user(userID), dispatch: .stateSync,
            on: req.db, app: req.application
        ) { @Sendable db in
            // Re-check against the row under the lock, not the one the request
            // read: `lockAndRefresh` adopts the committed size, so a resize that
            // landed in between is visible here and this one may now be a
            // shrink. The guard above cannot see that race.
            guard newSizeBytes > volume.size else {
                throw Abort(
                    .conflict,
                    reason:
                        "The volume was resized to \(volume.sizeGB) GB while this request was in flight; a resize must grow it."
                )
            }
            // Only the delta, and *before* the size write below, so the resync
            // baseline still reflects the old size — the `reserveVMResize`
            // contract (STR-181). `accept` runs this inside its transaction,
            // after locking the row, so a rejection unwinds the whole mutation.
            try await QuotaEnforcementService.reserveVolumeResize(
                for: project, environment: environment,
                sizeDelta: newSizeBytes - volume.size, on: db)
            // The size on the row is the *desired* size from here on. The agent
            // grows the disk and confirms by generation, which is what makes a
            // resize whose sync was dropped simply happen on the next one.
            volume.size = newSizeBytes
        }

        req.logger.info(
            "Volume resize requested",
            metadata: [
                "volumeId": .string(volume.id!.uuidString),
                "previousSizeGB": .stringConvertible(Double(previousSize) / 1024.0 / 1024.0 / 1024.0),
                "newSizeGB": .stringConvertible(request.sizeGB),
            ])

        return try await AcceptedMutation(
            VolumeService.response(for: volume, on: req.db), accepted
        ).acceptedResponse()
    }

    // MARK: - I/O Limits

    /// Validates a requested pair of I/O ceilings (STR-19).
    ///
    /// Zero is a `400`, not "unlimited". QEMU — and libvirt's `<iotune>` — spell
    /// unlimited as zero, so accepting it would make a typo indistinguishable
    /// from a deliberate removal, on the one setting where the difference is
    /// "this tenant is capped" versus "this tenant is not". Omit the field to
    /// clear a cap; there is exactly one way to say uncapped.
    private static func validateIOLimits(iopsTotal: Int64?, bpsTotal: Int64?) throws {
        if let iops = iopsTotal {
            guard iops > 0, iops <= Volume.maxIOPSTotal else {
                throw Abort(
                    .badRequest,
                    reason:
                        "'iopsTotal' must be between 1 and \(Volume.maxIOPSTotal); omit it to remove the cap")
            }
        }
        if let bps = bpsTotal {
            guard bps > 0, bps <= Volume.maxBPSTotal else {
                throw Abort(
                    .badRequest,
                    reason: "'bpsTotal' must be between 1 and \(Volume.maxBPSTotal); omit it to remove the cap")
            }
        }
    }

    /// Replace a volume's absolute I/O ceilings
    /// POST /api/volumes/:volumeId/io-limits
    /// Body: { "iopsTotal"?: int, "bpsTotal"?: int }
    ///
    /// A full replacement: an omitted field clears that cap. Answers `202` and
    /// converges like every other volume mutation — though note that no agent
    /// applies ceilings yet, so `appliedIOLimits` stays null until the
    /// agent-side work lands and the request is a recorded intent rather than
    /// an enforced one.
    @Sendable
    func setIOLimits(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let volume = try await fetchVolumeWithAction(req: req, action: "volume:update")
        let request = try req.content.decode(SetVolumeIOLimitsRequest.self)

        guard volume.desiredStatus == .present else {
            throw Abort(.conflict, reason: "Volume is being deleted and its I/O limits cannot be changed.")
        }

        try Self.validateIOLimits(iopsTotal: request.iopsTotal, bpsTotal: request.bpsTotal)

        guard try await reachableAgentHolding(volume, req: req) != nil else {
            throw Abort(.conflict, reason: "Volume is not provisioned on any hypervisor")
        }

        let userID = try user.requireID()
        let accepted = try await req.resourceMutation.accept(
            .throttle, on: volume, actor: .user(userID), dispatch: .stateSync,
            on: req.db, app: req.application
        ) { @Sendable _ in
            // The requested pair is desired state from here on; the applied
            // pair is only ever written by an agent's observed report.
            volume.iopsTotal = request.iopsTotal
            volume.bpsTotal = request.bpsTotal
        }

        req.logger.info(
            "Volume I/O limits requested",
            metadata: [
                "volumeId": .string(volume.id!.uuidString),
                "iopsTotal": .string(request.iopsTotal.map(String.init) ?? "uncapped"),
                "bpsTotal": .string(request.bpsTotal.map(String.init) ?? "uncapped"),
            ])

        return try await AcceptedMutation(
            VolumeService.response(for: volume, on: req.db), accepted
        ).acceptedResponse()
    }

    // MARK: - Create Snapshot

    /// An attached clone source can be read safely only while the owning VM is
    /// both observed and desired stopped. Checking both closes the start/stop
    /// convergence window; desired state also carries the VM id so the agent
    /// holds that VM's reconciliation lane for the entire copy.
    private func requireReadableCloneSource(_ volume: Volume, on db: any Database) async throws {
        guard let vmID = volume.$vm.id else { return }
        guard let vm = try await VM.find(vmID, on: db) else {
            throw Abort(.conflict, reason: "The volume's attached VM no longer exists")
        }
        guard vm.desiredStatus == .shutdown, vm.status == .shutdown || vm.status == .created else {
            throw Abort(
                .conflict,
                reason: "An attached volume can be cloned only while its VM is shut down")
        }
    }

    /// Create a snapshot of a volume
    /// POST /api/volumes/:volumeId/snapshot
    /// Body: { "name": string, "description"?: string, "ttlSeconds"?: int }
    ///
    /// Declarative since ADR 0001 stage 8 (STR-150): `202`, and the client
    /// polls the snapshot's own `conditions`. The volume itself no longer moves
    /// through a `.snapshotting` status — a snapshot is its own resource now,
    /// so nothing has to be borrowed from the volume's status to represent it,
    /// and nothing has to be restored afterwards on a failure path.
    @Sendable
    func createSnapshot(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let volume = try await fetchVolumeWithAction(req: req, action: "volume:snapshot")
        let request = try req.content.decodeValidated(CreateSnapshotRequest.self)

        guard volume.canSnapshot else {
            if volume.$vm.id != nil {
                throw Abort(
                    .conflict,
                    reason: "Attached volumes cannot be snapshotted; detach the volume first")
            }
            throw Abort(
                .conflict,
                reason: "Volume cannot be snapshotted in status '\(volume.status.rawValue)'. Must be 'available'"
            )
        }

        // The agent is *recorded* on the snapshot rather than re-derived per
        // request: a desired entry has to appear in exactly one agent's sync,
        // and a volume that moves must not silently orphan its snapshots into
        // another host's tombstone set.
        guard let agentId = try await reachableAgentHolding(volume, req: req) else {
            throw Abort(.conflict, reason: "Volume is not provisioned on any hypervisor")
        }
        let pool = try await VolumeService.pool(of: volume, on: req.db)
        if pool?.mode != .ceph {
            try await SnapshotArtifactMutation.requireCaptureCapableAgent(
                agentId, kind: .volumeSnapshot, app: req.application)
        }

        let userID = try user.requireID()
        let snapshot = VolumeSnapshot(
            name: request.name,
            description: request.description ?? "",
            volumeID: try volume.requireID(),
            projectID: volume.$project.id,
            environment: volume.environment,
            size: volume.size,
            agentId: agentId,
            expiresAt: nil,
            createdByID: userID
        )

        let project = try await volume.project(on: req.db)

        // Creator binding on the snapshot, in the same transaction as the row
        // (issue #477), alongside the attribution event — behind the storage
        // reservation, which admits against the parent volume's *whole* size
        // (STR-181): an overlay grows toward it with no API call to refuse along
        // the way, so the pool has to be able to absorb it fully grown.
        let accepted = try await req.db.transaction { db -> ResourceMutation.Accepted in
            try await IdempotencyService.reserve(
                req.idempotencyContext, actor: .user(userID), on: db)
            try await QuotaEnforcementService.reserveSnapshotStorage(
                for: project, environment: volume.environment, size: volume.size, on: db)
            let acceptedAt = try await ClusterClock.read(on: db)
            snapshot.expiresAt = try SnapshotRetention.expiry(
                requested: request.ttlSeconds,
                defaultTTLSeconds: req.controlPlaneConfiguration.optionalInt(
                    .snapshotDefaultTTLSeconds),
                from: acceptedAt)
            snapshot.extendConvergenceDeadline(
                by: OperationResourceKind.volumeSnapshot.completionBudgetSeconds(for: .create),
                from: acceptedAt)
            try await snapshot.save(on: db)
            try await RoleBindingService.grant(
                principalType: .user,
                principalID: userID,
                role: .admin,
                nodeType: .volumeSnapshot,
                nodeID: snapshot.requireID(),
                createdBy: userID,
                on: db
            )
            return try await SnapshotArtifactMutation.recordCapture(
                snapshot, actor: .user(userID), idempotencyContext: req.idempotencyContext, on: db)
        }

        try SnapshotArtifactMutation.dispatchCapture(snapshot, app: req.application)

        let snapshotID = try snapshot.requireID()
        let volumeID = try volume.requireID()
        req.logger.info(
            "Volume snapshot accepted",
            metadata: [
                "snapshotId": .string(snapshotID.uuidString),
                "volumeId": .string(volumeID.uuidString),
                "name": .string(snapshot.name),
            ])

        return try AcceptedMutation(SnapshotResponse(from: snapshot), accepted).acceptedResponse()
    }

    // MARK: - Clone Volume

    /// Clone a volume
    /// POST /api/volumes/:volumeId/clone
    /// Body: { "name": string, "description"?: string }
    @Sendable
    func cloneVolume(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let sourceVolume = try await fetchVolumeWithAction(req: req, action: "volume:clone")
        let request = try req.content.decodeValidated(CloneVolumeRequest.self)

        // Cloning reads the source's bytes, which is why it keeps a converged
        // requirement the other verbs dropped: copying a volume whose own
        // create is still writing it yields a torn image, and unlike a resize
        // that cannot be re-driven into correctness. An attached source is
        // additionally required to be stopped and is serialized with that VM
        // by the desired-state create strategy.
        guard sourceVolume.canClone else {
            throw Abort(
                .conflict,
                reason: "Volume is not ready to be cloned; wait for it to finish converging."
            )
        }
        try await requireReadableCloneSource(sourceVolume, on: req.db)

        guard let sourceAgentId = try await reachableAgentHolding(sourceVolume, req: req) else {
            throw Abort(.conflict, reason: "Source volume is not provisioned on any hypervisor")
        }
        let sourceAgentIds = [sourceAgentId]
        let sourcePool = try await VolumeService.pool(of: sourceVolume, on: req.db)
        let sourceIsCeph = sourcePool?.mode == .ceph

        // The clone is materialized on the source's agent — a clone reads the
        // source's file, so the two must be co-located — and therefore lives in
        // the source's pool and is placed at create time rather than scheduled.
        let newVolume = Volume(
            name: request.name,
            description: request.description ?? "Clone of \(sourceVolume.name)",
            projectID: sourceVolume.$project.id,
            environment: sourceVolume.environment,
            size: sourceVolume.size,
            format: sourceVolume.format,
            // A clone is independent data storage. Only VM creation may mint a
            // canonical boot volume and attach it as disk0.
            volumeType: .data,
            status: .creating,
            createdByID: user.id!,
            poolID: sourceVolume.$pool.id,
            sourceVolumeID: sourceVolume.id
        )
        newVolume.setDesiredStatus(.present)
        newVolume.generation = 1
        if sourceIsCeph {
            newVolume.reconcilerAgentId = sourceAgentIds.first
        }

        let userID = try user.requireID()
        // Same create-only transaction as the ordinary volume path: reserve
        // the clone's full storage footprint first, then make generation 1,
        // attribution, and creator access visible together.
        let sourceProject = try await sourceVolume.project(on: req.db)
        let accepted = try await req.db.transaction { db -> ResourceMutation.Accepted in
            try await IdempotencyService.reserve(
                req.idempotencyContext, actor: .user(userID), on: db)
            try await QuotaEnforcementService.reserveVolume(
                for: sourceProject, environment: sourceVolume.environment,
                size: sourceVolume.size, on: db)
            let acceptedAt = try await ClusterClock.read(on: db)
            newVolume.extendConvergenceDeadline(
                by: OperationResourceKind.volume.completionBudgetSeconds(for: .create),
                from: acceptedAt)
            try await newVolume.save(on: db)
            let newVolumeID = try newVolume.requireID()
            try await RoleBindingService.grant(
                principalType: .user,
                principalID: userID,
                role: .admin,
                nodeType: .volume,
                nodeID: newVolumeID,
                createdBy: userID,
                on: db
            )
            let event = try await ResourceEvent.record(
                .create, resourceKind: .volume, resourceID: newVolumeID,
                actor: .user(userID), on: db)
            let accepted = ResourceMutation.Accepted(
                mutationID: try event.requireID(), targetGeneration: newVolume.generation)
            try await IdempotencyService.complete(
                req.idempotencyContext,
                actor: .user(userID),
                resourceKind: .volume,
                resourceID: newVolumeID,
                accepted: accepted,
                on: db)
            return accepted
        }

        // The clone is a create *strategy* on the new volume's desired entry,
        // not an operation on the source (ADR 0001 stage 5). The source is
        // therefore never marked busy and never has to be restored afterwards —
        // it is simply read, by an agent that already holds it.
        let newVolumeID = try newVolume.requireID()
        let app = req.application
        req.resourceMutation.dispatch(
            .create, resourceType: Volume.self, resourceID: newVolumeID,
            targetGeneration: accepted.targetGeneration, agentIDs: sourceAgentIds,
            strategy: .placement { @Sendable db in
                if !sourceIsCeph {
                    try await db.transaction { tx in
                        for agentId in sourceAgentIds {
                            try await VolumeReplica(
                                volumeID: newVolumeID, agentId: agentId, state: .provisioning
                            ).create(on: tx)
                        }
                    }
                }
                for agentId in sourceAgentIds {
                    await app.agentService.syncDesiredState(agentId: agentId)
                }
            },
            app: app)

        req.logger.info(
            "Volume clone requested",
            metadata: [
                "sourceVolumeId": .string(sourceVolume.id!.uuidString),
                "newVolumeId": .string(newVolumeID.uuidString),
                "name": .string(newVolume.name),
            ])

        return try await AcceptedMutation(
            VolumeService.response(for: newVolume, on: req.db), accepted
        ).acceptedResponse()
    }

    // MARK: - List Snapshots

    /// List snapshots in one project without requiring clients to fan out over
    /// every parent volume.
    /// GET /api/volume-snapshots?project_id=...
    @Sendable
    func listProjectSnapshots(req: Request) async throws -> PagedResponse<SnapshotResponse> {
        let paging = try ListPaging.decode(from: req)
        guard let projectID = req.query[UUID.self, at: "project_id"] else {
            throw Abort(.badRequest, reason: "'project_id' is required")
        }
        guard try await req.can("project:read", on: IAMNode(type: .project, id: projectID)) else {
            throw Abort(.forbidden, reason: "You don't have access to this project")
        }

        let snapshots = try await VolumeSnapshot.query(on: req.db)
            .filter(\.$project.$id == projectID)
            .sort(\.$createdAt, .descending)
            .sort(\.$id, .descending)
            .all()

        let volumeNodes = Set(
            snapshots.map { IAMNode(type: .volume, id: $0.$volume.id) })
        let readableVolumes = try await req.canFilter(
            "volume:read", on: Array(volumeNodes))
        let visibleSnapshots = snapshots.filter {
            readableVolumes.contains(IAMNode(type: .volume, id: $0.$volume.id))
        }

        return paging.page(visibleSnapshots.map { SnapshotResponse(from: $0) })
    }

    /// List all snapshots for a volume
    /// GET /api/volumes/:volumeId/snapshots
    /// Query params: limit/offset (optional) — select the page.
    @Sendable
    func listSnapshots(req: Request) async throws -> PagedResponse<SnapshotResponse> {
        let paging = try ListPaging.decode(from: req)
        let volume = try await fetchVolumeWithAction(req: req, action: "volume:read")

        let snapshots = try await VolumeSnapshot.query(on: req.db)
            .filter(\.$volume.$id == volume.id!)
            .sort(\.$createdAt, .descending)
            .sort(\.$id, .descending)
            .all()

        return paging.page(snapshots.map { SnapshotResponse(from: $0) })
    }

    // MARK: - Delete Snapshot

    /// Delete a snapshot
    /// DELETE /api/volumes/:volumeId/snapshots/:snapshotId
    ///
    /// Marks the snapshot absent and stamps the finalizers its teardown owes.
    /// The row outlives this request: it goes only once the owning agent's
    /// observed report stops listing the artifact (STR-150).
    @Sendable
    func deleteSnapshot(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let volume = try await fetchVolumeWithAction(req: req, action: "volume:read")

        guard let snapshotIdString = req.parameters.get("snapshotId"),
            let snapshotId = UUID(uuidString: snapshotIdString)
        else {
            throw Abort(.badRequest, reason: "Invalid snapshot ID")
        }

        guard
            let snapshot = try await VolumeSnapshot.query(on: req.db)
                .filter(\.$id == snapshotId)
                .filter(\.$volume.$id == volume.id!)
                .first()
        else {
            throw Abort(.notFound, reason: "Snapshot not found")
        }

        let hasPermission = try await req.can(
            "volume:snapshot", on: IAMNode(type: .volumeSnapshot, id: snapshotId))
        guard hasPermission else {
            throw Abort(.forbidden, reason: "You don't have permission to delete this snapshot")
        }

        let accepted = try await SnapshotArtifactMutation.delete(
            snapshot, actor: .user(try user.requireID()),
            idempotencyContext: req.idempotencyContext,
            idempotencyResponseBody: { @Sendable snapshot, accepted, _ in
                try AcceptedMutation(SnapshotResponse(from: snapshot), accepted).encodedBody()
            },
            on: req.db, app: req.application)

        req.logger.info(
            "Volume snapshot deletion requested",
            metadata: [
                "snapshotId": .string(snapshotId.uuidString),
                "volumeId": .string(volume.id!.uuidString),
            ])

        if let response = accepted.cachedResponse() { return response }
        return try AcceptedMutation(SnapshotResponse(from: snapshot), accepted).acceptedResponse()
    }

    // MARK: - Helper Methods

    /// Resolves the current executor and rings the former one when a Ceph
    /// client failover changes ownership. The new agent is included in the
    /// mutation's post-commit placement dispatch; the old sync removes this
    /// volume from its desired set immediately when it is still connected.
    private func reachableAgentHolding(_ volume: Volume, req: Request) async throws -> String? {
        let resolution = try await VolumeService.resolveAgentHolding(volume, on: req.db)
        if resolution.changed, let previous = resolution.previousAgentID {
            await req.application.agentService.syncDesiredState(agentId: previous)
        }
        return resolution.agentID
    }

    /// Fetch a volume and check permission, mirroring
    /// `fetchVMWithAction`/`fetchSandboxWithAction`.
    private func fetchVolumeWithAction(req: Request, action: String) async throws -> Volume {
        guard let volumeId = req.parameters.get("volumeId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid volume ID")
        }

        return try await req.authorizedVolume(volumeId, action: action)
    }
}
