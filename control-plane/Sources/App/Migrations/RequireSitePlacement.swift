import Fluent
import Foundation
import SQLKit

/// Converts the last implicit single-node placements to the owning
/// organization's default site, then makes placement a database invariant.
///
/// The scope CTE handles resources delegated to OUs. A
/// missing default site deliberately makes `SET NOT NULL` fail: silently
/// retaining an unplaced topology resource would reintroduce the sentinel this
/// migration removes.
struct RequireSitePlacement: AsyncMigration {
    private struct AmbiguousOrganization: Decodable {
        let organizationID: UUID
        let unplacedAgentCount: Int

        enum CodingKeys: String, CodingKey {
            case organizationID = "organization_id"
            case unplacedAgentCount = "unplaced_agent_count"
        }
    }

    private struct AmbiguousLegacyTopology: Error, CustomStringConvertible {
        let inventory: String

        var description: String {
            """
            Site placement migration found ambiguous independent OVN deployments \
            (organization=site-less-agent-count: \(inventory)). Create one site for each \
            deployment and assign its agents before retrying the migration.
            """
        }
    }

    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }

        let scopes = """
            WITH ou_roots AS (
                SELECT id, organization_id AS root_id FROM organizational_units
            )
            """

        // A legacy site-less agent owns an independent local northbound DB.
        // Combining two such agents in one site would designate one writer for
        // two databases and stop reconciling the other's topology. Refuse that
        // ambiguous inventory before changing anything: operators must first
        // create the real sites and explicitly map all but (at most) the one
        // deployment intended to become the organization's default site.
        let ambiguous = try await sql.raw(
            """
            WITH unplaced AS (
                SELECT COALESCE(a.organization_id, ou.organization_id) AS organization_id,
                       COUNT(*)::int AS unplaced_agent_count
                FROM agents a
                LEFT JOIN organizational_units ou ON ou.id = a.organizational_unit_id
                WHERE a.site_id IS NULL
                GROUP BY COALESCE(a.organization_id, ou.organization_id)
            )
            SELECT organization_id, unplaced_agent_count
            FROM unplaced
            WHERE unplaced_agent_count > 1
               OR EXISTS (
                    SELECT 1
                    FROM agents placed
                    JOIN sites existing_site ON existing_site.id = placed.site_id
                    JOIN organizations owner ON owner.id = existing_site.organization_id
                    WHERE existing_site.organization_id = unplaced.organization_id
                      AND existing_site.name IN (
                          owner.name || ' Default Site',
                          'Default Site ' || owner.id::text
                      )
                )
            """
        ).all(decoding: AmbiguousOrganization.self)
        guard ambiguous.isEmpty else {
            let inventory =
                ambiguous
                .map { "\($0.organizationID.uuidString)=\($0.unplacedAgentCount)" }
                .joined(separator: ", ")
            throw AmbiguousLegacyTopology(inventory: inventory)
        }

        // BackfillDefaultSites predates mandatory placement and intentionally
        // skipped organizations that already owned a custom site. Such an
        // organization can still have legacy NULL placements, so ensure the
        // deterministic default exists before using it below. Organization
        // names are globally unique. If another owner already claimed the
        // human-readable name, use an organization-UUID fallback that remains
        // deterministic and can be selected by the updates below.
        try await sql.raw(
            """
            INSERT INTO sites (id, name, description, organization_id, created_at, updated_at)
            SELECT gen_random_uuid(),
                   CASE
                     WHEN EXISTS (SELECT 1 FROM sites collision WHERE collision.name = o.name || ' Default Site')
                     THEN 'Default Site ' || o.id::text
                     ELSE o.name || ' Default Site'
                   END,
                   'Default availability zone for ' || o.name,
                   o.id, now(), now()
            FROM organizations o
            WHERE NOT EXISTS (
                SELECT 1 FROM sites s
                WHERE s.organization_id = o.id
                  AND s.name IN (o.name || ' Default Site', 'Default Site ' || o.id::text)
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
              AND s.name IN (
                  (SELECT name || ' Default Site' FROM organizations WHERE id = s.organization_id),
                  'Default Site ' || s.organization_id::text
              )
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
              AND s.name IN (
                  (SELECT name || ' Default Site' FROM organizations WHERE id = s.organization_id),
                  'Default Site ' || s.organization_id::text
              )
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
              AND s.name IN (
                  (SELECT name || ' Default Site' FROM organizations WHERE id = s.organization_id),
                  'Default Site ' || s.organization_id::text
              )
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
