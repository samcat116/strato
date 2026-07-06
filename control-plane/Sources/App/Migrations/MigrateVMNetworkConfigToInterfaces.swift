import Fluent
import Vapor

/// Converts the legacy single-NIC fields on `vms` (mac_address, ip_address,
/// network_mask) into `VMNetworkInterface` records, completing for networking what
/// `MigrateVMDisksToVolumes` did for disks. The legacy columns are dropped by the
/// subsequent `RemoveLegacyVMNetworkFields` migration.
struct MigrateVMNetworkConfigToInterfaces: AsyncMigration {
    /// The `VM` model no longer declares the legacy network fields, so this
    /// migration reads them through its own minimal mapping of the `vms` table.
    private final class LegacyVM: Model, @unchecked Sendable {
        static let schema = "vms"

        @ID(key: .id)
        var id: UUID?

        @OptionalField(key: "mac_address")
        var macAddress: String?

        @OptionalField(key: "ip_address")
        var ipAddress: String?

        @OptionalField(key: "network_mask")
        var networkMask: String?

        init() {}
    }

    /// Point-in-time mapping of `vm_network_interfaces` with only the columns
    /// that existed when this migration shipped. The live `VMNetworkInterface`
    /// model has since grown columns (e.g. `gateway`) that are added by later
    /// migrations, so using it here would reference columns that don't exist
    /// yet on prepare (fresh database) or no longer exist on revert.
    private final class MigrationInterface: Model, @unchecked Sendable {
        static let schema = "vm_network_interfaces"

        @ID(key: .id)
        var id: UUID?

        @Parent(key: "vm_id")
        var vm: VM

        @Field(key: "network")
        var network: String

        @Field(key: "mac_address")
        var macAddress: String

        @OptionalField(key: "ip_address")
        var ipAddress: String?

        @OptionalField(key: "netmask")
        var netmask: String?

        @Field(key: "device_name")
        var deviceName: String

        @Field(key: "order_index")
        var orderIndex: Int

        init() {}

        init(vmID: UUID, network: String, macAddress: String, ipAddress: String?, netmask: String?) {
            self.$vm.id = vmID
            self.network = network
            self.macAddress = macAddress
            self.ipAddress = ipAddress
            self.netmask = netmask
            self.deviceName = "net0"
            self.orderIndex = 0
        }
    }

    func prepare(on database: Database) async throws {
        let logger = database.logger

        let vms = try await LegacyVM.query(on: database)
            .filter(\.$macAddress != nil)
            .all()

        logger.info("Found \(vms.count) VMs with legacy network config to migrate")

        var migratedCount = 0
        var skippedCount = 0

        for vm in vms {
            guard let vmId = vm.id, let macAddress = vm.macAddress else {
                skippedCount += 1
                continue
            }

            let existingInterface = try await MigrationInterface.query(on: database)
                .filter(\.$vm.$id == vmId)
                .first()

            if existingInterface != nil {
                logger.info("VM \(vmId) already has a network interface, skipping")
                skippedCount += 1
                continue
            }

            let interface = MigrationInterface(
                vmID: vmId,
                network: "default",
                macAddress: macAddress,
                ipAddress: vm.ipAddress,
                netmask: vm.networkMask
            )
            try await interface.save(on: database)
            migratedCount += 1
        }

        logger.info(
            "VM network config to interface migration complete",
            metadata: [
                "migrated": .stringConvertible(migratedCount),
                "skipped": .stringConvertible(skippedCount),
            ])
    }

    func revert(on database: Database) async throws {
        // Runs after RemoveLegacyVMNetworkFields.revert has recreated the legacy
        // columns: copy each VM's first interface back, then remove the records
        // (CreateVMNetworkInterface.revert drops the table afterwards).
        let interfaces = try await MigrationInterface.query(on: database)
            .sort(\.$orderIndex)
            .all()

        var restored: Set<UUID> = []
        for interface in interfaces {
            let vmId = interface.$vm.id
            guard !restored.contains(vmId) else { continue }
            restored.insert(vmId)

            guard let vm = try await LegacyVM.find(vmId, on: database) else { continue }
            vm.macAddress = interface.macAddress
            vm.ipAddress = interface.ipAddress
            vm.networkMask = interface.netmask
            try await vm.save(on: database)
        }

        try await MigrationInterface.query(on: database).delete()
    }
}
