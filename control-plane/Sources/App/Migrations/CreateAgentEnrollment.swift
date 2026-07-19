import Fluent

struct CreateAgentEnrollment: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("agent_enrollments")
            .id()
            .field("agent_name", .string, .required)
            .field("spiffe_id", .string, .required)
            .field("is_used", .bool, .required)
            .field("site_id", .uuid, .references("sites", "id", onDelete: .setNull))
            .field("organization_id", .uuid, .references("organizations", "id", onDelete: .restrict))
            .field(
                "organizational_unit_id", .uuid,
                .references("organizational_units", "id", onDelete: .restrict)
            )
            .field("expires_at", .datetime, .required)
            .field("created_at", .datetime)
            .field("used_at", .datetime)
            // One enrollment per node: re-enrolling a name revokes the old row
            // first, so a duplicate here means two SPIRE grants for one agent.
            .unique(on: "agent_name")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("agent_enrollments").delete()
    }
}
