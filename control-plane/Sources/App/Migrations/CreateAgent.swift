import Fluent

struct CreateAgent: AsyncMigration {
    func prepare(on database: Database) async throws {
        let agentStatus = try await database.enum("agent_status")
            .case("online")
            .case("offline")
            .case("connecting")
            .case("error")
            .create()
        
        try await database.schema("agents")
            .id()
            .field("name", .string, .required)
            .field("hostname", .string, .required)
            .field("version", .string, .required)
            .field("capabilities", .array(of: .string), .required)
            .field("status", agentStatus, .required)
            .field("total_cpu", .int, .required)
            .field("total_memory", .int64, .required)
            .field("total_disk", .int64, .required)
            .field("available_cpu", .int, .required)
            .field("available_memory", .int64, .required)
            .field("available_disk", .int64, .required)
            .field("last_heartbeat", .datetime)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "name")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("agents").delete()
        try await database.enum("agent_status").delete()
    }
}