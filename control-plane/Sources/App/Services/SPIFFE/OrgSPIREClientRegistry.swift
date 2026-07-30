import Fluent
import Foundation
import SPIREServerAPI
import Vapor

/// Resolves the SPIRE instance that owns an organization's identities, so
/// enrollment provisions a node in *its own* organization's trust domain
/// rather than the one platform domain (issue #615).
///
/// The platform `SPIRERegistrationService` on `Application` stays exactly what
/// it was — the platform trust domain's client, and the fallback. This adds the
/// per-organization dimension on top by reading `org_trust_domains`, the table
/// the phase-3 reconciler converges.
///
/// Nothing is cached. A `SPIRERegistrationService` is a value wrapping a client
/// whose connections are already per-call, so rebuilding one costs a PEM parse
/// on an operation an operator performs by hand; a cache would only add
/// invalidation to get wrong when the reconciler rotates a bundle or moves a
/// server address.
struct OrgSPIREClientRegistry: Sendable {
    /// The platform trust domain's registration service and the configuration
    /// it was built from — the source of the settings an org instance inherits
    /// (selectors, SVID TTL, which Workload API socket authenticates us).
    private let platform: SPIRERegistrationService
    private let platformConfig: SPIRERegistrationConfig
    private let logger: Logger

    /// Both flags are values, not environment reads at the point of use. The
    /// environment is consulted once, in `fromApplication`; tests construct the
    /// registry with explicit values instead of mutating the process
    /// environment, which `setenv` makes global and racy against the other
    /// suites swift-testing runs concurrently.
    private let orgTrustDomainsEnabled: Bool
    private let legacyEnrollmentsAllowed: Bool

    init(
        platform: SPIRERegistrationService,
        platformConfig: SPIRERegistrationConfig,
        logger: Logger,
        orgTrustDomainsEnabled: Bool = OrgTrustDomainsFeature.isEnabled,
        legacyEnrollmentsAllowed: Bool = OrgSPIREClientRegistry.legacyEnrollmentsAllowedFromEnvironment
    ) {
        self.platform = platform
        self.platformConfig = platformConfig
        self.logger = logger
        self.orgTrustDomainsEnabled = orgTrustDomainsEnabled
        self.legacyEnrollmentsAllowed = legacyEnrollmentsAllowed
    }

    /// Build from the application's configured platform registration service,
    /// or nil when SPIRE registration is not configured at all (in which case
    /// enrollment is already impossible and the caller reports that).
    ///
    /// The platform configuration comes from the installed service rather than
    /// from a fresh environment read: the service is what actually provisions,
    /// so anything that reconfigures it — including a test installing a fake —
    /// must be what org instances inherit from too.
    static func fromApplication(_ app: Application) -> OrgSPIREClientRegistry? {
        guard let platform = app.spireRegistrationService else { return nil }
        return OrgSPIREClientRegistry(
            platform: platform, platformConfig: platform.registrationConfig, logger: app.logger)
    }

    /// The platform trust domain, taken from the service that actually
    /// provisions rather than from `SPIRE_TRUST_DOMAIN`. The two agree today,
    /// but re-reading the environment here would reintroduce exactly the second
    /// source of truth `fromApplication` exists to avoid — and would diverge
    /// the moment anything configures the service from something else.
    private var platformTrustDomain: String { platform.trustDomain }

