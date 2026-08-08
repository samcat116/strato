import Fluent
import Foundation
import Vapor

/// The SPIFFE identity a guest VM is registered under (STR-55).
///
/// Composition and lookup only: this type says what a VM's identity *is*, never
/// what it may do. The URI is a lookup key into `workload_registrations`
/// (`docs/architecture/iam.md`: "identity names the principal; it never carries
/// authorization"), and the row it keys holds no role bindings until an operator
/// writes one — which is why every VM gets a registration unconditionally rather
/// than behind a per-VM switch. A principal with no bindings authenticates and
/// authorizes nothing, so the switch would be a second lock on a door the
/// authorization model already holds shut.
enum GuestIdentity {

    /// The guest-VM SPIFFE namespace (`docs/architecture/guest-identity.md`).
    ///
    /// Not yet refused by `WorkloadRegistry.validateRegistrable` — reserving it
    /// is STR-165 — so until then the `spiffe_id` unique index is what keeps a
    /// hand-registered URI from colliding with a VM's. Note that the minting
    /// path below deliberately does *not* route through `validateRegistrable`:
    /// its contract is validating a URI **supplied to a registration API**, and
    /// sending a machine-composed URI through it would break VM creation the day
    /// the reservation lands.
    static let vmPathPrefix = "/vm/"

    /// `/vm/<vm-id>`, the id **lowercased**.
    ///
    /// The spelling is fixed here, once, because changing it later invalidates
    /// every SVID ever issued under it. Lowercase for three reasons:
    ///
    /// * The path is matched by **exact string** on the way back in —
    ///   `WorkloadRegistry.resolve` filters `spiffe_id` for equality, and
    ///   `JWTSVIDAuthenticator` hands it a token's `sub` verbatim. Two spellings
    ///   of one identity is a lookup key that misses.
    /// * It is the house spelling for every identifier derived from a UUID:
    ///   Cedar entity ids (`CedarEntityUID`), role and policy descriptors, and
    ///   every OVN name the agent builds.
    /// * The authority half is already lowercase —
    ///   `OrgTrustDomain.trustDomain(forOrganization:)` lowercases the whole
    ///   domain because SPIFFE requires it — so an uppercase `uuidString` would
    ///   make the URI half-and-half.
    static func path(forVM vmID: UUID) -> String {
        "\(vmPathPrefix)\(vmID.uuidString.lowercased())"
    }

    /// The full URI for a VM's identity.
    ///
    /// Built through `SPIFFEIdentity` rather than by interpolation so the
    /// leading-slash rule stays in the one place that already owns it.
    static func spiffeID(forVM vmID: UUID, trustDomain: String) -> String {
        SPIFFEIdentity(trustDomain: trustDomain, path: path(forVM: vmID)).uri
    }

    /// The trust domain a guest of `organizationID` is minted into.
    ///
    /// The predicate mirrors `DatabaseOrgTrustDomainSource.loadOrgTrustDomains`
    /// exactly — the feature flag, `phase == .active`, and a cached bundle — and
    /// that is not duplication to be tidied away. That source decides which
    /// domains the control plane will *accept* identities from; a VM minted into
    /// a domain it rejects would hold an identity its own control plane refuses
    /// to authenticate. The two must move together.
    ///
    /// Falling back to the platform domain is a **degraded** mode, not an
    /// equivalent one (`docs/architecture/guest-identity.md`, "Naming"): every
    /// tenant's guests are then issued under the one CA that also signs Strato's
    /// own infrastructure. It is the only option while per-org trust domains
    /// ship dark, and the fallback is deliberate rather than a failure.
    ///
    /// The choice is made **once**, when the row is written, and the resulting
    /// URI never moves. Turning `SPIRE_ORG_TRUST_DOMAINS_ENABLED` on later
    /// leaves existing VMs on the platform domain; re-issuing them is a
    /// migration of its own, not something this resolver does behind an
    /// operator's back.
    static func trustDomain(
        forOrganization organizationID: UUID?,
        on db: any Database
    ) async throws -> String {
        let platform = PlatformTrustDomain.current
        guard OrgTrustDomainsFeature.isEnabled, let organizationID else { return platform }

        guard
            let row = try await OrgTrustDomain.query(on: db)
                .filter(\.$organizationID == organizationID)
                .filter(\.$phase == .active)
                .first(),
            row.acceptsIdentities
        else { return platform }

        return row.trustDomain
    }

    /// Create the registry row that makes a VM a principal.
    ///
    /// Call inside the VM's create transaction: the identity and the VM commit
    /// together or not at all, so there is no window in which a VM exists
    /// without one.
    @discardableResult
    static func register(
        vmID: UUID,
        organizationID: UUID?,
        displayName: String?,
        createdBy: UUID?,
        on db: any Database
    ) async throws -> WorkloadRegistration {
        let trustDomain = try await trustDomain(forOrganization: organizationID, on: db)
        let registration = WorkloadRegistration(
            spiffeID: spiffeID(forVM: vmID, trustDomain: trustDomain),
            kind: .workload,
            organizationID: organizationID,
            displayName: displayName,
            createdBy: createdBy,
            vmID: vmID
        )
        try await registration.save(on: db)
        return registration
    }

    /// The SPIFFE IDs of a set of VMs, in one query.
    ///
    /// The batched form is the only one the desired-state assembly and the VM
    /// list may use: both run over every VM in scope, so a per-VM lookup there
    /// is a fleet-wide load multiplier rather than a per-VM cost. A VM missing
    /// from the result has no registration — an administrator revoked it — and
    /// is vended no identity.
    static func spiffeIDs(forVMs vmIDs: [UUID], on db: any Database) async throws -> [UUID: String] {
        guard !vmIDs.isEmpty else { return [:] }
        let rows = try await WorkloadRegistration.query(on: db)
            .filter(\.$vm.$id ~~ vmIDs)
            .all()
        return Dictionary(
            rows.compactMap { row in row.$vm.id.map { ($0, row.spiffeID) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// One VM's SPIFFE ID, for the single-resource endpoints. Nil when the VM
    /// has no registration.
    static func spiffeID(forVM vmID: UUID, on db: any Database) async throws -> String? {
        try await spiffeIDs(forVMs: [vmID], on: db)[vmID]
    }
}
