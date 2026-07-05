import Fluent
import SQLKit

struct CreateVMNetworkInterface: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("vm_network_interfaces")
            .id()
            .field("vm_id", .uuid, .required, .references("vms", "id", onDelete: .cascade))
            .field("network", .string, .required)
            .field("mac_address", .string, .required)
            .field("ip_address", .string)
            .field("netmask", .string)
            .field("mtu", .int)
            .field("device_name", .string, .required)
            .field("order_index", .int, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "vm_id", "device_name")
            .create()

        // Spec building loads a VM's interfaces by vm_id on every create; the FK's
        // referencing column is not indexed automatically (see AddVMHotColumnIndexes).
        if let sql = database as? SQLDatabase {
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_vm_network_interfaces_vm_id ON vm_network_interfaces (vm_id)"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_vm_network_interfaces_vm_id").run()
        }
        try await database.schema("vm_network_interfaces").delete()
    }
}
