import Fluent
import Vapor

/// Migration to convert existing VM disk fields to Volume records
/// This ensures backwards compatibility with VMs created before the volume system
struct MigrateVMDisksToVolumes: AsyncMigration {
    func prepare(on database: Database) async throws {
        let logger = database.logger
        logger.info("Starting migration of existing VM disks to volumes")

        // Fetch all VMs that have a diskPath set
        let vms = try await VM.query(on: database)
            .filter(\.$diskPath != nil)
            .all()

        logger.info("Found \(vms.count) VMs with disk paths to migrate")

        var migratedCount = 0
        var skippedCount = 0

        for vm in vms {
            guard let vmId = vm.id else {
                logger.warning("VM without ID found, skipping")
                skippedCount += 1
                continue
            }

            guard let diskPath = vm.diskPath else {
                logger.warning("VM \(vmId) has no disk path, skipping")
                skippedCount += 1
                continue
            }

            // Check if a volume already exists for this VM
            let existingVolume = try await Volume.query(on: database)
                .filter(\.$vm.$id == vmId)
                .filter(\.$volumeType == .boot)
                .first()

            if existingVolume != nil {
                logger.info("VM \(vmId) already has a boot volume, skipping")
                skippedCount += 1
                continue
            }

            // Get the first user in the project as the owner (best effort)
            // In practice, we don't know who created the VM originally
            let projectId = vm.$project.id

            // Try to find a user with access to this project
            // Default to the first admin user if we can't find one
            let owner: User?
            if let adminUser = try await User.query(on: database)
                .filter(\.$isSystemAdmin == true)
                .first() {
                owner = adminUser
            } else {
                owner = try await User.query(on: database).first()
            }

            guard let ownerId = owner?.id else {
                logger.warning("No users found in database, cannot migrate VM \(vmId)")
                skippedCount += 1
                continue
            }

            // Create a Volume record for the existing disk
            let volume = Volume(
                name: "\(vm.name)-boot",
                description: "Boot volume migrated from VM disk",
                projectID: projectId,
                size: vm.disk,
                format: .qcow2,  // Assume qcow2 as default
                volumeType: .boot,
                status: .attached,
                createdByID: ownerId
            )

            // Set the VM relationship and device info
            volume.$vm.id = vmId
            volume.deviceName = "disk0"
            volume.bootOrder = 0
            volume.storagePath = diskPath
            volume.hypervisorId = vm.hypervisorId

            try await volume.save(on: database)

            logger.info("Migrated disk to volume for VM \(vmId)", metadata: [
                "volumeId": .string(volume.id?.uuidString ?? "unknown"),
                "diskPath": .string(diskPath)
            ])

            migratedCount += 1
        }

        logger.info("VM disk to volume migration complete", metadata: [
            "migrated": .stringConvertible(migratedCount),
            "skipped": .stringConvertible(skippedCount)
        ])
    }

    func revert(on database: Database) async throws {
        let logger = database.logger
        logger.info("Reverting VM disk to volume migration")

        // Find all volumes that were created by this migration
        // (boot volumes with description containing "migrated from VM disk")
        let migratedVolumes = try await Volume.query(on: database)
            .filter(\.$volumeType == .boot)
            .filter(\.$description == "Boot volume migrated from VM disk")
            .all()

        logger.info("Found \(migratedVolumes.count) migrated volumes to revert")

        for volume in migratedVolumes {
            try await volume.delete(on: database)
        }

        logger.info("Reverted VM disk to volume migration")
    }
}
