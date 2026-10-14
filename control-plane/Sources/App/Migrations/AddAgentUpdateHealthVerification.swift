import Fluent

/// Nullable fields leave existing assignments visibly unverifiable; operators
/// must reassign to capture a trustworthy pre-update baseline.
struct AddAgentUpdateHealthVerification: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("agents")
            .field("update_health_baseline", .json)
            .field("update_target_registered_at", .datetime)
            .field("update_verification_started_at", .datetime)
            .field("update_inventory_received_at", .datetime)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("agents")
            .deleteField("update_health_baseline")
            .deleteField("update_target_registered_at")
            .deleteField("update_verification_started_at")
            .deleteField("update_inventory_received_at")
            .update()
    }
}
