import Fluent

/// Persists the latest independently sampled host and per-workload contention
/// snapshots (STR-266). JSON keeps the availability-bearing wire shape intact;
/// receipt timestamps use the control-plane clock for freshness decisions.
struct AddResourceContentionTelemetry: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("agents")
            .field("resource_telemetry", .json)
            .field("resource_telemetry_received_at", .datetime)
            .update()
        try await database.schema("vms")
            .field("resource_telemetry", .json)
            .field("resource_telemetry_received_at", .datetime)
            .update()
        try await database.schema("sandboxes")
            .field("resource_telemetry", .json)
            .field("resource_telemetry_received_at", .datetime)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("sandboxes")
            .deleteField("resource_telemetry_received_at")
            .deleteField("resource_telemetry")
            .update()
        try await database.schema("vms")
            .deleteField("resource_telemetry_received_at")
            .deleteField("resource_telemetry")
            .update()
        try await database.schema("agents")
            .deleteField("resource_telemetry_received_at")
            .deleteField("resource_telemetry")
            .update()
    }
}
