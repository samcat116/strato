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

    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { throw UnsupportedDatabase() }

        try await database.schema("floating_ip_pools")
            .deleteUnique(on: "name")
            .update()

        try await sql.raw(
            """
            CREATE UNIQUE INDEX uq_floating_ip_pools_org_name
            ON floating_ip_pools (organization_id, name) WHERE organization_id IS NOT NULL
            """
        ).run()
        try await sql.raw(
            """
            CREATE UNIQUE INDEX uq_floating_ip_pools_ou_name
            ON floating_ip_pools (organizational_unit_id, name)
            WHERE organizational_unit_id IS NOT NULL
            """
        ).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { throw UnsupportedDatabase() }

        // Fail with the offending names rather than letting the index build
        // report an opaque "could not create unique index" on one arbitrary row.
        let duplicates = try await sql.raw(
            """
            SELECT name FROM floating_ip_pools GROUP BY name HAVING count(*) > 1 ORDER BY name
            """
        ).all(decodingColumn: "name", as: String.self)
        guard duplicates.isEmpty else { throw DuplicatePoolNames(names: duplicates) }

        try await sql.raw("DROP INDEX IF EXISTS uq_floating_ip_pools_org_name").run()
        try await sql.raw("DROP INDEX IF EXISTS uq_floating_ip_pools_ou_name").run()

        try await database.schema("floating_ip_pools")
            .unique(on: "name")
            .update()
    }
}
