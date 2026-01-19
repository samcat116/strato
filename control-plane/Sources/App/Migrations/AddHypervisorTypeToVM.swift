import Fluent

struct AddHypervisorTypeToVM: AsyncMigration {
    func prepare(on database: Database) async throws {
        // Add hypervisor_type field to VMs table with default value of "qemu"
        try await database.schema("vms")
            .field("hypervisor_type", .string, .required, .sql(.default("qemu")))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("vms")
            .deleteField("hypervisor_type")
            .update()
    }
}
