import Fluent
import Foundation
import SQLKit
import Vapor

/// Gives every VM that predates STR-55 the instance-identity registration a VM
/// created today gets in its own create transaction.
///
/// Without it, instance identity would be a property of *when* a VM was created
/// — new VMs vended a SPIFFE ID through the metadata service, older ones
/// silently not — which is the kind of split nothing downstream can reason
/// about: a role binding written against one VM's principal has no counterpart
/// to write against another's, and an operator reading the registry cannot tell
/// an absent identity from a revoked one.
///
/// The trust domain is chosen by the same rule `GuestIdentity.trustDomain`
/// applies at runtime: the organization's own domain when per-org trust domains
/// are enabled *and* that domain is one the control plane would accept
/// identities from (`phase = 'active'` with a cached bundle), else the platform
/// domain. Read from the environment rather than injected, matching
/// `AddTrustDomainToAgentIdentities`.
///
/// One `INSERT … SELECT` rather than a Swift loop over `VM.query`: the org walk
/// is two `LEFT JOIN`s and the domain choice is a `COALESCE`, so the whole thing
/// is one statement — which matters, because a loop would pull every VM row on
/// the fleet into the migration's transaction to issue one insert each.
struct BackfillVMWorkloadRegistrations: AsyncMigration {

    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }

        let platformTrustDomain = PlatformTrustDomain.current
        let orgDomainsEnabled = OrgTrustDomainsFeature.isEnabled

        var query: SQLQueryString = """
            INSERT INTO workload_registrations
                (id, spiffe_id, kind, organization_id, vm_id, display_name, created_at)
            SELECT gen_random_uuid(),
                   'spiffe://' ||
            """

        // The org-domain join is emitted only when the flag is on: with it off
        // there is no org domain to prefer, and an always-present join would
        // read as one.
        if orgDomainsEnabled {
            query += " COALESCE(otd.trust_domain, \(bind: platformTrustDomain))"
        } else {
            query += " \(bind: platformTrustDomain)"
        }

        // `lower(v.id::text)` is `GuestIdentity.path(forVM:)` in SQL — the same
        // lowercase spelling, for the same reason: the URI is matched by exact
        // string on the way back in.
        query += """
             || '/vm/' || lower(v.id::text),
                   'workload'::workload_registration_kind,
                   org.id,
                   v.id,
                   v.name,
                   now()
            FROM vms v
            LEFT JOIN projects p ON p.id = v.project_id
            LEFT JOIN organizational_units ou ON ou.id = p.organizational_unit_id
            LEFT JOIN organizations org
                   ON org.id = COALESCE(p.organization_id, ou.organization_id)
            """

        if orgDomainsEnabled {
            query += """

                LEFT JOIN org_trust_domains otd
                       ON otd.organization_id = org.id
                      AND otd.phase = 'active'::org_trust_domain_phase
                      AND otd.org_bundle_pem IS NOT NULL
                """
        }

        // `ON CONFLICT DO NOTHING` covers the `spiffe_id` unique index, which a
        // hand-registered URI could be squatting while `/vm/` is unreserved
        // (STR-165). Skipping such a row is the only safe answer here — a
        // migration cannot redraw a VM's id the way the create path's retry can
        // — so the count below is what makes the skip visible instead of
        // silent. The `NOT EXISTS` guard covers re-application, which
        // `MigrationRoundTripTests` performs.
        query += """

            WHERE NOT EXISTS (
                      SELECT 1 FROM workload_registrations wr WHERE wr.vm_id = v.id)
            ON CONFLICT DO NOTHING
            """

        try await sql.raw(query).run()

        let strandedRow = try await sql.raw(
            """
            SELECT count(*) AS stranded FROM vms v
            WHERE NOT EXISTS (SELECT 1 FROM workload_registrations wr WHERE wr.vm_id = v.id)
            """
        ).first()
        let stranded = try strandedRow?.decode(column: "stranded", as: Int.self) ?? 0
        if stranded > 0 {
            database.logger.warning(
                """
                Some VMs could not be given an instance identity; their SPIFFE ID is already \
                registered to another principal. Inspect GET /api/workload-registrations and \
                remove the squatting rows, then re-run this migration.
                """,
                metadata: ["vms_without_identity": .stringConvertible(stranded)]
            )
        }
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }

        // Deliberately **not** a no-op, unlike `BackfillDefaultSites`. The
        // migration above this one drops `vm_id`, and reverts run in reverse
        // order: a row that survived would lose its link to the VM but keep its
        // `spiffe_id`, so on re-apply the unique index would lock that VM out of
        // the identity it is supposed to own — permanently, and silently,
        // because the insert's `ON CONFLICT DO NOTHING` would skip it.
        // Deleting restores the exact pre-migration state.
        //
        // Bindings first: a principal row removed without its grants is the
        // leak STR-112 exists to prevent, and here the orphans would point at a
        // principal id nothing can resolve.
        try await sql.raw(
            """
            DELETE FROM role_bindings
            WHERE principal_type = 'workload'
              AND principal_id IN (SELECT id FROM workload_registrations WHERE vm_id IS NOT NULL)
            """
        ).run()

        try await sql.raw("DELETE FROM workload_registrations WHERE vm_id IS NOT NULL").run()
    }
}
