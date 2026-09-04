import Fluent
import Foundation
import SQLKit

/// Persists the network fabric's agent-reported convergence state (STR-294).
/// Fresh databases receive the same columns from `CurrentSchema.sql`; catalog-
/// guarded statements repair preserved databases without a second baseline.
struct AddNetworkFabricObservations: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw ConvergenceWriteError.unsupportedDatabase
        }
        for table in ["logical_networks", "security_groups"] {
            try await sql.raw(
                """
                ALTER TABLE \(ident: table)
                    ADD COLUMN IF NOT EXISTS observed_generation bigint NOT NULL DEFAULT 0,
                    ADD COLUMN IF NOT EXISTS convergence_phase text,
                    ADD COLUMN IF NOT EXISTS last_error text,
                    ADD COLUMN IF NOT EXISTS failed_generation bigint,
                    ADD COLUMN IF NOT EXISTS last_error_at timestamp with time zone,
                    ADD COLUMN IF NOT EXISTS convergence_deadline timestamp with time zone
                """
            ).run()
        }
        // Security groups historically started at generation zero. Zero also
        // means "no authority observation yet", so advance those existing rows
        // before deriving conditions or they would become green on upgrade.
        try await sql.raw(
            "UPDATE security_groups SET generation = 1 WHERE generation = 0"
        ).run()

        // Existing rows did not pass through the new mutation writer and
        // therefore have no silence deadline. Give every outstanding fabric
        // generation the same initial budget as a newly accepted mutation.
        let convergenceDeadline = Date().addingTimeInterval(180)
        for table in ["logical_networks", "security_groups"] {
            try await sql.raw(
                """
                UPDATE \(ident: table)
                SET convergence_deadline = \(bind: convergenceDeadline)
                WHERE observed_generation < generation
                  AND convergence_deadline IS NULL
                """
            ).run()
        }
        for table in ["vm_network_interfaces", "sandbox_network_interfaces"] {
            try await sql.raw(
                """
                ALTER TABLE \(ident: table)
                    ADD COLUMN IF NOT EXISTS security_group_status text,
                    ADD COLUMN IF NOT EXISTS security_group_last_error text,
                    ADD COLUMN IF NOT EXISTS security_group_last_error_at timestamp with time zone
                """
            ).run()
        }
    }

    /// Fresh-schema ownership makes destructive reversion ambiguous. Rebuild a
    /// database to move behind this baseline instead of dropping observations.
    func revert(on database: any Database) async throws {}
}
