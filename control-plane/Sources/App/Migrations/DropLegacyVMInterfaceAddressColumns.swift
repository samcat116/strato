import Fluent
import SQLKit

/// Drops the legacy single-address columns from `vm_network_interfaces`
/// (`ip_address`, `netmask`, `gateway`), superseded by per-family rows in
/// `vm_interface_addresses` (`CreateVMInterfaceAddresses`). The columns were
/// kept mapped-but-unwritten for one release so a binary rollback still
/// booted; that window is over. The old per-network IPAM uniqueness index goes
/// with them — `idx_vm_interface_addresses_network_address` took over its job.
struct DropLegacyVMInterfaceAddressColumns: AsyncMigration {
    func prepare(on database: Database) async throws {
        // The index is dropped explicitly rather than left to Postgres, which
        // would drop it implicitly with the column it references.
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_vm_network_interfaces_network_ip").run()
        }

        try await database.schema("vm_network_interfaces")
            .deleteField("ip_address")
            .update()
        try await database.schema("vm_network_interfaces")
            .deleteField("netmask")
            .update()
        try await database.schema("vm_network_interfaces")
            .deleteField("gateway")
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("vm_network_interfaces")
            .field("ip_address", .string)
            .update()
        try await database.schema("vm_network_interfaces")
            .field("netmask", .string)
            .update()
        try await database.schema("vm_network_interfaces")
            .field("gateway", .string)
            .update()

        // Restore the uniqueness index exactly as AddGatewayToVMNetworkInterface
        // created it. The re-added columns are all NULL, which both engines
        // treat as distinct, so building it cannot fail.
        if let sql = database as? SQLDatabase {
            try await sql.raw(
                "CREATE UNIQUE INDEX IF NOT EXISTS idx_vm_network_interfaces_network_ip "
                    + "ON vm_network_interfaces (network, ip_address)"
            ).run()
        }
    }
}
