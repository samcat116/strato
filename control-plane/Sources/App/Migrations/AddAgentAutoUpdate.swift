import Fluent

/// Declarative agent auto-update (issue #434): the per-agent opt-in flag and
/// the fleet rollout's bookkeeping columns.
///
/// `auto_update` defaults false — updating an agent restarts it, so nobody is
/// enrolled by surprise. The remaining columns are rollout state owned by the
/// auto-update sweep: which version the rollout has assigned this agent
/// (`update_desired_version`, carried on desired-state syncs as
/// `desiredAgentUpdate`), when it was assigned (`update_attempted_at`, the
/// health-budget clock), and the agent's last reported blocked reason /
/// terminal failure. One field per `.update()` call: SQLite cannot combine
/// multiple ALTER TABLE actions in one step.
struct AddAgentAutoUpdate: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("agents")
            .field("auto_update", .bool, .required, .sql(.default(false)))
            .update()
        try await database.schema("agents")
            .field("update_desired_version", .string)
            .update()
        try await database.schema("agents")
            .field("update_attempted_at", .datetime)
            .update()
        try await database.schema("agents")
            .field("update_blocked_reason", .string)
            .update()
        try await database.schema("agents")
            .field("update_failure_reason", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("agents")
            .deleteField("auto_update")
            .update()
        try await database.schema("agents")
            .deleteField("update_desired_version")
            .update()
        try await database.schema("agents")
            .deleteField("update_attempted_at")
            .update()
        try await database.schema("agents")
            .deleteField("update_blocked_reason")
            .update()
        try await database.schema("agents")
            .deleteField("update_failure_reason")
            .update()
    }
}
