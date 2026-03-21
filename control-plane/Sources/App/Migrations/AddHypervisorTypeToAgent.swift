import Fluent

struct AddHypervisorTypeToAgent: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("agents")
            .field("hypervisor_type", .string, .required, .custom("DEFAULT 'qemu'"))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("agents")
            .deleteField("hypervisor_type")
            .update()
    }
}
