import Fluent
import SQLKit

/// Per-organization SPIFFE trust domains, phase 2 (issue #613).
///
/// The table ships dark: with `SPIRE_ORG_TRUST_DOMAINS_ENABLED` off nothing
/// writes rows, so only the platform trust domain is ever in play.
///
/// `organization_id` deliberately carries no foreign key. A `deleting` row has
/// to outlive the organization it names — that row *is* the instruction to
/// destroy the org's CA — and a cascade or a restrict would either erase the
/// teardown work or block the delete outright.
struct CreateOrgTrustDomain: AsyncMigration {
    func prepare(on database: Database) async throws {
        let phase = try await database.enum("org_trust_domain_phase")
            .case("pending")
            .case("provisioning")
            .case("active")
            .case("failed")
            .case("deleting")
            .create()

        try await database.schema("org_trust_domains")
            .id()
            .field("organization_id", .uuid, .required)
            .field("trust_domain", .string, .required)
            // Defaults so the schema stands on its own: the model's `init`
            // always sets these, but a raw insert or a future backfill that
            // omits them should land on the same starting state rather than
            // fail.
            .field("phase", phase, .required, .sql(.default("pending")))
            .field("generation", .int, .required, .sql(.default(1)))
            .field("observed_generation", .int, .required, .sql(.default(0)))
            .field("server_address", .string)
            .field("bundle_endpoint_url", .string)
            .field("node_address", .string)
            .field("org_bundle_pem", .string)
            .field("platform_federation_at", .datetime)
            .field("org_federation_at", .datetime)
            .field("last_error", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .field("deleted_at", .datetime)
            // One trust domain per organization, and one organization per
            // trust domain: the runtime lookup that scopes an SVID to an org
            // is only sound if the domain string resolves to exactly one row.
            .unique(on: "organization_id")
            .unique(on: "trust_domain")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("org_trust_domains").delete()
        try await database.enum("org_trust_domain_phase").delete()
    }
}