    /// The SPIRE instance an enrollment in `scope` must be provisioned
    /// against, plus everything the resulting bootstrap command needs.
    ///
    /// - The feature flag off, or the scope's organization not resolvable:
    ///   the platform instance, behaving exactly as before per-org domains.
    /// - The organization's trust domain ready (`active` with a cached
    ///   bundle): that organization's own instance.
    /// - Ready-but-not-yet, i.e. the reconciler has claimed a domain but has
    ///   not finished provisioning it: the platform instance when legacy
    ///   enrollments are allowed, otherwise a 503 telling the operator to wait.
    func resolve(scope: OrganizationScope, on db: Database) async throws -> OrgSPIRESelection {
        guard orgTrustDomainsEnabled else {
            return platformSelection(reason: .featureDisabled)
        }

        // The trust domain follows the *organization*, not the folder: capacity
        // delegated to a folder is still the org's tenancy, and a folder has no
        // CA of its own. So an OU-scoped enrollment resolves to its root org.
        guard let organizationID = try await scope.rootOrganizationID(on: db) else {
            // A dangling folder reference. The scope was validated to exist
            // before this call, so this is a corrupt hierarchy rather than user
            // error — provision in the platform domain rather than fail the
            // enrollment, and say so.
            logger.warning(
                "Enrollment scope has no root organization; provisioning in the platform trust domain",
                metadata: ["scope": .string("\(scope)")])
            return platformSelection(reason: .noOrganization)
        }

        guard
            let row = try await OrgTrustDomain.query(on: db)
                .filter(\.$organizationID == organizationID)
                .first()
        else {
            // Organizations created before the feature was switched on never
            // claimed a domain. They are platform-domain tenants until an
            // operator backfills them (phase 7's migration).
            return platformSelection(reason: .noTrustDomainClaimed(organizationID: organizationID))
        }

        guard row.acceptsIdentities else {
            // `acceptsIdentities` is the same gate `SPIREService` verifies
            // against: phase `active` *and* a cached bundle. Provisioning into
            // a domain the control plane holds no roots for would mint an
            // identity it then refuses on the WebSocket — an agent that
            // enrolls successfully and can never connect.
            guard legacyEnrollmentsAllowed else {
                throw Abort(
                    .serviceUnavailable,
                    reason:
                        "Organization \(organizationID)'s trust domain (\(row.trustDomain)) is not ready yet "
                        + "(phase: \(row.phase.rawValue)\(row.lastError.map { ", last error: \($0)" } ?? "")). "
                        + "Wait for it to become active, or set SPIRE_LEGACY_ENROLLMENTS=true to enroll into the "
                        + "platform trust domain meanwhile."
                )
            }
            logger.notice(
                "Organization trust domain is not ready; falling back to the platform trust domain",
                metadata: [
                    "organizationID": .string(organizationID.uuidString),
                    "trustDomain": .string(row.trustDomain),
                    "phase": .string(row.phase.rawValue),
                ])
            return platformSelection(reason: .trustDomainNotReady(trustDomain: row.trustDomain))
        }

        return try orgSelection(row: row)
    }

    /// The registration service for an already-issued identity's trust domain,
    /// for withdrawing a grant rather than creating one.
    ///
    /// Resolution is by **trust domain**, not by the resource's current
    /// organization: the domain is what was actually provisioned and is baked
    /// into every SVID issued under it, while an agent's org can be reassigned
    /// afterwards (`PATCH /api/agents/:id/organization`). Resolving a
    /// revocation by scope would then aim at the wrong server and quietly
    /// delete nothing, leaving a revoked node able to keep renewing SVIDs.
    ///
    /// Deliberately more permissive than `resolve`: a domain being torn down is
    /// exactly when entries most need removing, so any phase is accepted, and
    /// only the two things a *delete* actually needs are required — an
    /// addressable admin API and roots to verify it with. In particular the
    /// node-attestation address is not required here; it only feeds bootstrap
    /// commands, and demanding it would fail revocation for a half-provisioned
    /// row with a message about the reconciler.
    ///
    /// Returns **nil** when no instance is known for the domain at all, which
    /// is a different situation from "the server is unreachable": there is
    /// nothing to retry, so the caller must decide (via `skipSpireDeprovision`)
    /// whether to proceed. Throws only for a row we *should* be able to reach
    /// but cannot build a client for — callers still fail closed there rather
    /// than report a revocation that did not happen.
    func service(forTrustDomain trustDomain: String, on db: Database) async throws
        -> SPIRERegistrationService?
    {
        guard trustDomain != platformTrustDomain else { return platform }

        guard
            let row = try await OrgTrustDomain.query(on: db)
                .filter(\.$trustDomain == trustDomain)
                .first()
        else {
            // The row is gone — teardown finished, or it was never recorded —
            // while a resource still names the domain. Nothing here can remove
            // the entries, and no amount of retrying will change that.
            return nil
        }
        return try adminService(row: row)
    }

