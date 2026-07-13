import Fluent
import SQLKit

/// Sandbox NIC table (issue #416), mirroring `CreateVMNetworkInterface`. One
/// row per sandbox NIC (single-NIC in v1); cascade-deleted with the sandbox so
/// a sandbox delete tears down its interface and addresses.
struct CreateSandboxNetworkInterface: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("sandbox_network_interfaces")
            .id()
            .field("sandbox_id", .uuid, .required, .references("sandboxes", "id", onDelete: .cascade))
            .field("network", .string, .required)
            .field("mac_address", .string, .required)
            .field("mtu", .int)
            .field("device_name", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "sandbox_id", "device_name")
            .create()

        // Sync assembly loads a sandbox's interfaces by sandbox_id; the FK's
        // referencing column is not indexed automatically.
        if let sql = database as? SQLDatabase {
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_sandbox_network_interfaces_sandbox_id "
                    + "ON sandbox_network_interfaces (sandbox_id)"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_sandbox_network_interfaces_sandbox_id").run()
        }
        try await database.schema("sandbox_network_interfaces").delete()
    }
}
