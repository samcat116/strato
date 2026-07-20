import Fluent
import Foundation
import SQLKit

/// Creates `vm_interface_observed_addresses`, the guest-reported (qga)
/// counterpart of `vm_interface_addresses` (issue #563). No backfill: observed
/// addresses only exist once an agent reports them, so the table starts empty.
struct CreateVMInterfaceObservedAddresses: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("vm_interface_observed_addresses")
            .id()
            .field(
                "interface_id", .uuid, .required,
                .references("vm_network_interfaces", "id", onDelete: .cascade)
            )
            .field("family", .string, .required)
            .field("address", .string, .required)
            .field("prefix_length", .int)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()

        if let sql = database as? SQLDatabase {
            // One row per (interface, address): a guest reports each address
            // once, and the uniqueness keeps reconciliation idempotent.
            try await sql.raw(
                "CREATE UNIQUE INDEX IF NOT EXISTS idx_vm_interface_observed_addresses_iface_address "
                    + "ON vm_interface_observed_addresses (interface_id, address)"
            ).run()
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_vm_interface_observed_addresses_interface "
                    + "ON vm_interface_observed_addresses (interface_id)"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_vm_interface_observed_addresses_iface_address").run()
            try await sql.raw("DROP INDEX IF EXISTS idx_vm_interface_observed_addresses_interface").run()
        }
        try await database.schema("vm_interface_observed_addresses").delete()
    }
}
