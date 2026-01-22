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
           let projectId = UUID(uuidString: projectIdString) {
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
           let status = VolumeStatus(rawValue: statusString) {
            query = query.filter(\.$status == status)
        }

        // Filter by volume type if specified
        if let typeString = req.query[String.self, at: "type"],
           let volumeType = VolumeType(rawValue: typeString) {
            query = query.filter(\.$volumeType == volumeType)
        }

        let volumes = try await query
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
            guard let defaultProject = try await Project.query(on: req.db)
                .filter(\.$organization.$id == currentOrgId)
                .first() else {
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

        // Validate format
        let format: VolumeFormat
        if let formatString = request.format {
            guard let parsedFormat = VolumeFormat(rawValue: formatString) else {
                throw Abort(.badRequest, reason: "Invalid format '\(formatString)'. Must be 'qcow2' or 'raw'")
            }
            format = parsedFormat
        } else {
            format = .qcow2  // Default
        }

        // Validate volume type
        let volumeType: VolumeType
        if let typeString = request.volumeType {
            guard let parsedType = VolumeType(rawValue: typeString) else {
                throw Abort(.badRequest, reason: "Invalid volume type '\(typeString)'. Must be 'boot' or 'data'")
            }
            volumeType = parsedType
        } else {
            volumeType = .data  // Default
        }

        // Calculate size in bytes
        let sizeBytes = Int64(request.sizeGB) * 1024 * 1024 * 1024

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

        // TODO: Send message to an agent to actually create the volume
        // For now, mark as available (would be done by agent callback)
        volume.status = .available
        try await volume.save(on: req.db)

        req.logger.info("Volume created", metadata: [
            "volumeId": .string(volume.id!.uuidString),
            "name": .string(volume.name),
            "projectId": .string(projectId.uuidString),
            "sizeGB": .stringConvertible(request.sizeGB)
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

        req.logger.info("Volume updated", metadata: [
            "volumeId": .string(volume.id!.uuidString),
            "name": .string(volume.name)
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
            throw Abort(.conflict, reason: "Volume cannot be deleted in status '\(volume.status.rawValue)'. Must be 'available' or 'error'")
        }

        // Mark as deleting
        volume.status = .deleting
        try await volume.save(on: req.db)

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

        // TODO: Send message to agent to delete the volume from storage
        // For now, delete directly

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

        req.logger.info("Volume deleted", metadata: [
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
            throw Abort(.conflict, reason: "Volume cannot be attached in status '\(volume.status.rawValue)'. Must be 'available'")
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
            throw Abort(.badRequest, reason: "Volume operations are not supported for Firecracker VMs. Firecracker only supports a single root disk.")
        }

        // Check that volume and VM are on the same hypervisor (if volume has a hypervisor)
        if let volumeHypervisorId = volume.hypervisorId,
           let vmHypervisorId = vm.hypervisorId,
           volumeHypervisorId != vmHypervisorId {
            throw Abort(.badRequest, reason: "Volume and VM must be on the same hypervisor. Volume is on '\(volumeHypervisorId)', VM is on '\(vmHypervisorId)'")
        }

        // Generate device name if not provided
        let deviceName: String
        if let providedName = request.deviceName {
            deviceName = providedName
        } else {
            deviceName = try await generateDeviceName(for: vm, on: req.db)
        }

        // Mark as attaching
        volume.status = .attaching
        volume.$vm.id = vm.id
        volume.deviceName = deviceName
        volume.bootOrder = request.bootOrder
        volume.hypervisorId = vm.hypervisorId
        try await volume.save(on: req.db)

        // If volume doesn't have a storage path, generate one based on where VM disks are stored
        // In production this would be set when the volume is created on an agent
        if volume.storagePath == nil {
            // Use the VM's hypervisorId and volume ID to construct a path
            // This assumes volumes are stored alongside VMs
            volume.storagePath = "/tmp/strato-test/volumes/\(volume.id!.uuidString)/volume.qcow2"
            try await volume.save(on: req.db)
        }

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

        // Mark as attached (in production this would be done by agent callback)
        volume.status = .attached
        try await volume.save(on: req.db)

        req.logger.info("Volume attached to VM", metadata: [
            "volumeId": .string(volume.id!.uuidString),
            "vmId": .string(vm.id!.uuidString),
            "deviceName": .string(deviceName)
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
            throw Abort(.conflict, reason: "Volume cannot be detached in status '\(volume.status.rawValue)'. Must be 'attached'")
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
            throw Abort(.badRequest, reason: "Volume operations are not supported for Firecracker VMs. Firecracker only supports a single root disk.")
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

        // Clear attachment info (in production this would be done by agent callback)
        volume.$vm.id = nil
        volume.deviceName = nil
        volume.bootOrder = nil
        volume.status = .available
        try await volume.save(on: req.db)

        req.logger.info("Volume detached from VM", metadata: [
            "volumeId": .string(volume.id!.uuidString),
            "previousVmId": .string(vmId.uuidString)
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
            throw Abort(.conflict, reason: "Volume cannot be resized in status '\(volume.status.rawValue)'. Must be 'available' (detached)")
        }

        // Calculate new size in bytes
        let newSizeBytes = Int64(request.sizeGB) * 1024 * 1024 * 1024

        // Validate new size is larger
        guard newSizeBytes > volume.size else {
            throw Abort(.badRequest, reason: "New size (\(request.sizeGB) GB) must be larger than current size (\(volume.sizeGB) GB)")
        }

        // Mark as resizing
        let previousSize = volume.size
        volume.status = .resizing
        try await volume.save(on: req.db)

        // TODO: Send message to agent to resize the volume
        // For now, update directly
        volume.size = newSizeBytes
        volume.status = .available
        try await volume.save(on: req.db)

        req.logger.info("Volume resized", metadata: [
            "volumeId": .string(volume.id!.uuidString),
            "previousSizeGB": .stringConvertible(Double(previousSize) / 1024.0 / 1024.0 / 1024.0),
            "newSizeGB": .stringConvertible(request.sizeGB)
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
            throw Abort(.conflict, reason: "Volume cannot be snapshotted in status '\(volume.status.rawValue)'. Must be 'available' or 'attached'")
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

        // TODO: Send message to agent to create the snapshot
        // For now, mark as available directly
        snapshot.status = .available
        try await snapshot.save(on: req.db)

        // Restore volume status
        volume.status = previousStatus
        try await volume.save(on: req.db)

        req.logger.info("Snapshot created", metadata: [
            "snapshotId": .string(snapshot.id!.uuidString),
            "volumeId": .string(volume.id!.uuidString),
            "name": .string(snapshot.name)
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
            throw Abort(.conflict, reason: "Volume cannot be cloned in status '\(sourceVolume.status.rawValue)'. Must be 'available' or 'attached'")
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

        // TODO: Send message to agent to clone the volume
        // For now, mark as available directly
        newVolume.status = .available
        try await newVolume.save(on: req.db)

        // Restore source volume status
        sourceVolume.status = previousStatus
        try await sourceVolume.save(on: req.db)

        req.logger.info("Volume cloned", metadata: [
            "sourceVolumeId": .string(sourceVolume.id!.uuidString),
            "newVolumeId": .string(newVolume.id!.uuidString),
            "name": .string(newVolume.name)
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
              let snapshotId = UUID(uuidString: snapshotIdString) else {
            throw Abort(.badRequest, reason: "Invalid snapshot ID")
        }

        guard let snapshot = try await VolumeSnapshot.query(on: req.db)
            .filter(\.$id == snapshotId)
            .filter(\.$volume.$id == volume.id!)
            .first() else {
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
            throw Abort(.conflict, reason: "Snapshot cannot be deleted in status '\(snapshot.status.rawValue)'. Must be 'available' or 'error'")
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

        req.logger.info("Snapshot deleted", metadata: [
            "snapshotId": .string(snapshotId.uuidString),
            "volumeId": .string(volume.id!.uuidString)
        ])

        return .noContent
    }

    // MARK: - Helper Methods

    /// Fetch a volume and check permission
    private func fetchVolumeWithPermission(req: Request, user: User, permission: String) async throws -> Volume {
        guard let volumeIdString = req.parameters.get("volumeId"),
              let volumeId = UUID(uuidString: volumeIdString) else {
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

        // Find the highest disk number
        var maxDiskNum = -1
        for volume in attachedVolumes {
            if let deviceName = volume.deviceName,
               deviceName.hasPrefix("disk"),
               let numStr = deviceName.dropFirst(4).description.components(separatedBy: CharacterSet.decimalDigits.inverted).first,
               let num = Int(numStr) {
                maxDiskNum = max(maxDiskNum, num)
            }
        }

        return "disk\(maxDiskNum + 1)"
    }
}