    /// Whether an organization whose trust domain isn't ready may still be
    /// enrolled into the platform domain, as configured.
    ///
    /// Defaults to **true**: switching per-org trust domains on must not brick
    /// enrollment for every organization the reconciler has yet to reach.
    /// Operators flip it off once every organization is provisioned, which is
    /// what makes "no new platform-domain agents" enforceable (phase 7).
    ///
    static var legacyEnrollmentsAllowedFromEnvironment: Bool {
        legacyEnrollmentsAllowed(rawValue: Environment.get("SPIRE_LEGACY_ENROLLMENTS"))
    }

    /// The parsing behind `legacyEnrollmentsAllowedFromEnvironment`, as a pure
    /// function so it can be exercised without `setenv` — which is
    /// process-global and races the other suites swift-testing runs
    /// concurrently.
    ///
    /// Because the default is "allowed", the *disabling* spellings are matched
    /// explicitly rather than by "anything that isn't `true`". The other way
    /// round, `SPIRE_LEGACY_ENROLLMENTS=0` would read as allowed — the opposite
    /// of what an operator writing it means.
    static func legacyEnrollmentsAllowed(rawValue: String?) -> Bool {
        guard let raw = rawValue?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else {
            return true
        }
        return !["false", "0", "no", "off"].contains(raw)
    }

    /// The control plane's own identity. It lives in the platform trust domain
    /// no matter which domain the agent is issued in, so an org-domain agent
    /// cannot derive it from its own trust domain and has to be told.
    private var controlPlaneSPIFFEID: String {
        "spiffe://\(platformTrustDomain)/control-plane"
    }

    private func platformSelection(reason: OrgSPIRESelection.PlatformReason) -> OrgSPIRESelection {
        OrgSPIRESelection(
            service: platform,
            // Same domain on both ends: nothing to federate with.
            federatesWith: [],
            controlPlaneSPIFFEID: controlPlaneSPIFFEID,
            platformFallback: reason
        )
    }

    /// A client for one org's SPIRE admin API — everything an entry mutation
    /// (create *or* delete) needs, and nothing more.
    ///
    /// `serverPublicAddress` is filled from `serverAddress` when the row has
    /// one and left empty otherwise: it is only ever read back out for a
    /// bootstrap command, and `orgSelection` below is what requires it. Keeping
    /// it optional here is what lets revocation work against a row the
    /// reconciler never finished.
    private func adminService(row: OrgTrustDomain) throws -> SPIRERegistrationService {
        guard let nodeAddress = row.nodeAddress, !nodeAddress.isEmpty else {
            throw Abort(
                .serviceUnavailable,
                reason:
                    "Organization trust domain \(row.trustDomain) records no admin API address; "
                    + "the trust-domain reconciler has not finished provisioning it."
            )
        }
        guard let bundlePEM = row.orgBundlePEM else {
            throw Abort(
                .serviceUnavailable,
                reason:
                    "Organization trust domain \(row.trustDomain) has no cached bundle, so its SPIRE server "
                    + "cannot be verified."
            )
        }
        // Per-org SPIRE servers are separate processes reachable only over the
        // network, so the admin API is always the mTLS TCP path — we present
        // the platform SVID and verify the peer against *its* domain's roots
        // (never a union), which is what SPIREServerPeer.trustDomain encodes.
        let address = try SPIREServerAPIAddress(parsing: nodeAddress)
        guard let workloadSocketPath = platformConfig.workloadAPISocketPath else {
            throw Abort(
                .serviceUnavailable,
                reason:
                    "Reaching organization SPIRE server \(row.trustDomain) requires the control plane's own SVID, "
                    + "but SPIFFE_ENDPOINT_SOCKET is not configured."
            )
        }

        let config = SPIRERegistrationConfig(
            trustDomain: row.trustDomain,
            serverAPIAddress: address,
            workloadAPISocketPath: workloadSocketPath,
            serverPublicAddress: row.serverAddress ?? "",
            agentSelectors: platformConfig.agentSelectors,
            svidTTLSeconds: platformConfig.svidTTLSeconds
        )
        let client = SPIREServerAPIClient(
            address: address,
            transportSecurity: .mtls(
                identityProvider: WorkloadAPISVIDSource(socketPath: workloadSocketPath, logger: logger),
                peer: .trustDomain(row.trustDomain, bundlePEM: Self.splitPEM(bundlePEM))
            ),
            logger: logger
        )
        return SPIRERegistrationService(api: client, config: config, logger: logger)
    }

