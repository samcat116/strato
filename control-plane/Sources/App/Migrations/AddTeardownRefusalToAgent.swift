import Fluent

/// The agent-reported blast-radius refusal (STR-98 phase 2), on the row where
/// the UI can show it.
///
/// A refusal is a standing condition rather than an event — it repeats on
/// every sync until the teardown batch shrinks or an operator intervenes — so
/// it belongs beside `update_blocked_reason`, which is surfaced the same way
/// and for the same reason: an agent declining to do what the control plane
/// asked is something an operator has to see, not something to leave in a log
/// on the host.
struct AddTeardownRefusalToAgent: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("agents")
            .field("teardown_refusal_reason", .string)
            .field("teardown_refused_at", .datetime)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("agents")
            .deleteField("teardown_refusal_reason")
            .deleteField("teardown_refused_at")
            .update()
    }
}
