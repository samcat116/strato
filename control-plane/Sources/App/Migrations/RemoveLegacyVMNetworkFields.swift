import Fluent

/// Drops the legacy single-NIC columns from `vms` once
/// `MigrateVMNetworkConfigToInterfaces` has copied them into
/// `vm_network_interfaces`.
///
/// Each column change is a separate `.update()` because SQLite cannot combine
/// multiple ALTER TABLE actions in one statement.
struct RemoveLegacyVMNetworkFields: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("vms").deleteField("mac_address").update()
        try await database.schema("vms").deleteField("ip_address").update()
        try await database.schema("vms").deleteField("network_mask").update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("vms").field("mac_address", .string).update()
        try await database.schema("vms").field("ip_address", .string).update()
        try await database.schema("vms").field("network_mask", .string).update()
    }
}
