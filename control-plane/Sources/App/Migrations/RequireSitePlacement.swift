import Fluent
import SQLKit

/// Converts the last implicit single-node placements to the owning
/// organization's default site, then makes placement a database invariant.
///
/// The scope CTE handles resources delegated to OUs. A
/// missing default site deliberately makes `SET NOT NULL` fail: silently
/// retaining an unplaced topology resource would reintroduce the sentinel this
/// migration removes.
struct RequireSitePlacement: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }

        let scopes = """
            WITH ou_roots AS (
                SELECT id, organization_id AS root_id FROM organizational_units
            )
            """

        // BackfillDefaultSites predates mandatory placement and intentionally
        // skipped organizations that already owned a custom site. Such an
        // organization can still have legacy NULL placements, so ensure the
        // deterministic default exists before using it below. Organization
        // names and site names are globally unique, making this idempotent.
        try await sql.raw(
            """
            INSERT INTO sites (id, name, description, organization_id, created_at, updated_at)
            SELECT gen_random_uuid(),
                   o.name || ' Default Site',
                   'Default availability zone for ' || o.name,
                   o.id, now(), now()
            FROM organizations o
            WHERE NOT EXISTS (
                SELECT 1 FROM sites s WHERE s.name = o.name || ' Default Site'
            )
            """
        ).run()

        try await sql.raw(
            """
            \(unsafeRaw: scopes)
            UPDATE agents a SET site_id = s.id
            FROM sites s
            WHERE a.site_id IS NULL
              AND s.organization_id = COALESCE(a.organization_id,
                  (SELECT root_id FROM ou_roots WHERE id = a.organizational_unit_id))
              AND s.name = (SELECT name || ' Default Site' FROM organizations WHERE id = s.organization_id)
            """
        ).run()
        try await sql.raw(
            """
            \(unsafeRaw: scopes)
            UPDATE logical_networks n SET site_id = s.id
            FROM projects p, sites s
            WHERE n.site_id IS NULL AND p.id = n.project_id
              AND s.organization_id = COALESCE(p.organization_id,
                  (SELECT root_id FROM ou_roots WHERE id = p.organizational_unit_id))
              AND s.name = (SELECT name || ' Default Site' FROM organizations WHERE id = s.organization_id)
            """
        ).run()
        try await sql.raw(
            """
            \(unsafeRaw: scopes)
            UPDATE floating_ip_pools f SET site_id = s.id
            FROM sites s
            WHERE f.site_id IS NULL
              AND s.organization_id = COALESCE(f.organization_id,
                  (SELECT root_id FROM ou_roots WHERE id = f.organizational_unit_id))
              AND s.name = (SELECT name || ' Default Site' FROM organizations WHERE id = s.organization_id)
            """
        ).run()

        for table in ["agents", "logical_networks", "floating_ip_pools"] {
            try await sql.raw(
                "ALTER TABLE \(ident: table) ALTER COLUMN site_id SET NOT NULL"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        for table in ["agents", "logical_networks", "floating_ip_pools"] {
            try await sql.raw(
                "ALTER TABLE \(ident: table) ALTER COLUMN site_id DROP NOT NULL"
            ).run()
        }
    }
}
