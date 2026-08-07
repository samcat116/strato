import Fluent
import Vapor
import StratoShared

struct VolumeController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let volumes = routes.grouped("api", "volumes")

        // All routes require authentication
        let protected = volumes.grouped(User.guardMiddleware())

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
        protected.post(":volumeId", "snapshot", use: createSnapshot)
        protected.post(":volumeId", "clone", use: cloneVolume)

        // Snapshot operations
        protected.get(":volumeId", "snapshots", use: listSnapshots)
        protected.delete(":volumeId", "snapshots", ":snapshotId", use: deleteSnapshot)
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
            let hasAccess = try await req.can("view_project", on: "project", id: projectId.uuidString)

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

        return volumes.map { VolumeResponse(from: $0) }
    }

    // MARK: - Create Volume

    /// Create a new volume
    /// POST /api/volumes
    @Sendable
    func createVolume(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let request = try req.content.decode(CreateVolumeRequest.self)

        // Determine project
        let projectId: UUID
        if let requestProjectId = request.projectId {
            projectId = requestProjectId
        } else if let currentOrgId = user.currentOrganizationId {
            // Get default project for user's current organization
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

        // Check permission to create volumes in this project
        let hasPermission = try await req.can("create_volume", on: "project", id: projectId.uuidString)

        guard hasPermission else {
            throw Abort(.forbidden, reason: "You don't have permission to create volumes in this project")
        }

        // Validate format and volume type
        let format = try VolumeNaming.parseFormat(request.format)
        let volumeType = try VolumeNaming.parseVolumeType(request.volumeType)

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
            let hasImagePermission = try await req.can("read", on: "image", id: sourceImageId.uuidString)

            guard hasImagePermission else {
                throw Abort(.forbidden, reason: "Access denied to image")
            }

            guard image.status == .ready else {
                throw Abort(.badRequest, reason: "Source image is not ready (status: '\(image.status.rawValue)')")
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
                reason: "'sizeGB' exceeds the maximum volume size of \(Volume.maxSizeGB) GB")
        }
        guard let sizeBytes = request.sizeGB.gbToBytes else {
            throw Abort(.badRequest, reason: "'sizeGB' is too large")
        }

        // Every volume lives in a pool; without a pool-selection API yet,
        // that's the default local pool seeded by migration.
        let pool = try await StoragePool.defaultPool(on: req.db)

        // Create volume record
        let volume = Volume(
            name: request.name,
            description: request.description ?? "",
            projectID: projectId,
            size: sizeBytes,
            format: format,
            volumeType: volumeType,
            status: .creating,
            createdByID: user.id!,
            poolID: pool.id,
            sourceImageID: request.sourceImageId
        )

        let app = req.application
        let userID = try user.requireID()
        // Bind to a `let` so the `@Sendable` dispatch closure captures an
        // immutable copy rather than the mutable `sourceImage` var.
        let poolMemberIds = pool.memberAgentIds

        // How long the create has to converge before the stuck-convergence
        // sweep marks the volume degraded, stamped with the insert so a
        // control-plane crash between here and placement still leaves a
        // resource the sweep can judge.
        volume.extendConvergenceDeadline(
            by: OperationResourceKind.volume.completionBudgetSeconds(for: .create))
        volume.setDesiredStatus(.present)

        // The creator's explicit, revocable binding on the volume, in the same
        // transaction as the row (issue #477).
        try await req.db.transaction { db in
            try await volume.save(on: db)
            try await RoleBindingService.grant(
                principalType: .user,
                principalID: user.id!,
                role: .admin,
                nodeType: .volume,
                nodeID: volume.id!,
                createdBy: user.id,
                on: db
            )
        }

        let volumeId = try volume.requireID()

        // Placement is a `.placement` dispatch rather than something resolved
        // in-band, and it has to *commit* before the sync can carry the volume:
        // `DesiredStateAssembler` finds a volume by its `hypervisorId`, so an
        // unplaced one is in nobody's desired state. On throw, `dispatch`
        // degrades the volume with the reason.
        let accepted = try await req.resourceMutation.accept(
            .create, on: volume, actor: .user(userID),
            dispatch: .placement { @Sendable db in
                let agents = await app.agentService.getAgentList()
                guard
                    let agent = VolumeService.selectVolumeAgent(
                        from: agents, memberAgentIds: poolMemberIds),
                    let agentId = agent.id?.uuidString
                else {
                    throw ResourceMutation.WorkError(
                        "No agent available to host this volume: it needs an online, QEMU-capable "
                            + "agent in the volume's pool speaking wire protocol "
                            + "\(WireProtocol.volumeSyncMinimumVersion) or later.")
                }
                guard let placed = try await Volume.find(volumeId, on: db) else { return }
                placed.hypervisorId = agentId
                try await placed.save(on: db)
                try await VolumeReplica(
                    volumeID: volumeId, agentId: agentId, state: .provisioning
                ).create(on: db)
                await app.agentService.syncDesiredState(agentId: agentId)
            },
            on: req.db, app: app)

        req.logger.info(
            "Volume creation requested",
            metadata: [
                "volumeId": .string(volumeId.uuidString),
                "name": .string(volume.name),
                "projectId": .string(projectId.uuidString),
                "sizeGB": .stringConvertible(request.sizeGB),
                "sourceImageId": .string(sourceImage?.id?.uuidString ?? ""),
            ])

        return try AcceptedMutation(VolumeResponse(from: volume), accepted).acceptedResponse()
    }

    // MARK: - Get Volume

    /// Get a specific volume by ID
    /// GET /api/volumes/:volumeId
    @Sendable
    func getVolume(req: Request) async throws -> VolumeResponse {
        let user = try req.auth.require(User.self)
        let volume = try await fetchVolumeWithPermission(req: req, user: user, permission: "read")
        return VolumeResponse(from: volume)
    }

    // MARK: - Update Volume

    /// Update a volume's metadata
    /// PUT /api/volumes/:volumeId
    @Sendable
    func updateVolume(req: Request) async throws -> VolumeResponse {
        let user = try req.auth.require(User.self)
        let volume = try await fetchVolumeWithPermission(req: req, user: user, permission: "update")
        let request = try req.content.decode(UpdateVolumeRequest.self)

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

        return VolumeResponse(from: volume)
    }

    // MARK: - Delete Volume

    /// Delete a volume
    /// DELETE /api/volumes/:volumeId
    @Sendable
    func deleteVolume(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let volume = try await fetchVolumeWithPermission(req: req, user: user, permission: "delete")

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
        // Unplaced, or placed on an agent that is offline or too old to speak
        // volume sync: nothing will ever confirm the teardown, so clear the
        // agent's finalizer here. Dead and un-upgraded agents must not make
        // their volumes undeletable — and an agent below wire v30 is
        // permanently in the second category until it is upgraded, which is the
        // one place the hard cutover leaves a rough edge worth naming.
        let agentCanConverge = await Self.agentConvergesVolumes(volume.hypervisorId, app: app)
        let strategy: ResourceMutation.Dispatch =
            agentCanConverge
            ? .stateSync
            : .directResolution { @Sendable db in
                if volume.hypervisorId != nil {
                    app.logger.warning(
                        "Deleting volume record without agent teardown; its agent cannot converge volumes",
                        metadata: ["volumeId": .string(volumeID.uuidString)])
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
                return outcome.isRemoved
            }

        let accepted = try await req.resourceMutation.accept(
            .delete, on: volume, actor: .user(userID), dispatch: strategy,
            on: req.db, app: app
        ) { @Sendable _ in
            // Stamp before the mark: `stampForDeletion` reads whether the
            // volume is already terminating, and re-stamping a second DELETE
            // would resurrect tokens their participants have already cleared.
            ResourceFinalizerService.stampForDeletion(volume)
            volume.setDesiredStatus(.absent)
        }

        req.logger.info(
            "Volume deletion requested",
            metadata: ["volumeId": .string(volumeID.uuidString)])

        return try AcceptedMutation(VolumeResponse(from: volume), accepted).acceptedResponse()
    }

    // MARK: - Attach Volume

    /// Attach a volume to a VM
    /// POST /api/volumes/:volumeId/attach
    /// Body: { "vmId": UUID, "deviceName"?: string, "bootOrder"?: int, "readonly"?: bool }
    @Sendable
    func attachVolume(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let volume = try await fetchVolumeWithPermission(req: req, user: user, permission: "attach")
        let request = try req.content.decode(AttachVolumeRequest.self)

        guard volume.canAttach else {
            throw Abort(
                .conflict,
                reason: "Volume is already attached to a VM. Detach it first.")
        }

        // Attaching changes the VM, so the caller needs update on it too. An
        // unreachable VM is answered as absent whether it is missing or merely
        // forbidden — see `reachableVM` (issue #881).
        let vm = try await req.reachableVM(request.vmId, permission: "update")

        // Permission on both sides isn't enough: a caller holding rights in two
        // projects could otherwise move a volume's data across the project
        // boundary, leaving quota attributed to one project and the consuming
        // workload in another. Same containment rule as VM create applies to
        // networks and security groups (issue #766), answered the same way at
        // every site (issue #777).
        try ProjectContainment.require(
            "Volume", in: volume.$project.id,
            sameProjectAs: "the VM", in: vm.$project.id)

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
        if let vmHypervisorId = vm.hypervisorId {
            let pool = try await volume.$pool.get(on: req.db)
            var replicaAgentIds = try await VolumeReplica.query(on: req.db)
                .filter(\.$volume.$id == volume.id!)
                .all()
                .map(\.agentId)
            // Rows without a replica (mid-provisioning races) still carry the
            // dual-written legacy column.
            if replicaAgentIds.isEmpty, let legacyAgentId = volume.hypervisorId {
                replicaAgentIds = [legacyAgentId]
            }

            guard
                StoragePool.agentCanReach(
                    agentId: vmHypervisorId, pool: pool, replicaAgentIds: replicaAgentIds)
            else {
                throw Abort(
                    .badRequest,
                    reason:
                        "Volume is not reachable from the VM's agent. Volume is on '\(replicaAgentIds.joined(separator: ", "))', VM is on '\(vmHypervisorId)'"
                )
            }
        }

        try await Self.requireVolumeSyncCapableAgent(volume.hypervisorId, app: req.application)

        // Generate device name if not provided
        let deviceName: String
        if let providedName = request.deviceName {
            deviceName = providedName
        } else {
            deviceName = try await generateDeviceName(for: vm, on: req.db)
        }

        let userID = try user.requireID()
        let readonly = request.readonly ?? false
        let bootOrder = request.bootOrder
        let vmID = try vm.requireID()
        let vmAgentId = vm.hypervisorId

        let accepted = try await req.resourceMutation.accept(
            .attach, on: volume, actor: .user(userID), dispatch: .stateSync,
            on: req.db, app: req.application
        ) { @Sendable _ in
            // The desired attachment, and nothing else. There is no
            // `.attaching` status to set and revert: the agent reports what it
            // realized, and `conditions` is what a client watches.
            volume.$vm.id = vmID
            volume.deviceName = deviceName
            volume.bootOrder = bootOrder
            volume.readonly = readonly
            volume.attachedAgentId = vmAgentId
            volume.bumpGeneration()
        }

        req.logger.info(
            "Volume attachment requested",
            metadata: [
                "volumeId": .string(volume.id!.uuidString),
                "vmId": .string(vmID.uuidString),
                "deviceName": .string(deviceName),
            ])

        return try AcceptedMutation(VolumeResponse(from: volume), accepted).acceptedResponse()
    }

    // MARK: - Detach Volume

    /// Detach a volume from a VM
    /// POST /api/volumes/:volumeId/detach
    @Sendable
    func detachVolume(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let volume = try await fetchVolumeWithPermission(req: req, user: user, permission: "detach")

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

        try await Self.requireVolumeSyncCapableAgent(volume.hypervisorId, app: req.application)

        let userID = try user.requireID()
        let accepted = try await req.resourceMutation.accept(
            .detach, on: volume, actor: .user(userID), dispatch: .stateSync,
            on: req.db, app: req.application
        ) { @Sendable _ in
            volume.$vm.id = nil
            volume.deviceName = nil
            volume.bootOrder = nil
            volume.readonly = false
            volume.attachedAgentId = nil
            volume.bumpGeneration()
        }

        req.logger.info(
            "Volume detachment requested",
            metadata: [
                "volumeId": .string(volume.id!.uuidString),
                "previousVmId": .string(vmId.uuidString),
            ])

        return try AcceptedMutation(VolumeResponse(from: volume), accepted).acceptedResponse()
    }

    // MARK: - Resize Volume

    /// Resize a volume (increase size only)
    /// POST /api/volumes/:volumeId/resize
    /// Body: { "sizeGB": int }
    @Sendable
    func resizeVolume(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let volume = try await fetchVolumeWithPermission(req: req, user: user, permission: "resize")
        let request = try req.content.decode(ResizeVolumeRequest.self)

        // Offline resize only: growing a disk under a running guest needs the
        // guest to notice, which nothing here arranges.
        guard volume.canResize else {
            throw Abort(
                .conflict,
                reason: "Volume is attached to a VM and cannot be resized. Detach it first.")
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
                reason: "'sizeGB' exceeds the maximum volume size of \(Volume.maxSizeGB) GB")
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

        guard volume.hypervisorId != nil else {
            throw Abort(.conflict, reason: "Volume is not provisioned on any hypervisor")
        }
        try await Self.requireVolumeSyncCapableAgent(volume.hypervisorId, app: req.application)

        let previousSize = volume.size
        let userID = try user.requireID()
        let accepted = try await req.resourceMutation.accept(
            .resize, on: volume, actor: .user(userID), dispatch: .stateSync,
            on: req.db, app: req.application
        ) { @Sendable _ in
            // The size on the row is the *desired* size from here on. The agent
            // grows the disk and confirms by generation, which is what makes a
            // resize whose sync was dropped simply happen on the next one.
            volume.size = newSizeBytes
            volume.bumpGeneration()
        }

        req.logger.info(
            "Volume resize requested",
            metadata: [
                "volumeId": .string(volume.id!.uuidString),
                "previousSizeGB": .stringConvertible(Double(previousSize) / 1024.0 / 1024.0 / 1024.0),
                "newSizeGB": .stringConvertible(request.sizeGB),
            ])

        return try AcceptedMutation(VolumeResponse(from: volume), accepted).acceptedResponse()
    }

    // MARK: - Create Snapshot

    /// Create a snapshot of a volume
    /// POST /api/volumes/:volumeId/snapshot
    /// Body: { "name": string, "description"?: string }
    @Sendable
    func createSnapshot(req: Request) async throws -> SnapshotResponse {
        let user = try req.auth.require(User.self)
        let volume = try await fetchVolumeWithPermission(req: req, user: user, permission: "snapshot")
        let request = try req.content.decode(CreateSnapshotRequest.self)

        // Validate volume can be snapshotted. An attached volume gets its own
        // message: refusing it is a deliberate correctness guard (issue #747),
        // not a transient state the caller should wait out.
        guard volume.canSnapshot else {
            if volume.status == .attached {
                throw Abort(
                    .conflict,
                    reason:
                        "Volume is attached to a running VM. Snapshots of an attached volume would not be point-in-time, so they are refused; detach the volume first."
                )
            }
            throw Abort(
                .conflict,
                reason: "Volume cannot be snapshotted in status '\(volume.status.rawValue)'. Must be 'available'"
            )
        }

        guard volume.hypervisorId != nil, volume.storagePath != nil else {
            throw Abort(.conflict, reason: "Volume is not provisioned on any hypervisor")
        }

        // Mark volume as snapshotting
        let previousStatus = volume.status
        volume.status = .snapshotting
        try await volume.save(on: req.db)

        // Create snapshot record
        let snapshot = VolumeSnapshot(
            name: request.name,
            description: request.description ?? "",
            volumeID: volume.id!,
            projectID: volume.$project.id,
            size: volume.size,
            status: .creating,
            createdByID: user.id!
        )

        // Creator binding on the snapshot, in the same transaction as the row
        // (issue #477).
        try await req.db.transaction { db in
            try await snapshot.save(on: db)
            try await RoleBindingService.grant(
                principalType: .user,
                principalID: user.id!,
                role: .admin,
                nodeType: .volumeSnapshot,
                nodeID: snapshot.id!,
                createdBy: user.id,
                on: db
            )
        }

        // Create the snapshot on the hypervisor; the agent reports the actual
        // snapshot storage path.
        do {
            let snapshotPath = try await req.application.volumeService.requestVolumeSnapshot(
                volume: volume,
                snapshot: snapshot
            )
            snapshot.storagePath = snapshotPath
            snapshot.status = .available
            try await snapshot.save(on: req.db)
        } catch {
            snapshot.status = .error
            snapshot.errorMessage = error.localizedDescription
            try await snapshot.save(on: req.db)
            volume.status = previousStatus
            try await volume.save(on: req.db)
            throw Abort(.badGateway, reason: "Failed to create snapshot on hypervisor: \(error.localizedDescription)")
        }

        // Restore volume status
        volume.status = previousStatus
        try await volume.save(on: req.db)

        req.logger.info(
            "Snapshot created",
            metadata: [
                "snapshotId": .string(snapshot.id!.uuidString),
                "volumeId": .string(volume.id!.uuidString),
                "name": .string(snapshot.name),
            ])

        return SnapshotResponse(from: snapshot)
    }

    // MARK: - Clone Volume

    /// Clone a volume
    /// POST /api/volumes/:volumeId/clone
    /// Body: { "name": string, "description"?: string }
    @Sendable
    func cloneVolume(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let sourceVolume = try await fetchVolumeWithPermission(req: req, user: user, permission: "clone")
        let request = try req.content.decode(CloneVolumeRequest.self)

        // Cloning reads the source's bytes, which is why it keeps a
        // converged-and-detached requirement the other verbs dropped: copying a
        // volume whose own create is still writing it yields a torn image, and
        // unlike a resize that cannot be re-driven into correctness.
        guard sourceVolume.canClone else {
            if sourceVolume.$vm.id != nil {
                throw Abort(
                    .conflict,
                    reason:
                        "Volume is attached to a VM. Cloning copies the volume's file, so a guest writing it mid-copy would produce a torn image; detach the volume first."
                )
            }
            throw Abort(
                .conflict,
                reason: "Volume is not ready to be cloned; wait for it to finish converging."
            )
        }

        guard let sourceAgentId = sourceVolume.hypervisorId else {
            throw Abort(.conflict, reason: "Source volume is not provisioned on any hypervisor")
        }
        try await Self.requireVolumeSyncCapableAgent(sourceAgentId, app: req.application)

        // The clone is materialized on the source's agent — a clone reads the
        // source's file, so the two must be co-located — and therefore lives in
        // the source's pool and is placed at create time rather than scheduled.
        let newVolume = Volume(
            name: request.name,
            description: request.description ?? "Clone of \(sourceVolume.name)",
            projectID: sourceVolume.$project.id,
            size: sourceVolume.size,
            format: sourceVolume.format,
            volumeType: sourceVolume.volumeType,
            status: .creating,
            createdByID: user.id!,
            poolID: sourceVolume.$pool.id,
            sourceVolumeID: sourceVolume.id
        )
        newVolume.hypervisorId = sourceAgentId
        newVolume.extendConvergenceDeadline(
            by: OperationResourceKind.volume.completionBudgetSeconds(for: .create))
        newVolume.setDesiredStatus(.present)

        // Creator binding on the cloned volume, in the same transaction as
        // the row (issue #477).
        try await req.db.transaction { db in
            try await newVolume.save(on: db)
            try await RoleBindingService.grant(
                principalType: .user,
                principalID: user.id!,
                role: .admin,
                nodeType: .volume,
                nodeID: newVolume.id!,
                createdBy: user.id,
                on: db
            )
        }

        // The clone is a create *strategy* on the new volume's desired entry,
        // not an operation on the source (ADR 0001 stage 5). The source is
        // therefore never marked busy and never has to be restored afterwards —
        // it is simply read, by an agent that already holds it.
        let newVolumeID = try newVolume.requireID()
        let userID = try user.requireID()
        let app = req.application
        let accepted = try await req.resourceMutation.accept(
            .create, on: newVolume, actor: .user(userID),
            dispatch: .placement { @Sendable db in
                try await VolumeReplica(
                    volumeID: newVolumeID, agentId: sourceAgentId, state: .provisioning
                ).create(on: db)
                await app.agentService.syncDesiredState(agentId: sourceAgentId)
            },
            on: req.db, app: app)

        req.logger.info(
            "Volume clone requested",
            metadata: [
                "sourceVolumeId": .string(sourceVolume.id!.uuidString),
                "newVolumeId": .string(newVolumeID.uuidString),
                "name": .string(newVolume.name),
            ])

        return try AcceptedMutation(VolumeResponse(from: newVolume), accepted).acceptedResponse()
    }

    // MARK: - List Snapshots

    /// List all snapshots for a volume
    /// GET /api/volumes/:volumeId/snapshots
    /// Query params: limit/offset (optional) — select the page.
    @Sendable
    func listSnapshots(req: Request) async throws -> PagedResponse<SnapshotResponse> {
        let paging = try ListPaging.decode(from: req)
        let user = try req.auth.require(User.self)
        let volume = try await fetchVolumeWithPermission(req: req, user: user, permission: "read")

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
    @Sendable
    func deleteSnapshot(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let volume = try await fetchVolumeWithPermission(req: req, user: user, permission: "read")

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

        // Check permission to delete snapshot
        let hasPermission = try await req.can("delete", on: "volume_snapshot", id: snapshotId.uuidString)

        guard hasPermission else {
            throw Abort(.forbidden, reason: "You don't have permission to delete this snapshot")
        }

        // Validate snapshot can be deleted
        guard snapshot.canDelete else {
            throw Abort(
                .conflict,
                reason:
                    "Snapshot cannot be deleted in status '\(snapshot.status.rawValue)'. Must be 'available', 'error', or 'deleting'"
            )
        }

        // Mark as deleting
        snapshot.status = .deleting
        try await snapshot.save(on: req.db)

        // Delete the snapshot file on the hypervisor first; the database
        // record is only removed once the agent confirms. Only snapshots of
        // volumes that were never provisioned on a hypervisor skip the agent
        // round-trip.
        do {
            try await req.application.volumeService.requestVolumeSnapshotDeletion(
                volume: volume,
                snapshot: snapshot
            )
        } catch {
            snapshot.status = .error
            snapshot.errorMessage = "Failed to delete snapshot on hypervisor: \(error.localizedDescription)"
            try await snapshot.save(on: req.db)
            throw Abort(.badGateway, reason: "Failed to delete snapshot on hypervisor: \(error.localizedDescription)")
        }

        try await req.db.transaction { db in
            try await snapshot.delete(on: db)
            // Drop the snapshot's bindings with the row.
            try await RoleBindingService.revokeAll(
                nodeType: .volumeSnapshot, nodeID: snapshotId, on: db)
        }

        req.logger.info(
            "Snapshot deleted",
            metadata: [
                "snapshotId": .string(snapshotId.uuidString),
                "volumeId": .string(volume.id!.uuidString),
            ])

        return .noContent
    }

    // MARK: - Helper Methods

    /// Whether the agent holding a volume can actually converge it: online, and
    /// speaking wire v30 or later (STR-148).
    ///
    /// With the imperative volume frames gone there is no fallback path, so an
    /// agent below v30 cannot hear about a volume at all. `selectVolumeAgent`
    /// keeps new volumes off such agents; this answers the same question for
    /// volumes that were already there when the control plane was upgraded.
    private static func agentConvergesVolumes(_ agentId: String?, app: Application) async -> Bool {
        guard let agentId, await app.agentService.agentIsOnline(agentId: agentId) else { return false }
        guard let agentUUID = UUID(uuidString: agentId),
            let agent = try? await Agent.find(agentUUID, on: app.db)
        else { return false }
        return WireProtocol.supportsVolumeSync(agent.wireProtocolVersion ?? 0)
    }

    /// Refuses a mutation whose volume sits on an agent that cannot converge
    /// it, at accept time.
    ///
    /// Deliberately *not* applied to delete, which must keep working against a
    /// stranded volume by force-clearing its finalizer — otherwise upgrading
    /// the control plane before the fleet would make those volumes permanently
    /// undeletable. An offline agent is allowed through here: it is expected to
    /// come back and converge, which is the whole point of level-triggering.
    private static func requireVolumeSyncCapableAgent(_ agentId: String?, app: Application) async throws {
        guard let agentId, let agentUUID = UUID(uuidString: agentId),
            let agent = try? await Agent.find(agentUUID, on: app.db)
        else { return }
        guard WireProtocol.supportsVolumeSync(agent.wireProtocolVersion ?? 0) else {
            throw Abort(
                .conflict,
                reason:
                    "Agent '\(agent.name)' speaks wire protocol \(agent.wireProtocolVersion ?? 0) and cannot "
                    + "manage volumes; upgrade it to an agent speaking "
                    + "\(WireProtocol.volumeSyncMinimumVersion) or later and retry."
            )
        }
    }

    /// Fetch a volume and check permission
    private func fetchVolumeWithPermission(req: Request, user: User, permission: String) async throws -> Volume {
        guard let volumeIdString = req.parameters.get("volumeId"),
            let volumeId = UUID(uuidString: volumeIdString)
        else {
            throw Abort(.badRequest, reason: "Invalid volume ID")
        }

        guard let volume = try await Volume.find(volumeId, on: req.db) else {
            throw Abort(.notFound, reason: "Volume not found")
        }

        let hasPermission = try await req.can(permission, on: "volume", id: volumeId.uuidString)

        guard hasPermission else {
            throw Abort(.forbidden, reason: "You don't have '\(permission)' permission on this volume")
        }

        return volume
    }

    /// Generate a device name for a new volume attachment
    private func generateDeviceName(for vm: VM, on db: Database) async throws -> String {
        // Get existing volumes attached to this VM
        let attachedVolumes = try await Volume.query(on: db)
            .filter(\.$vm.$id == vm.id!)
            .all()

        return VolumeNaming.nextDeviceName(existingDeviceNames: attachedVolumes.map { $0.deviceName })
    }
}
