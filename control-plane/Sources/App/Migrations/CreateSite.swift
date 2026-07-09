import Fluent

/// Sites (availability zones) group agents that share a routable underlay and
/// one OVN deployment. Adds the `sites` table plus nullable `site_id` on both
/// agents and logical networks: a site-less agent keeps the legacy per-node
/// OVN model, and a site-less network is unpinned (placeable anywhere, so only
/// safe while it stays on one node).
///
/// `network_controller_agent_id` intentionally has no FK: agents deregister
/// and re-register by name, and losing the designation to a cascade would
/// silently stop topology reconciliation for the whole site. Dangling ids are
/// resolved (and ignored) at sync-assembly time instead.
struct CreateSite: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("sites")
            .id()
            .field("name", .string, .required)
            .field("description", .string)
            .field("network_controller_agent_id", .uuid)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "name")
            .create()

        // One field per .update() for SQLite compatibility.
        try await database.schema("agents")
            .field("site_id", .uuid, .references("sites", "id", onDelete: .setNull))
            .update()

        try await database.schema("logical_networks")
            .field("site_id", .uuid, .references("sites", "id", onDelete: .setNull))
            .update()

        try await database.schema("agent_registration_tokens")
            .field("site_id", .uuid, .references("sites", "id", onDelete: .setNull))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("agent_registration_tokens")
            .deleteField("site_id")
            .update()

        try await database.schema("logical_networks")
            .deleteField("site_id")
            .update()

        try await database.schema("agents")
            .deleteField("site_id")
            .update()

        try await database.schema("sites").delete()
    }
}
