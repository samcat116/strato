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

        // The URI expression and the walk that feeds it, built once and used by
        // both statements below: the insert, and the diagnostic that reports
        // which VMs the insert could not reach. Two hand-written copies would be
        // two chances for the diagnostic to name a SPIFFE ID that is not the one
        // the insert actually tried.
        //
        // `lower(v.id::text)` is `GuestIdentity.path(forVM:)` in SQL — the same
        // lowercase spelling, for the same reason: the URI is matched by exact
        // string on the way back in.
        var uri: SQLQueryString = "'spiffe://' || "
        if orgDomainsEnabled {
            uri += "COALESCE(otd.trust_domain, \(bind: platformTrustDomain))"
        } else {
            uri += "\(bind: platformTrustDomain)"
        }
        uri += " || '/vm/' || lower(v.id::text)"

        // The org-domain join is emitted only when the flag is on: with it off
        // there is no org domain to prefer, and an always-present join would
        // read as one.
        var walk: SQLQueryString = """
            FROM vms v
            LEFT JOIN projects p ON p.id = v.project_id
            LEFT JOIN organizational_units ou ON ou.id = p.organizational_unit_id
            LEFT JOIN organizations org
                   ON org.id = COALESCE(p.organization_id, ou.organization_id)
            """
        if orgDomainsEnabled {
            walk += """

                LEFT JOIN org_trust_domains otd
                       ON otd.organization_id = org.id
                      AND otd.phase = 'active'::org_trust_domain_phase
                      AND otd.org_bundle_pem IS NOT NULL
                """
        }

        let missing: SQLQueryString = """
            WHERE NOT EXISTS (
                      SELECT 1 FROM workload_registrations wr WHERE wr.vm_id = v.id)
            """

        // No `display_name`: an operator-facing label for a VM-owned row is the
        // VM's *current* name, hydrated at read time, not a copy that decays
        // from the first rename onwards. Matches `GuestIdentity.register`.
        //
        // `ON CONFLICT DO NOTHING` covers the `spiffe_id` unique index, which a
        // hand-registered URI could be squatting while `/vm/` is unreserved
        // (STR-165). Skipping such a row is the only safe answer here — a
        // migration cannot redraw a VM's id the way the create path's retry can
        // — so the diagnostic below is what makes the skip visible instead of
        // silent. The `NOT EXISTS` guard covers re-application, which
        // `MigrationRoundTripTests` performs.
        var insert: SQLQueryString = """
            INSERT INTO workload_registrations
                (id, spiffe_id, kind, organization_id, vm_id, display_name, created_at)
            SELECT gen_random_uuid(),
                  \u{20}
            """
        insert += uri
        insert += """
            ,
                   'workload'::workload_registration_kind,
                   org.id,
                   v.id,
                   NULL,
                   now()

            """
        insert += walk
        insert += "\n"
        insert += missing
        insert += "\nON CONFLICT DO NOTHING"

        try await sql.raw(insert).run()

        // A sample of the offending SPIFFE IDs, not just a count: the operator's
        // next step is to look each one up, and a bare number would send them
        // searching a registry that now holds one row per VM. Ten is enough to
        // act on and short enough to log.
        var stragglers: SQLQueryString = "SELECT count(*) OVER () AS stranded, "
        stragglers += uri
        stragglers += " AS spiffe_id\n"
        stragglers += walk
        stragglers += "\n"
        stragglers += missing
        stragglers += "\nLIMIT 10"

        let strandedRows = try await sql.raw(stragglers).all()
        if let first = strandedRows.first {
            let stranded = try first.decode(column: "stranded", as: Int.self)
            let sample = try strandedRows.map { try $0.decode(column: "spiffe_id", as: String.self) }
            database.logger.warning(
                """
                Some VMs could not be given an instance identity: their SPIFFE ID is already \
                registered to another principal. Look each up with \
                GET /api/workload-registrations?spiffeId=<id>, remove the squatting rows, then \
                re-run this migration.
                """,
                metadata: [
                    "vms_without_identity": .stringConvertible(stranded),
                    "sample_spiffe_ids": .array(sample.map { .string($0) }),
                ]
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
