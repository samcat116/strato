import Fluent
import Foundation
import SQLKit

/// Assigns every pre-existing unscoped agent, site, and registration token to
/// the oldest organization. Scoping is mandatory going forward (new rows are
/// validated in application code), but rows created before
/// `AddOrganizationScopeToInfra` have no owner; the oldest org is the best
/// available guess — single-org installs (the common case) are exact, and
/// multi-org installs can correct individual agents afterwards via
/// `PATCH /api/agents/:id/organization`.
///
/// No-op when no organization exists yet: then no user has ever registered,
/// and token creation (which requires an org) has never been reachable.
struct BackfillInfraOrganizationScope: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }

        try await sql.raw(
            """
            UPDATE agents
            SET organization_id = (SELECT id FROM organizations ORDER BY created_at LIMIT 1)
            WHERE organization_id IS NULL AND organizational_unit_id IS NULL
            """
        ).run()
        try await sql.raw(
            """
            UPDATE sites
            SET organization_id = (SELECT id FROM organizations ORDER BY created_at LIMIT 1)
            WHERE organization_id IS NULL AND organizational_unit_id IS NULL
            """
        ).run()
        try await sql.raw(
            """
            UPDATE agent_registration_tokens
            SET organization_id = (SELECT id FROM organizations ORDER BY created_at LIMIT 1)
            WHERE organization_id IS NULL AND organizational_unit_id IS NULL
            """
        ).run()
    }

    func revert(on database: Database) async throws {
        // The pre-migration state (no scope columns at all) is restored by
        // AddOrganizationScopeToInfra's revert; nothing to undo here.
    }
}
