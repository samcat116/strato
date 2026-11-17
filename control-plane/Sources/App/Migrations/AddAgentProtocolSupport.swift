import Fluent

/// Registration owns these values alongside inventory_session_id. They are
/// deliberately absent from Fluent's Agent model and its public JSON shape.
/// `protocol_session_id` names the registration session that wrote them, so a
/// session's agreement can be written once and never changed.
struct AddAgentProtocolSupport: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("agents")
            .field("protocol_major", .int)
            .field("protocol_capabilities", .json)
            .field("protocol_agreed_capabilities", .json)
            .field("protocol_session_id", .uuid)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("agents")
            .deleteField("protocol_major")
            .deleteField("protocol_capabilities")
            .deleteField("protocol_agreed_capabilities")
            .deleteField("protocol_session_id")
            .update()
    }
}
