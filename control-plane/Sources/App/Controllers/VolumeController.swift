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
    /// Query params: project_id (optional), status (optional)
    @Sendable
    func listVolumes(req: Request) async throws -> [VolumeResponse] {
        let user = try req.auth.require(User.self)

        // Build query
        var query = Volume.query(on: req.db)

        // Filter by project if specified
        if let projectIdString = req.query[String.self, at: "project_id"],
            let projectId = UUID(uuidString: projectIdString)
        {
            // Verify user has access to the project
            let hasAccess = try await req.spicedb.checkPermission(
                subject: user.id!.uuidString,
                permission: "read",
                resource: "project",
                resourceId: projectId.uuidString
            )

            guard hasAccess else {
                throw Abort(.forbidden, reason: "You don't have access to this project")
            }

            query = query.filter(\.$project.$id == projectId)
        } else {
            // Get all projects user has access to and filter
            let accessibleProjects = try await getAccessibleProjects(for: user, on: req)
            query = query.filter(\.$project.$id ~~ accessibleProjects)
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

        let volumes =
            try await query
            .sort(\.$createdAt, .descending)
            .all()

        return volumes.map { VolumeResponse(from: $0) }
    }

    // MARK: - Create Volume

    /// Create a new volume
    /// POST /api/volumes
    @Sendable
    func createVolume(req: Request) async throws -> VolumeResponse {
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
        let hasPermission = try await req.spicedb.checkPermission(
            subject: user.id!.uuidString,
            permission: "create_volume",
            resource: "project",
            resourceId: projectId.uuidString
        )

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
            guard image.status == .ready else {
                throw Abort(.badRequest, reason: "Source image is not ready (status: '\(image.status.rawValue)')")
            }
            sourceImage = image
        }

        // Calculate size in bytes
        let sizeBytes = Double(request.sizeGB).gbToBytes

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
            sourceImageID: request.sourceImageId
        )

        try await volume.save(on: req.db)

        // Create SpiceDB relationship
        try await req.spicedb.writeRelationship(
            entity: "volume",
            entityId: volume.id!.uuidString,
            relation: "owner",
            subject: "user",
            subjectId: user.id!.uuidString
        )

        try await req.spicedb.writeRelationship(
            entity: "volume",
            entityId: volume.id!.uuidString,
            relation: "project",
            subject: "project",
            subjectId: projectId.uuidString
        )

        // Provision the volume on an agent in the background. The volume stays
        // `.creating` until the agent confirms, then becomes `.available` with
        // its real storage path and hypervisor — or `.error` on failure.
        let volumeService = req.application.volumeService
        let volumeId = volume.id!
        Task {
            await volumeService.provisionVolume(volumeId: volumeId, sourceImage: sourceImage)
        }

        req.logger.info(
            "Volume creation requested",
            metadata: [
                "volumeId": .string(volume.id!.uuidString),
                "name": .string(volume.name),
                "projectId": .string(projectId.uuidString),
                "sizeGB": .stringConvertible(request.sizeGB),
            ])

        return VolumeResponse(from: volume)
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
    func deleteVolume(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let volume = try await fetchVolumeWithPermission(req: req, user: user, permission: "delete")

        // Validate volume can be deleted
        guard volume.canDelete else {
            throw Abort(
                .conflict,
                reason:
                    "Volume cannot be deleted in status '\(volume.status.rawValue)'. "
                    + "Must be 'available', 'error', or 'deleting'"
            )
        }

        // Mark as deleting
        volume.status = .deleting
        try await volume.save(on: req.db)

        // Delete the backing storage on the agent first; database records are
        // only removed once the hypervisor confirms (deleting the volume
        // directory also removes its snapshot files). Volumes that were never
        // provisioned on an agent are deleted from the database directly.
        do {
            try await req.application.volumeService.requestVolumeDeletion(volume: volume)
        } catch {
            volume.status = .error
            volume.errorMessage = "Failed to delete volume on hypervisor: \(error.localizedDescription)"
            try await volume.save(on: req.db)
            throw Abort(.badGateway, reason: "Failed to delete volume on hypervisor: \(error.localizedDescription)")
        }

        // Delete any snapshots first
        let snapshots = try await VolumeSnapshot.query(on: req.db)
            .filter(\.$volume.$id == volume.id!)
            .all()

        for snapshot in snapshots {
            // Delete SpiceDB relationship
            try await req.spicedb.deleteRelationship(
                entity: "volume_snapshot",
                entityId: snapshot.id!.uuidString,
                relation: "volume",
                subject: "volume",
                subjectId: volume.id!.uuidString
            )
            try await snapshot.delete(on: req.db)
        }

        // Delete SpiceDB relationships
        try await req.spicedb.deleteRelationship(
            entity: "volume",
            entityId: volume.id!.uuidString,
            relation: "owner",
            subject: "user",
            subjectId: volume.$createdBy.id.uuidString
        )

        try await req.spicedb.deleteRelationship(
            entity: "volume",
            entityId: volume.id!.uuidString,
            relation: "project",
            subject: "project",
            subjectId: volume.$project.id.uuidString
        )

        try await volume.delete(on: req.db)

        req.logger.info(
            "Volume deleted",
            metadata: [
                "volumeId": .string(volume.id!.uuidString)
            ])

        return .noContent
    }

    // MARK: - Attach Volume

    /// Attach a volume to a VM
    /// POST /api/volumes/:volumeId/attach
    /// Body: { "vmId": UUID, "deviceName"?: string, "bootOrder"?: int, "readonly"?: bool }
    @Sendable
    func attachVolume(req: Request) async throws -> VolumeResponse {
        let user = try req.auth.require(User.self)
        let volume = try await fetchVolumeWithPermission(req: req, user: user, permission: "attach")
        let request = try req.content.decode(AttachVolumeRequest.self)

        // Validate volume can be attached
        guard volume.canAttach else {
            throw Abort(
                .conflict,
                reason: "Volume cannot be attached in status '\(volume.status.rawValue)'. Must be 'available'")
        }

        // Fetch the VM
        guard let vm = try await VM.find(request.vmId, on: req.db) else {
            throw Abort(.notFound, reason: "VM not found")
        }

        // Check user has permission to the VM (system admins bypass)
        if !user.isSystemAdmin {
            let hasVMPermission = try await req.spicedb.checkPermission(
                subject: user.id!.uuidString,
                permission: "update",
                resource: "virtual_machine",
                resourceId: vm.id!.uuidString
            )

            guard hasVMPermission else {
                throw Abort(.forbidden, reason: "You don't have permission to modify this VM")
            }
        }

        // IMPORTANT: Check that VM is QEMU type - volumes not supported for Firecracker
        guard vm.hypervisorType == .qemu else {
            throw Abort(
                .badRequest,
                reason:
                    "Volume operations are not supported for Firecracker VMs. Firecracker only supports a single root disk."
            )
        }

        // Check that volume and VM are on the same hypervisor (if volume has a hypervisor)
        if let volumeHypervisorId = volume.hypervisorId,
            let vmHypervisorId = vm.hypervisorId,
            volumeHypervisorId != vmHypervisorId
        {
            throw Abort(
                .badRequest,
                reason:
                    "Volume and VM must be on the same hypervisor. Volume is on '\(volumeHypervisorId)', VM is on '\(vmHypervisorId)'"
            )
        }

        // Generate device name if not provided
        let deviceName: String
        if let providedName = request.deviceName {
            deviceName = providedName
        } else {
            deviceName = try await generateDeviceName(for: vm, on: req.db)
        }

        // Mark as attaching. The volume's hypervisorId is set at provisioning
        // and must not be overwritten here — the same-hypervisor check above
        // already guarantees it matches the VM's.
        volume.status = .attaching
        volume.$vm.id = vm.id
        volume.deviceName = deviceName
        volume.bootOrder = request.bootOrder
        try await volume.save(on: req.db)

        // Send hot-plug message to agent
        do {
            try await req.application.volumeService.requestVolumeAttachment(
                volume: volume,
                vm: vm,
                deviceName: deviceName,
                readonly: request.readonly ?? false
            )
        } catch {
            // If hot-plug fails, revert status
            volume.status = .available
            volume.$vm.id = nil
            volume.deviceName = nil
            volume.bootOrder = nil
            try await volume.save(on: req.db)
            throw error
        }

        // Agent confirmed the hot-plug
        volume.status = .attached
        try await volume.save(on: req.db)

        req.logger.info(
            "Volume attached to VM",
            metadata: [
                "volumeId": .string(volume.id!.uuidString),
                "vmId": .string(vm.id!.uuidString),
                "deviceName": .string(deviceName),
            ])

        return VolumeResponse(from: volume)
    }

    // MARK: - Detach Volume

    /// Detach a volume from a VM
    /// POST /api/volumes/:volumeId/detach
    @Sendable
    func detachVolume(req: Request) async throws -> VolumeResponse {
        let user = try req.auth.require(User.self)
        let volume = try await fetchVolumeWithPermission(req: req, user: user, permission: "detach")

        // Validate volume can be detached
        guard volume.canDetach else {
            throw Abort(
                .conflict, reason: "Volume cannot be detached in status '\(volume.status.rawValue)'. Must be 'attached'"
            )
        }

        guard let vmId = volume.$vm.id else {
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

        // Mark as detaching
        volume.status = .detaching
        try await volume.save(on: req.db)

        // Send hot-unplug message to agent
        do {
            try await req.application.volumeService.requestVolumeDetachment(
                volume: volume,
                vm: vm
            )
        } catch {
            // If hot-unplug fails, revert status
            volume.status = .attached
            try await volume.save(on: req.db)
            throw error
        }

        // Agent confirmed the hot-unplug; clear attachment info
        volume.$vm.id = nil
        volume.deviceName = nil
        volume.bootOrder = nil
        volume.status = .available
        try await volume.save(on: req.db)

        req.logger.info(
            "Volume detached from VM",
            metadata: [
                "volumeId": .string(volume.id!.uuidString),
                "previousVmId": .string(vmId.uuidString),
            ])

        return VolumeResponse(from: volume)
    }

    // MARK: - Resize Volume

    /// Resize a volume (increase size only)
    /// POST /api/volumes/:volumeId/resize
    /// Body: { "sizeGB": int }
    @Sendable
    func resizeVolume(req: Request) async throws -> VolumeResponse {
        let user = try req.auth.require(User.self)
        let volume = try await fetchVolumeWithPermission(req: req, user: user, permission: "resize")
        let request = try req.content.decode(ResizeVolumeRequest.self)

        // Validate volume can be resized
        guard volume.canResize else {
            throw Abort(
                .conflict,
                reason: "Volume cannot be resized in status '\(volume.status.rawValue)'. Must be 'available' (detached)"
            )
        }

        // Calculate new size in bytes
        let newSizeBytes = Double(request.sizeGB).gbToBytes

        // Validate new size is larger
        guard newSizeBytes > volume.size else {
            throw Abort(
                .badRequest,
                reason: "New size (\(request.sizeGB) GB) must be larger than current size (\(volume.sizeGB) GB)")
        }

        guard volume.hypervisorId != nil, volume.storagePath != nil else {
            throw Abort(.conflict, reason: "Volume is not provisioned on any hypervisor")
        }

        // Mark as resizing
        let previousSize = volume.size
        volume.status = .resizing
        try await volume.save(on: req.db)

        // Grow the disk on the hypervisor; the database size is only updated
        // once the agent confirms.
        do {
            try await req.application.volumeService.requestVolumeResize(volume: volume, newSizeBytes: newSizeBytes)
        } catch {
            // The agent didn't grow the disk; the volume is unchanged and usable.
            volume.status = .available
            volume.errorMessage = "Resize failed: \(error.localizedDescription)"
            try await volume.save(on: req.db)
            throw Abort(.badGateway, reason: "Failed to resize volume on hypervisor: \(error.localizedDescription)")
        }

        volume.size = newSizeBytes
        volume.status = .available
        volume.errorMessage = nil
        try await volume.save(on: req.db)

        req.logger.info(
            "Volume resized",
            metadata: [
                "volumeId": .string(volume.id!.uuidString),
                "previousSizeGB": .stringConvertible(Double(previousSize) / 1024.0 / 1024.0 / 1024.0),
                "newSizeGB": .stringConvertible(request.sizeGB),
            ])

        return VolumeResponse(from: volume)
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

        // Validate volume can be snapshotted
        guard volume.canSnapshot else {
            throw Abort(
                .conflict,
                reason:
                    "Volume cannot be snapshotted in status '\(volume.status.rawValue)'. Must be 'available' or 'attached'"
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

        try await snapshot.save(on: req.db)

        // Create SpiceDB relationships
        try await req.spicedb.writeRelationship(
            entity: "volume_snapshot",
            entityId: snapshot.id!.uuidString,
            relation: "volume",
            subject: "volume",
            subjectId: volume.id!.uuidString
        )

        try await req.spicedb.writeRelationship(
            entity: "volume_snapshot",
            entityId: snapshot.id!.uuidString,
            relation: "owner",
            subject: "user",
            subjectId: user.id!.uuidString
        )

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
    func cloneVolume(req: Request) async throws -> VolumeResponse {
        let user = try req.auth.require(User.self)
        let sourceVolume = try await fetchVolumeWithPermission(req: req, user: user, permission: "clone")
        let request = try req.content.decode(CloneVolumeRequest.self)

        // Validate source volume can be cloned
        guard sourceVolume.canSnapshot else {
            throw Abort(
                .conflict,
                reason:
                    "Volume cannot be cloned in status '\(sourceVolume.status.rawValue)'. Must be 'available' or 'attached'"
            )
        }

        guard sourceVolume.hypervisorId != nil, sourceVolume.storagePath != nil else {
            throw Abort(.conflict, reason: "Source volume is not provisioned on any hypervisor")
        }

        // Mark source as cloning
        let previousStatus = sourceVolume.status
        sourceVolume.status = .cloning
        try await sourceVolume.save(on: req.db)

        // Create new volume record
        let newVolume = Volume(
            name: request.name,
            description: request.description ?? "Clone of \(sourceVolume.name)",
            projectID: sourceVolume.$project.id,
            size: sourceVolume.size,
            format: sourceVolume.format,
            volumeType: sourceVolume.volumeType,
            status: .creating,
            createdByID: user.id!,
            sourceVolumeID: sourceVolume.id
        )

        try await newVolume.save(on: req.db)

        // Create SpiceDB relationships
        try await req.spicedb.writeRelationship(
            entity: "volume",
            entityId: newVolume.id!.uuidString,
            relation: "owner",
            subject: "user",
            subjectId: user.id!.uuidString
        )

        try await req.spicedb.writeRelationship(
            entity: "volume",
            entityId: newVolume.id!.uuidString,
            relation: "project",
            subject: "project",
            subjectId: sourceVolume.$project.id.uuidString
        )

        // Clone on the agent in the background (copying a disk image can take
        // minutes). The new volume stays `.creating` until the agent confirms,
        // and the source returns to its prior status either way.
        let volumeService = req.application.volumeService
        let sourceVolumeId = sourceVolume.id!
        let targetVolumeId = newVolume.id!
        Task {
            await volumeService.performClone(
                sourceVolumeId: sourceVolumeId,
                targetVolumeId: targetVolumeId,
                restoreSourceStatusTo: previousStatus
            )
        }

        req.logger.info(
            "Volume clone requested",
            metadata: [
                "sourceVolumeId": .string(sourceVolume.id!.uuidString),
                "newVolumeId": .string(newVolume.id!.uuidString),
                "name": .string(newVolume.name),
            ])

        return VolumeResponse(from: newVolume)
    }

    // MARK: - List Snapshots

    /// List all snapshots for a volume
    /// GET /api/volumes/:volumeId/snapshots
    @Sendable
    func listSnapshots(req: Request) async throws -> [SnapshotResponse] {
        let user = try req.auth.require(User.self)
        let volume = try await fetchVolumeWithPermission(req: req, user: user, permission: "read")

        let snapshots = try await VolumeSnapshot.query(on: req.db)
            .filter(\.$volume.$id == volume.id!)
            .sort(\.$createdAt, .descending)
            .all()

        return snapshots.map { SnapshotResponse(from: $0) }
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
        let hasPermission = try await req.spicedb.checkPermission(
            subject: user.id!.uuidString,
            permission: "delete",
            resource: "volume_snapshot",
            resourceId: snapshotId.uuidString
        )

        guard hasPermission else {
            throw Abort(.forbidden, reason: "You don't have permission to delete this snapshot")
        }

        // Validate snapshot can be deleted
        guard snapshot.canDelete else {
            throw Abort(
                .conflict,
                reason:
                    "Snapshot cannot be deleted in status '\(snapshot.status.rawValue)'. Must be 'available' or 'error'"
            )
        }

        // Mark as deleting
        snapshot.status = .deleting
        try await snapshot.save(on: req.db)

        // TODO: Send message to agent to delete the snapshot from storage

        // Delete SpiceDB relationships
        try await req.spicedb.deleteRelationship(
            entity: "volume_snapshot",
            entityId: snapshotId.uuidString,
            relation: "volume",
            subject: "volume",
            subjectId: volume.id!.uuidString
        )

        try await req.spicedb.deleteRelationship(
            entity: "volume_snapshot",
            entityId: snapshotId.uuidString,
            relation: "owner",
            subject: "user",
            subjectId: snapshot.$createdBy.id.uuidString
        )

        try await snapshot.delete(on: req.db)

        req.logger.info(
            "Snapshot deleted",
            metadata: [
                "snapshotId": .string(snapshotId.uuidString),
                "volumeId": .string(volume.id!.uuidString),
            ])

        return .noContent
    }

    // MARK: - Helper Methods

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

        // System admins bypass permission checks
        if user.isSystemAdmin {
            return volume
        }

        // Check SpiceDB permission
        let hasPermission = try await req.spicedb.checkPermission(
            subject: user.id!.uuidString,
            permission: permission,
            resource: "volume",
            resourceId: volumeId.uuidString
        )

        guard hasPermission else {
            throw Abort(.forbidden, reason: "You don't have '\(permission)' permission on this volume")
        }

        return volume
    }

    /// Get all project IDs the user has access to
    private func getAccessibleProjects(for user: User, on req: Request) async throws -> [UUID] {
        // Get all projects and check access
        let allProjects = try await Project.query(on: req.db).all()
        var accessibleProjectIds: [UUID] = []

        for project in allProjects {
            let hasAccess = try await req.spicedb.checkPermission(
                subject: user.id!.uuidString,
                permission: "read",
                resource: "project",
                resourceId: project.id!.uuidString
            )
            if hasAccess {
                accessibleProjectIds.append(project.id!)
            }
        }

        return accessibleProjectIds
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
