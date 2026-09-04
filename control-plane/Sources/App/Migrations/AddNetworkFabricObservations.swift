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

        try await sql.raw(
            """
            CREATE TABLE IF NOT EXISTS security_group_site_observations (
                id uuid PRIMARY KEY,
                security_group_id uuid NOT NULL
                    REFERENCES security_groups(id) ON DELETE CASCADE,
                site_id uuid NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
                observed_generation bigint NOT NULL DEFAULT 0,
                status text,
                last_error text,
                failed_generation bigint,
                failure_classification text,
                last_error_at timestamp with time zone,
                CONSTRAINT uq_security_group_site_observations
                    UNIQUE (security_group_id, site_id)
            )
            """
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS ix_security_group_site_observations_site ON security_group_site_observations(site_id)"
        ).run()

        // Seed every currently required site/group pair, including the
        // transitive remote-group closure. Offline authorities must count on
        // upgrade even though they cannot run an assembly pass themselves.
        try await sql.raw(
            """
            WITH RECURSIVE direct(site_id, group_id) AS (
                SELECT DISTINCT agents.site_id, memberships.security_group_id
                FROM vm_interface_security_groups memberships
                JOIN vm_network_interfaces interfaces ON interfaces.id = memberships.interface_id
                JOIN vms ON vms.id = interfaces.vm_id
                JOIN agents ON lower(agents.id::text) = lower(vms.hypervisor_id)
                UNION
                SELECT DISTINCT agents.site_id, memberships.security_group_id
                FROM sandbox_interface_security_groups memberships
                JOIN sandbox_network_interfaces interfaces ON interfaces.id = memberships.interface_id
                JOIN sandboxes ON sandboxes.id = interfaces.sandbox_id
                JOIN agents ON lower(agents.id::text) = lower(sandboxes.hypervisor_id)
            ), required(site_id, group_id) AS (
                SELECT site_id, group_id FROM direct
                UNION
                SELECT required.site_id, rules.remote_group_id
                FROM required
                JOIN security_group_rules rules
                  ON rules.security_group_id = required.group_id
                WHERE rules.remote_group_id IS NOT NULL
            )
            INSERT INTO security_group_site_observations
                (id, security_group_id, site_id, observed_generation)
            SELECT gen_random_uuid(), group_id, site_id, 0
            FROM required
            ON CONFLICT (security_group_id, site_id) DO NOTHING
            """
        ).run()

        // Existing networks did not pass through the new mutation writer and
        // therefore have no silence deadline. Security-group deadlines start
        // only when desired-state assembly includes them for an authority;
        // otherwise unused groups would time out despite legitimate silence.
        let convergenceDeadline = Date().addingTimeInterval(180)
        try await sql.raw(
            """
            UPDATE logical_networks
            SET convergence_deadline = \(bind: convergenceDeadline)
            WHERE observed_generation < generation
              AND convergence_deadline IS NULL
            """
        ).run()
        try await sql.raw(
            """
            UPDATE security_groups groups
            SET convergence_deadline = \(bind: convergenceDeadline)
            WHERE groups.observed_generation < groups.generation
              AND groups.convergence_deadline IS NULL
              AND EXISTS (
                  SELECT 1 FROM security_group_site_observations observations
                  WHERE observations.security_group_id = groups.id
              )
            """
        ).run()
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