    private func orgSelection(row: OrgTrustDomain) throws -> OrgSPIRESelection {
        // Only enrollment needs this: it is the address the *node* dials to
        // attest, which ends up in the bootstrap command. Checked before
        // building the client so a half-provisioned row fails naming the
        // missing field rather than handing back an unusable command.
        guard let serverAddress = row.serverAddress, !serverAddress.isEmpty else {
            throw Abort(
                .serviceUnavailable,
                reason:
                    "Organization trust domain \(row.trustDomain) is active but records no node attestation "
                    + "address for agents to dial; the trust-domain reconciler has not finished provisioning it."
            )
        }

        return OrgSPIRESelection(
            service: try adminService(row: row),
            // Without this the agent's Workload API would hand it only its own
            // domain's roots, and it could never verify the control plane —
            // whose SVID is signed by the platform CA. This is the entry-level
            // half of the federation the reconciler establishes server-side.
            federatesWith: [platformTrustDomain],
            controlPlaneSPIFFEID: controlPlaneSPIFFEID,
            platformFallback: nil
        )
    }

    /// Split a PEM bundle that may hold several concatenated certificates into
    /// one string per certificate, the form `SPIREServerPeer` expects. Text
    /// between blocks is dropped, so an operator-pasted bundle with headers
    /// still parses.
    static func splitPEM(_ pem: String) -> [String] {
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"
        var certificates: [String] = []
        var remainder = Substring(pem)
        while let start = remainder.range(of: begin), let finish = remainder.range(of: end) {
            guard finish.lowerBound > start.lowerBound else { break }
            certificates.append(String(remainder[start.lowerBound..<finish.upperBound]) + "\n")
            remainder = remainder[finish.upperBound...]
        }
        return certificates
    }
}

/// Which SPIRE instance an enrollment goes to, and the facts the bootstrap
/// command has to carry as a result.
struct OrgSPIRESelection: Sendable {
    /// Why an enrollment landed in the platform trust domain rather than its
    /// organization's own. Nil means it did not — it went to the org instance.
    enum PlatformReason: Sendable {
        /// `SPIRE_ORG_TRUST_DOMAINS_ENABLED` is off: single-domain behavior.
        case featureDisabled
        /// The scope resolved to no organization (a dangling folder).
        case noOrganization
        /// The organization predates the feature and never claimed a domain.
        case noTrustDomainClaimed(organizationID: UUID)
        /// A domain is claimed but the reconciler has not made it usable yet.
        case trustDomainNotReady(trustDomain: String)

        var label: String {
            switch self {
            case .featureDisabled: return "feature-disabled"
            case .noOrganization: return "no-organization"
            case .noTrustDomainClaimed: return "no-trust-domain-claimed"
            case .trustDomainNotReady: return "trust-domain-not-ready"
            }
        }
    }

    /// The registration service to provision against.
    let service: SPIRERegistrationService

    /// Trust domains the provisioned workload entry federates with, so the
    /// node's Workload API hands the agent those domains' bundles alongside
    /// its SVID.
    let federatesWith: [String]

    /// The control plane identity the agent must pin. Always in the platform
    /// trust domain, which is why it is passed explicitly rather than left to
    /// the agent's `spiffe://<own-td>/control-plane` default.
    let controlPlaneSPIFFEID: String

    /// Nil when this is the organization's own instance.
    let platformFallback: PlatformReason?
}
