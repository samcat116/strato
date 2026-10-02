import Fluent

struct AddGuestAgentObservationToVM: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("vms")
            .field("guest_agent_observation", .json)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("vms").deleteField("guest_agent_observation").update()
    }
}
