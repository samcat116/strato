import Fluent
import Foundation
import Vapor

/// Snapshot of the `vms` columns used by this migration. In particular, this
/// must not use the live `VM` model: enum repair runs later in the migration
/// chain, and FluentKit traps while decoding a malformed `@Enum` raw value.
/// Keeping the snapshot minimal also prevents later VM fields from breaking
/// this historical migration.
private final class VMVolumeBackfillRow: Model, @unchecked Sendable {
    static let schema = "vms"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "name")
    var name: String

    @Field(key: "disk")
    var disk: Int64

    @OptionalField(key: "disk_path")
    var diskPath: String?

    @OptionalField(key: "hypervisor_id")
    var hypervisorId: String?

    @Field(key: "project_id")
    var projectId: UUID

    init() {}
}

/// Snapshot of the `volumes` columns as they exist at this migration's point
/// in the order. The live `Volume` model has since grown fields (e.g.
/// `pool_id`) whose columns don't exist yet when this migration runs — and no
/// longer exist when it reverts — so querying through it fails on both paths.
private final class LegacyVolume: Model, @unchecked Sendable {
    static let schema = "volumes"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "name")
    var name: String

    @Field(key: "description")
    var description: String

    @Field(key: "project_id")
    var projectId: UUID

    @Field(key: "size")
    var size: Int64

    @Field(key: "format")
    var format: String

    @Field(key: "type")
    var volumeType: String

    @Field(key: "status")
    var status: String

    @OptionalField(key: "storage_path")
    var storagePath: String?

    @OptionalField(key: "hypervisor_id")
    var hypervisorId: String?

    @OptionalField(key: "vm_id")
    var vmId: UUID?

    @OptionalField(key: "device_name")
    var deviceName: String?

    @OptionalField(key: "boot_order")
    var bootOrder: Int?

    @Field(key: "created_by_id")
    var createdById: UUID

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}
}

/// Migration to convert existing VM disk fields to Volume records
/// This ensures backwards compatibility with VMs created before the volume system
struct MigrateVMDisksToVolumes: AsyncMigration {
    func prepare(on database: Database) async throws {
        let logger = database.logger
        logger.info("Starting migration of existing VM disks to volumes")

        // Fetch all VMs that have a diskPath set
        let vms = try await VMVolumeBackfillRow.query(on: database)
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
            let existingVolume = try await LegacyVolume.query(on: database)
                .filter(\.$vmId == vmId)
                .filter(\.$volumeType == "boot")
                .first()

            if existingVolume != nil {
                logger.info("VM \(vmId) already has a boot volume, skipping")
                skippedCount += 1
                continue
            }

            // Get the first user in the project as the owner (best effort)
            // In practice, we don't know who created the VM originally
            let projectId = vm.projectId

            // Try to find a user with access to this project
            // Default to the first admin user if we can't find one
            let owner: User?
            if let adminUser = try await User.query(on: database)
                .filter(\.$isSystemAdmin == true)
                .first()
            {
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
            let volume = LegacyVolume()
            volume.name = "\(vm.name)-boot"
            volume.description = "Boot volume migrated from VM disk"
            volume.projectId = projectId
            volume.size = vm.disk
            volume.format = "qcow2"  // Assume qcow2 as default
            volume.volumeType = "boot"
            volume.status = "attached"
            volume.createdById = ownerId

            // Set the VM relationship and device info
            volume.vmId = vmId
            volume.deviceName = "disk0"
            volume.bootOrder = 0
            volume.storagePath = diskPath
            volume.hypervisorId = vm.hypervisorId

            try await volume.save(on: database)

            logger.info(
                "Migrated disk to volume for VM \(vmId)",
                metadata: [
                    "volumeId": .string(volume.id?.uuidString ?? "unknown"),
                    "diskPath": .string(diskPath),
                ])

            migratedCount += 1
        }

        logger.info(
            "VM disk to volume migration complete",
            metadata: [
                "migrated": .stringConvertible(migratedCount),
                "skipped": .stringConvertible(skippedCount),
            ])
    }

    func revert(on database: Database) async throws {
        let logger = database.logger
        logger.info("Reverting VM disk to volume migration")

        // Find all volumes that were created by this migration
        // (boot volumes with description containing "migrated from VM disk")
        let migratedVolumes = try await LegacyVolume.query(on: database)
            .filter(\.$volumeType == "boot")
            .filter(\.$description == "Boot volume migrated from VM disk")
            .all()

        logger.info("Found \(migratedVolumes.count) migrated volumes to revert")

        for volume in migratedVolumes {
            try await volume.delete(on: database)
        }

        logger.info("Reverted VM disk to volume migration")
    }
}
