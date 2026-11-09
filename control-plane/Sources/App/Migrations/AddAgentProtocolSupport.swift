import Fluent

/// Registration owns these values alongside inventory_session_id. They are
/// deliberately absent from Fluent's Agent model and its public JSON shape.
struct AddAgentProtocolSupport: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("agents")
            .field("protocol_major", .int)
            .field("protocol_capabilities", .json)
            .field("protocol_agreed_capabilities", .json)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("agents")
            .deleteField("protocol_major")
            .deleteField("protocol_capabilities")
            .deleteField("protocol_agreed_capabilities")
            .update()
    }
}
