import Fluent

/// Persisted separately from the Agent model so stale model saves cannot
/// overwrite the session generation, and it is not exposed in API responses.
struct AddAgentInventorySession: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("agents").field("inventory_session_id", .uuid).update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("agents").deleteField("inventory_session_id").update()
    }
}
