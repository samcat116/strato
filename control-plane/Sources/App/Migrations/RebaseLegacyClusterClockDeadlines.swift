import Fluent
import SQLKit

/// Gives durable deadlines written before STR-292 a safe database-clock
/// baseline. The old writer's wall-clock offset was never stored, so it cannot
/// be reconstructed during upgrade.
///
/// In-flight convergence gets a fresh, family-specific maximum budget. Legacy
/// snapshot retention restarts the originally requested TTL, recovered from
/// the difference between `created_at` and `expires_at`; malformed rows whose
/// TTL cannot be recovered are kept rather than deleted early.
struct RebaseLegacyClusterClockDeadlines: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw ClusterClockError.sqlDatabaseRequired
        }

        for (table, budgetSeconds) in Self.convergenceBudgets {
            try await sql.raw(
                """
                WITH database_clock AS MATERIALIZED (
                    SELECT clock_timestamp() AS current_time
                )
                UPDATE \(unsafeRaw: table)
                SET convergence_deadline = GREATEST(
                    convergence_deadline,
                    database_clock.current_time + \(bind: budgetSeconds) * interval '1 second'
                )
                FROM database_clock
                WHERE convergence_deadline IS NOT NULL
                """
            ).run()
        }

        for table in Self.snapshotTables {
            try await sql.raw(
                """
                WITH database_clock AS MATERIALIZED (
                    SELECT clock_timestamp() AS current_time
                )
                UPDATE \(unsafeRaw: table)
                SET expires_at = CASE
                    WHEN created_at IS NULL OR expires_at <= created_at THEN NULL
                    ELSE GREATEST(
                        expires_at,
                        database_clock.current_time + (expires_at - created_at)
                    )
                END
                FROM database_clock
                WHERE expires_at IS NOT NULL
                """
            ).run()
        }
    }

    /// This data repair cannot recover the discarded replica-clock offsets.
    func revert(on database: any Database) async throws {}

    private static let convergenceBudgets: [(table: String, seconds: Int)] = [
        (VM.schema, 1_800),
        (Sandbox.schema, 3_600),
        (Volume.schema, 900),
        (VolumeSnapshot.schema, 300),
        (VMSnapshot.schema, 1_800),
        (SandboxSnapshot.schema, 3_600),
    ]

    private static let snapshotTables = [
        VolumeSnapshot.schema,
        VMSnapshot.schema,
        SandboxSnapshot.schema,
    ]
}
