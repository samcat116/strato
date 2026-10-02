import Fluent

struct AddVMGuestConfigEvidence: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(VM.schema).field("guest_config_evidence", .json).update()
    }
    func revert(on database: any Database) async throws {
        try await database.schema(VM.schema).deleteField("guest_config_evidence").update()
    }
}
