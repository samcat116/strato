import Foundation
import Fluent
import Vapor

/// The trust domain the control plane's own identities live in. Every org trust
/// domain is a subdomain of it, and everything that predates per-org trust
/// domains — the existing agents, their enrollments, the CP Envoy SVID — belongs
/// to it.
enum PlatformTrustDomain {
    /// Default used by model/test convenience initializers. Runtime SPIRE
    /// services use the startup-resolved `spireTrustDomain` setting instead.
    static let current = "strato.local"
}

/// One organization's trust domain as `SPIREService` needs it: the domain
/// string, the org it scopes to, and the roots its SVIDs must chain to.
public struct OrgTrustDomainSnapshot: Sendable {
    public let organizationID: UUID
    public let trustDomain: String
    /// PEM-concatenated X.509 roots for this domain.
    public let bundlePEM: String

    public init(organizationID: UUID, trustDomain: String, bundlePEM: String) {
        self.organizationID = organizationID
        self.trustDomain = trustDomain
        self.bundlePEM = bundlePEM
    }
}

/// Source of the org trust domains `SPIREService` will accept identities from.
/// A protocol rather than a direct query so the service stays unit-testable
/// without a database, and so a future cache (phase 3's reconciler already
/// maintains one) can be substituted without touching validation.
public protocol OrgTrustDomainSource: Sendable {
    func loadOrgTrustDomains() async throws -> [OrgTrustDomainSnapshot]
}

/// Reads the `org_trust_domains` table. Returns nothing at all while the
/// feature flag is off, which is what keeps the multi-trust-domain paths
/// dormant even if rows somehow exist.
struct DatabaseOrgTrustDomainSource: OrgTrustDomainSource {
    let app: Application

    public func loadOrgTrustDomains() async throws -> [OrgTrustDomainSnapshot] {
        guard app.controlPlaneConfiguration.bool(.spireOrgTrustDomainsEnabled) == true else { return [] }

        let rows = try await OrgTrustDomainStore.active(on: app.db)

        // `acceptsIdentities` also demands a cached bundle: a domain we hold no
        // roots for cannot be verified against, and accepting its SVIDs on the
        // strength of the row alone would be exactly the union-of-roots mistake
        // per-org domains exist to prevent.
        return rows.compactMap { row in
            guard row.acceptsIdentities, let bundlePEM = row.orgBundlePEM else { return nil }
            return OrgTrustDomainSnapshot(
                organizationID: row.organizationID,
                trustDomain: row.trustDomain,
                bundlePEM: bundlePEM
            )
        }
    }
}
