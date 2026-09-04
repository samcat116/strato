import Fluent
import SQLKit

/// Repairs agent receipt timestamps stamped by a replica's wall clock before
/// STR-292 made PostgreSQL the authoritative clock. Future liveness and
/// dependency samples are made stale, not fresh, so a disconnected legacy
/// agent cannot remain eligible while the database clock catches up.
struct NormalizeLegacyAgentClockTimestamps: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw ClusterClockError.sqlDatabaseRequired
        }

        try await sql.raw(
            """
            WITH database_clock AS MATERIALIZED (
                SELECT clock_timestamp() AS current_time
            )
            UPDATE agents
            SET last_heartbeat = CASE
                    WHEN last_heartbeat > database_clock.current_time
                    THEN database_clock.current_time - interval '61 seconds'
                    ELSE last_heartbeat
                END,
                dependency_observations_received_at = CASE
                    WHEN dependency_observations_received_at > database_clock.current_time
                    THEN database_clock.current_time - interval '61 seconds'
                    ELSE dependency_observations_received_at
                END,
                resource_telemetry_received_at = CASE
                    WHEN resource_telemetry_received_at > database_clock.current_time
                    THEN database_clock.current_time
                    ELSE resource_telemetry_received_at
                END
            FROM database_clock
            WHERE last_heartbeat > database_clock.current_time
               OR dependency_observations_received_at > database_clock.current_time
               OR resource_telemetry_received_at > database_clock.current_time
            """
        ).run()
    }

    /// This data repair cannot recover the discarded replica-clock offsets.
    func revert(on database: any Database) async throws {}
}
