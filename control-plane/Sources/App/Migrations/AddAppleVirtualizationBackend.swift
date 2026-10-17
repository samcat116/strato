import Fluent
import SQLKit
import Vapor

/// Expands the durable backend identity without rewriting existing VMs.
struct AddAppleVirtualizationBackend: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { throw Abort(.internalServerError) }
        try await sql.raw(
            """
            ALTER TABLE vms
            DROP CONSTRAINT ck_vms_hypervisor_type_enum,
            ADD CONSTRAINT ck_vms_hypervisor_type_enum
            CHECK (hypervisor_type IN ('qemu', 'firecracker', 'apple_virtualization'))
            """
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { throw Abort(.internalServerError) }
        // PostgreSQL refuses rollback while Apple VMs exist; never rename or delete them.
        try await sql.raw(
            """
            ALTER TABLE vms
            DROP CONSTRAINT ck_vms_hypervisor_type_enum,
            ADD CONSTRAINT ck_vms_hypervisor_type_enum
            CHECK (hypervisor_type IN ('qemu', 'firecracker'))
            """
        ).run()
    }
}
