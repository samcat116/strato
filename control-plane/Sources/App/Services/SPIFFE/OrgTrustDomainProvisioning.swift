import ControlPlanePostgres
import Foundation
import Vapor

/// The organization-lifecycle half of per-org trust domains (issue #613).
///
/// Both ends of the lifecycle are written here and nowhere else. With
/// `SPIRE_ORG_TRUST_DOMAINS_ENABLED` off no organization ever acquires a trust
/// domain, which is the pre-#600 behavior.
///
/// Note the asymmetry: only `claim` is flag-gated. Teardown deliberately is
/// not — see `markForTeardown`.
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
    static func claim(
        organizationID: UUID,
        configuration: ControlPlaneConfiguration,
        on db: PostgresStoreContext
    ) async throws {
        guard configuration.bool(.spireOrgTrustDomainsEnabled) == true else { return }

        let existing = try await OrgTrustDomainStore.find(
            organizationID: organizationID, on: db)
        if existing != nil { return }

        let trustDomain = OrgTrustDomain.trustDomain(
            forOrganization: organizationID,
            platformTrustDomain: configuration.string(.spireTrustDomain)!
        )

        // The derived domain is a truncation of the org UUID, so a collision
        // with a *different* organization is possible in principle. Detect it
        // here: otherwise the unique index trips inside the org-create
        // transaction and the caller sees an opaque 500 with no indication that
        // retrying with a fresh organization UUID is the remedy.
        let collision = try await OrgTrustDomainStore.find(
            trustDomain: trustDomain, on: db)
        if let collision {
            throw OrgTrustDomainError.trustDomainCollision(
                trustDomain: trustDomain,
                existingOrganizationID: collision.organizationID
            )
        }

        try await OrgTrustDomainStore.insert(
            OrgTrustDomainWrite(
                organizationID: organizationID,
                trustDomain: trustDomain),
            on: db)
    }

    /// Mark a deleted organization's trust domain for teardown. Bumps the
    /// generation so the reconciler treats it as fresh intent even if it had
    /// already converged the row, and stamps the tombstone.
    ///
    /// Call inside the organization-delete transaction. The row is *not*
    /// deleted: destroying the CA is work that outlives the organization.
    ///
    /// Deliberately **not** flag-gated, unlike `claim`. The flag can change
    /// between an organization's creation and its deletion, and gating here
    /// would mean a row claimed with the flag on and deleted with it off never
    /// records teardown intent — leaving an orphaned row (there is no FK to
    /// `organizations`) whose CA is resurrected if the flag comes back on. No
    /// row means nothing to do, so this is a no-op in the flag-off case anyway.
    static func markForTeardown(organizationID: UUID, on db: PostgresStoreContext) async throws {
        _ = try await OrgTrustDomainStore.markForTeardown(
            organizationID: organizationID, on: db)
    }
}

/// Failures that abort an organization's trust-domain claim.
enum OrgTrustDomainError: Error, LocalizedError {
    /// Two organizations derived the same trust domain. Astronomically
    /// unlikely, and recoverable only by creating the organization under a
    /// different UUID — so it is reported as itself rather than as a raw
    /// unique-constraint violation.
    case trustDomainCollision(trustDomain: String, existingOrganizationID: UUID)

    var errorDescription: String? {
        switch self {
        case .trustDomainCollision(let trustDomain, let existingOrganizationID):
            return
                "Trust domain \(trustDomain) is already claimed by organization \(existingOrganizationID); retry creating this organization"
        }
    }
}
