import Fluent
import SQLKit

/// Gives durable deadlines written before STR-292 a safe database-clock
/// baseline. The old writer's wall-clock offset was never stored, so it cannot
/// be reconstructed during upgrade.
///
/// In-flight convergence gets a fresh, family-specific maximum budget. Legacy
/// snapshot retention restarts the originally requested TTL, recovered from
/// the difference between `created_at` and `expires_at`; malformed rows whose
/// TTL cannot be recovered are kept rather than deleted early. The other
/// active fixed windows are restarted from the same sampled database instant:
/// sandbox TTLs, pending VM commands, and nonterminal agent updates.
struct RebaseLegacyClusterClockDeadlines: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw ClusterClockError.sqlDatabaseRequired
        }
        let databaseTime = try await ClusterClock.read(on: database).date

        for (table, budgetSeconds) in Self.convergenceBudgets {
            try await sql.raw(
                """
                UPDATE \(unsafeRaw: table)
                SET convergence_deadline = GREATEST(
                    convergence_deadline,
                    \(bind: databaseTime) + \(bind: budgetSeconds) * interval '1 second'
                )
                WHERE convergence_deadline IS NOT NULL
                """
            ).run()
        }

        for table in Self.snapshotTables {
            try await sql.raw(
                """
                UPDATE \(unsafeRaw: table)
                SET expires_at = CASE
                    WHEN created_at IS NULL OR expires_at <= created_at THEN NULL
                    ELSE GREATEST(
                        expires_at,
                        \(bind: databaseTime) + (expires_at - created_at)
                    )
                END
                WHERE expires_at IS NOT NULL
                """
            ).run()
        }

        // `expiresAt` is derived from this anchor rather than stored. Moving
        // active legacy TTLs to the migration instant grants the complete
        // requested lifetime without changing the user-visible TTL value.
        try await sql.raw(
            """
            UPDATE sandboxes
            SET created_at = \(bind: databaseTime)
            WHERE ttl_seconds IS NOT NULL
              AND desired_status <> 'Absent'
            """
        ).run()

        // Every recorded command uses the same fixed completion budget. Actor
        // capture state is process-local and empty after deployment, so the
        // durable pending row is the only deadline that needs rebasing.
        try await sql.raw(
            """
            UPDATE vm_command_executions
            SET deadline = \(bind: databaseTime)
                         + \(bind: Self.vmCommandBudgetSeconds) * interval '1 second'
            WHERE status = 'pending'
            """
        ).run()

        // A failed assignment is already terminal and a parked assignment has
        // a nil attempt timestamp. Restart only assignments the sweep can
        // still judge against its health budget.
        try await sql.raw(
            """
            UPDATE agents
            SET update_attempted_at = \(bind: databaseTime)
            WHERE update_desired_version IS NOT NULL
              AND update_attempted_at IS NOT NULL
              AND update_failure_reason IS NULL
            """
        ).run()
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
        (LogicalNetwork.schema, 180),
        (SecurityGroup.schema, 180),
    ]

    private static let snapshotTables = [
        VolumeSnapshot.schema,
        VMSnapshot.schema,
        SandboxSnapshot.schema,
    ]

    private static let vmCommandBudgetSeconds = Int(VMCommandExecutionService.completionBudget)
}
