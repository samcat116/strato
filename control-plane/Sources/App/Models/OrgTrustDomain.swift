import Fluent
import Vapor

/// Lifecycle phase of one organization's SPIRE instance.
///
/// The reconciler that drives these transitions arrives in phase 3 (issue
/// #614); phase 2 only writes the endpoints of the lifecycle — `pending` when
/// the organization is created and `deleting` when it is deleted — so the
/// controller has a work list waiting for it the moment it ships.
enum OrgTrustDomainPhase: String, Codable, CaseIterable, Sendable {
    /// Row exists, nothing provisioned yet.
    case pending
    /// Server/federation provisioning in flight.
    case provisioning
    /// Server up, federation established both ways, bundle cached.
    case active
    /// Provisioning failed; the reconciler retries from here.
    case failed
    /// Organization deleted (or teardown requested): the SPIRE instance and
    /// federation relationships must be destroyed. The row deliberately
    /// outlives the organization it names, so teardown survives the delete.
    case deleting
}

/// The SPIFFE trust domain owned by one organization, plus the state the
/// reconciler needs to converge its SPIRE instance.
///
/// Deliberately **has no foreign key to `organizations`** — the same reason
/// `ResourceOperation` doesn't: a `deleting` row must survive the organization
/// row it refers to, or org deletion would drop the record of the CA that still
/// has to be destroyed. Uniqueness on `organization_id` is enforced by index.
///
/// The trust domain string is immutable once assigned (it is baked into every
/// SVID the org's SPIRE server has ever issued) and is derived once from the
/// organization UUID by `OrgTrustDomain.trustDomain(forOrganization:)`. Runtime
/// resolution is always a lookup on this table, never string-parsing of the
/// domain — identity is a lookup key, never a carrier of authorization
/// (`docs/architecture/iam.md`, issue #491).
final class OrgTrustDomain: Model, @unchecked Sendable {
    static let schema = "org_trust_domains"

    @ID(key: .id)
    var id: UUID?

    /// Owning organization. Unique, and intentionally FK-free (see above).
    @Field(key: "organization_id")
    var organizationID: UUID

    /// e.g. `org-3f2a91c04b7d4e5f.strato.local`. Unique and immutable.
    @Field(key: "trust_domain")
    var trustDomain: String

    @Enum(key: "phase")
    var phase: OrgTrustDomainPhase

    /// Bumped by every intent change (create, teardown request). The reconciler
    /// copies it to `observedGeneration` once it has converged that intent, so
    /// a crash mid-provision resumes rather than being mistaken for done.
    @Field(key: "generation")
    var generation: Int

    @Field(key: "observed_generation")
    var observedGeneration: Int

    /// Address agents dial for node attestation (`host:port`).
    @OptionalField(key: "server_address")
    var serverAddress: String?

    /// SPIFFE bundle endpoint URL of this org's SPIRE server.
    @OptionalField(key: "bundle_endpoint_url")
    var bundleEndpointURL: String?

    /// Address the control plane dials for this org's SPIRE server admin API.
    @OptionalField(key: "node_address")
    var nodeAddress: String?

    /// Cached X.509 roots for this trust domain, PEM-encoded and concatenated.
    /// This is what `SPIREService` verifies org SVIDs against; without it the
    /// control plane cannot authenticate the org's agents at all.
    @OptionalField(key: "org_bundle_pem")
    var orgBundlePEM: String?

    /// When the platform trust domain last accepted this org's bundle
    /// (platform → org federation).
    @OptionalField(key: "platform_federation_at")
    var platformFederationAt: Date?

    /// When this org's server last accepted the platform bundle
    /// (org → platform federation).
    @OptionalField(key: "org_federation_at")
    var orgFederationAt: Date?

    /// Last reconciliation failure, surfaced in the admin UI (phase 7).
    @OptionalField(key: "last_error")
    var lastError: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    /// Tombstone: set when the organization is deleted. The row stays so the
    /// reconciler can finish destroying the CA, and is only removed once
    /// teardown has actually completed.
    ///
    /// Deliberately `on: .none` rather than Fluent's `.delete` soft-delete
    /// hook: a soft-deleted row is filtered out of every ordinary query, and
    /// this tombstone exists precisely so the reconciler can still *find* the
    /// row and act on it.
    @Timestamp(key: "deleted_at", on: .none)
    var deletedAt: Date?

    init() {}

    init(organizationID: UUID, trustDomain: String, phase: OrgTrustDomainPhase = .pending) {
        self.organizationID = organizationID
        self.trustDomain = trustDomain
        self.phase = phase
        self.generation = 1
        self.observedGeneration = 0
    }

    /// Whether this org's SPIRE identities should be accepted right now: the
    /// instance is (or was) up and we hold roots to verify against. A `pending`
    /// or `failed` row has nothing to verify with, and a `deleting` row's
    /// identities are being revoked.
    var acceptsIdentities: Bool {
        phase == .active && orgBundlePEM != nil
    }

    /// The trust domain for an organization, derived once at creation and then
    /// stored. Deterministic so a re-run of provisioning lands on the same
    /// domain, and short enough to stay inside SPIFFE's 255-byte name limit
    /// alongside the platform suffix.
    ///
    /// The hex characters of the UUID are the *label*, not the authority:
    /// nothing resolves an organization by parsing this string.
    ///
    /// 16 hex characters is 64 bits of the UUID. A collision would trip the
    /// `trust_domain` unique index inside the organization-create transaction
    /// and fail the creation, so the width is chosen to put that beyond
    /// practical reach (~1e-10 at 6k organizations) rather than merely
    /// unlikely; `OrgTrustDomainProvisioning.claim` still detects it explicitly
    /// instead of surfacing a raw constraint violation.
    ///
    /// The whole domain is lowercased: SPIFFE requires lowercase trust domain
    /// names, and an operator's uppercase `SPIRE_TRUST_DOMAIN` must not produce
    /// a domain that fails to match a normalized SAN.
    static func trustDomain(forOrganization organizationID: UUID, platformTrustDomain: String) -> String {
        let shortID = organizationID.uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(16)
        return "org-\(shortID).\(platformTrustDomain)".lowercased()
    }
}
