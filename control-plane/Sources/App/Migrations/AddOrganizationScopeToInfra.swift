import Fluent

/// Agents, sites, and registration tokens become organization-scoped: each
/// carries exactly one of `organization_id` / `organizational_unit_id` (the
/// Project pattern — both columns nullable, the one-of invariant enforced in
/// application code so historical rows can be backfilled separately).
///
/// `.restrict` on both FKs: infrastructure must never silently lose its owner
/// to an org/OU deletion — the delete fails until the operator reassigns or
/// removes the agents/sites first.
struct AddOrganizationScopeToInfra: AsyncMigration {
    func prepare(on database: Database) async throws {
        // One field per .update() for SQLite compatibility.
        try await database.schema("agents")
            .field("organization_id", .uuid, .references("organizations", "id", onDelete: .restrict))
            .update()
        try await database.schema("agents")
            .field("organizational_unit_id", .uuid, .references("organizational_units", "id", onDelete: .restrict))
            .update()

        try await database.schema("sites")
            .field("organization_id", .uuid, .references("organizations", "id", onDelete: .restrict))
            .update()
        try await database.schema("sites")
            .field("organizational_unit_id", .uuid, .references("organizational_units", "id", onDelete: .restrict))
            .update()

        try await database.schema("agent_registration_tokens")
            .field("organization_id", .uuid, .references("organizations", "id", onDelete: .restrict))
            .update()
        try await database.schema("agent_registration_tokens")
            .field("organizational_unit_id", .uuid, .references("organizational_units", "id", onDelete: .restrict))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("agent_registration_tokens")
            .deleteField("organizational_unit_id")
            .update()
        try await database.schema("agent_registration_tokens")
            .deleteField("organization_id")
            .update()

        try await database.schema("sites")
            .deleteField("organizational_unit_id")
            .update()
        try await database.schema("sites")
            .deleteField("organization_id")
            .update()

        try await database.schema("agents")
            .deleteField("organizational_unit_id")
            .update()
        try await database.schema("agents")
            .deleteField("organization_id")
            .update()
    }
}
