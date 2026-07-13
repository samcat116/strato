import Fluent
import SQLKit

/// Per-family address rows for sandbox NICs (issue #416), mirroring
/// `CreateVMInterfaceAddresses`. The `(network, address)` unique index is the
/// sandbox-side IPAM concurrency backstop; IPAM reads the used set as the union
/// of this table and `vm_interface_addresses`, so a VM and a sandbox never see
/// each other's addresses as free. No unique `(interface_id, family)`:
/// one-address-per-family is enforced in code so the schema permits multiple
/// per family later, matching the VM table.
struct CreateSandboxInterfaceAddresses: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("sandbox_interface_addresses")
            .id()
            .field(
                "interface_id", .uuid, .required,
                .references("sandbox_network_interfaces", "id", onDelete: .cascade)
            )
            .field("network", .string, .required)
            .field("family", .string, .required)
            .field("address", .string, .required)
            .field("prefix_length", .int, .required)
            .field("gateway", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()

        if let sql = database as? SQLDatabase {
            try await sql.raw(
                "CREATE UNIQUE INDEX IF NOT EXISTS idx_sandbox_interface_addresses_network_address "
                    + "ON sandbox_interface_addresses (network, address)"
            ).run()
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_sandbox_interface_addresses_interface "
                    + "ON sandbox_interface_addresses (interface_id)"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_sandbox_interface_addresses_network_address").run()
            try await sql.raw("DROP INDEX IF EXISTS idx_sandbox_interface_addresses_interface").run()
        }
        try await database.schema("sandbox_interface_addresses").delete()
    }
}
