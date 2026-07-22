import Fluent
import Foundation

/// The organization-lifecycle half of per-org trust domains (issue #613).
///
/// Both ends of the lifecycle are written here and nowhere else, so the
/// feature flag is checked in exactly one place: with
/// `SPIRE_ORG_TRUST_DOMAINS_ENABLED` off these are no-ops and an organization
/// has no trust domain at all, which is the pre-#600 behavior.
///
/// Neither writes anything about SPIRE itself — provisioning the instance,
/// establishing federation and caching the bundle is the reconciler's job
/// (issue #614). These just record intent for it to converge on.
enum OrgTrustDomainProvisioning {
    /// Claim the trust domain for a newly created organization. Idempotent: an
    /// organization that somehow already has a row keeps it, because the domain
    /// string is immutable once any SVID has been issued under it.
    ///
    /// Call inside the organization-create transaction.
    static func claim(organizationID: UUID, on db: Database) async throws {
        guard OrgTrustDomainsFeature.isEnabled else { return }

        let existing = try await OrgTrustDomain.query(on: db)
            .filter(\.$organizationID == organizationID)
            .first()
        if existing != nil { return }

        let row = OrgTrustDomain(
            organizationID: organizationID,
            trustDomain: OrgTrustDomain.trustDomain(
                forOrganization: organizationID,
                platformTrustDomain: PlatformTrustDomain.current
            )
        )
        try await row.save(on: db)
    }

    /// Mark a deleted organization's trust domain for teardown. Bumps the
    /// generation so the reconciler treats it as fresh intent even if it had
    /// already converged the row, and stamps the tombstone.
    ///
    /// Call inside the organization-delete transaction. The row is *not*
    /// deleted: destroying the CA is work that outlives the organization.
    static func markForTeardown(organizationID: UUID, on db: Database) async throws {
        guard OrgTrustDomainsFeature.isEnabled else { return }

        guard
            let row = try await OrgTrustDomain.query(on: db)
                .filter(\.$organizationID == organizationID)
                .first()
        else { return }

        row.phase = .deleting
        row.generation += 1
        row.deletedAt = Date()
        row.lastError = nil
        try await row.save(on: db)
    }
}
