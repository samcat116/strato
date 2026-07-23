import Fluent
import Foundation
import SQLKit

/// Gives every organization that owns no site of its own a "<org> Default Site"
/// (availability zone), so a node can be enrolled into it immediately.
///
/// Enrollment now requires a site (`CreateAgentEnrollmentRequest.validate`);
/// without a default, an organization created before this change — or any org
/// whose operator never made a site — could not enroll its first agent until
/// someone hand-created one. New orgs get their default at creation time
/// (`Site.createDefault`); this covers the pre-existing ones.
///
/// Deliberately conservative: only orgs with zero directly-owned sites are
/// touched, and an org is skipped if the computed default name already exists
/// (site names are globally unique), so the backfill is safe on installs that
/// already manage sites.
struct BackfillDefaultSites: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }

        try await sql.raw(
            """
            INSERT INTO sites (id, name, description, organization_id, created_at, updated_at)
            SELECT gen_random_uuid(),
                   o.name || ' Default Site',
                   'Default availability zone for ' || o.name,
                   o.id, now(), now()
            FROM organizations o
            WHERE NOT EXISTS (SELECT 1 FROM sites s WHERE s.organization_id = o.id)
              AND NOT EXISTS (SELECT 1 FROM sites s2 WHERE s2.name = o.name || ' Default Site')
            """
        ).run()
    }

    func revert(on database: Database) async throws {
        // No-op: an auto-created default is a perfectly valid site, and by the
        // time a revert runs an operator may have assigned it a network
        // controller, renamed it, or placed agents/networks in it. Deleting on
        // a name heuristic would risk removing a site in active use, so the
        // rows are left in place.
    }
}
