import Fluent

struct AddAgentMemoryAccounting: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("agents").field("memory_accounting", .json).update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("agents").deleteField("memory_accounting").update()
    }
}
