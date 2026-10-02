import Fluent

struct AddVMGuestConfigEvidence: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(VM.schema)
            .field("guest_config_evidence", .json)
            .field("guest_config_failed_generation", .int64)
            .field("guest_config_realized_generation", .int64).update()
    }
    func revert(on database: any Database) async throws {
        try await database.schema(VM.schema)
            .deleteField("guest_config_evidence")
            .deleteField("guest_config_failed_generation")
            .deleteField("guest_config_realized_generation").update()
    }
}
