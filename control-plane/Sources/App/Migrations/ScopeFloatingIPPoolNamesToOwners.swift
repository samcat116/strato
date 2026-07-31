import Fluent
import Foundation
import SQLKit

/// Scopes `floating_ip_pools.name` uniqueness to the pool's owner (STR-105).
///
/// `CreateFloatingIP` made the name globally unique across the database even
/// though the row already carries its owner, so the first tenant to create a
/// pool named `public` locked every other tenant out of that name — and a
/// create collision disclosed that some other organization holds it. The two
/// sibling constraints were already fixed the same way:
/// `ScopeLogicalNetworksToProjects` (`(project_id, name)`) and
/// `AddTrustDomainToAgentIdentities` (`(trust_domain, name)`).
///
/// A pool is owned by exactly one of `organization_id` / `organizational_unit_id`
/// (`OrganizationScope`), so the scoped key is one partial index per owner
/// column rather than a single composite: each indexes only the rows that
/// column actually owns. Rows that predate scoping own neither column and stay
/// unconstrained — the same rows `FloatingIPController` already treats as
/// system-admin-only, and which the API can no longer create.
///
/// Partial indexes need raw SQL (Fluent's schema builder has no support for
/// them), matching `uq_floating_ips_interface` in `CreateFloatingIP`.
struct ScopeFloatingIPPoolNamesToOwners: AsyncMigration {
    struct UnsupportedDatabase: Error {}

    /// Restoring global uniqueness is impossible once two owners have taken the
    /// same name — which is exactly the state this migration exists to allow.
    struct DuplicatePoolNames: Error, LocalizedError, CustomStringConvertible, Equatable {
        let names: [String]

        var errorDescription: String? { description }

        var description: String {
            """
            Cannot restore global uniqueness on floating_ip_pools.name: \
            \(names.count) name(s) are held by more than one owner \
            (\(names.joined(separator: ", "))). Rename or delete the duplicates \
            before reverting this migration.
            """
        }
    }

    /// Swapping one constraint for two indexes takes three statements, and
    /// `Migrator` wraps nothing — a run that dies partway (statement timeout on
    /// a large table, a killed rolling deploy) would leave the constraint
    /// dropped, the migration unrecorded, and the retry failing on whichever
    /// statement already succeeded, recoverable only by hand. Postgres has
    /// transactional DDL, so one explicit transaction makes the swap atomic;
    /// `IF NOT EXISTS` is the cheap backstop for an index that somehow outlives
    /// it. No data can trip either — the global constraint being dropped here
    /// guarantees there are no duplicates to reject.
    func prepare(on database: Database) async throws {
        guard database is SQLDatabase else { throw UnsupportedDatabase() }

        try await database.transaction { db in
            guard let sql = db as? SQLDatabase else { throw UnsupportedDatabase() }

            try await db.schema("floating_ip_pools")
                .deleteUnique(on: "name")
                .update()

            try await sql.raw(
                """
                CREATE UNIQUE INDEX IF NOT EXISTS uq_floating_ip_pools_org_name
                ON floating_ip_pools (organization_id, name) WHERE organization_id IS NOT NULL
                """
            ).run()
            try await sql.raw(
                """
                CREATE UNIQUE INDEX IF NOT EXISTS uq_floating_ip_pools_ou_name
                ON floating_ip_pools (organizational_unit_id, name)
                WHERE organizational_unit_id IS NOT NULL
                """
            ).run()
        }
    }

    /// Atomic for the same reason as `prepare`, and with the duplicate check
    /// inside the transaction so it can't be invalidated by a concurrent insert
    /// between the check and the constraint.
    func revert(on database: Database) async throws {
        guard database is SQLDatabase else { throw UnsupportedDatabase() }

        try await database.transaction { db in
            guard let sql = db as? SQLDatabase else { throw UnsupportedDatabase() }

            // Fail with the offending names rather than letting the constraint
            // report an opaque "could not create unique index" on one
            // arbitrary row.
            let duplicates = try await sql.raw(
                """
                SELECT name FROM floating_ip_pools GROUP BY name HAVING count(*) > 1 ORDER BY name
                """
            ).all(decodingColumn: "name", as: String.self)
            guard duplicates.isEmpty else { throw DuplicatePoolNames(names: duplicates) }

            try await sql.raw("DROP INDEX IF EXISTS uq_floating_ip_pools_org_name").run()
            try await sql.raw("DROP INDEX IF EXISTS uq_floating_ip_pools_ou_name").run()

            try await db.schema("floating_ip_pools")
                .unique(on: "name")
                .update()
        }
    }
}
