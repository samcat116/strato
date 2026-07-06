import Fluent
import SQLKit

/// Adds the gateway denormalized onto each NIC row at allocation time (so spec
/// building needs no network lookup), and a unique index guarding control-plane
/// IPAM against two concurrent creates allocating the same address on one
/// network. NULL ip_address rows are exempt on both PostgreSQL and SQLite.
struct AddGatewayToVMNetworkInterface: AsyncMigration {
    func prepare(on database: Database) async throws {
        // Single action per update() call: SQLite cannot combine multiple
        // ALTER TABLE actions in one statement.
        try await database.schema("vm_network_interfaces")
            .field("gateway", .string)
            .update()

        if let sql = database as? SQLDatabase {
            try await sql.raw(
                "CREATE UNIQUE INDEX IF NOT EXISTS idx_vm_network_interfaces_network_ip "
                    + "ON vm_network_interfaces (network, ip_address)"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_vm_network_interfaces_network_ip").run()
        }
        try await database.schema("vm_network_interfaces")
            .deleteField("gateway")
            .update()
    }
}
