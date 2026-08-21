import ControlPlanePostgres
import Foundation
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
/// Namespace for stable schema and identity derivation. Persisted rows are
/// decoded as immutable `OrgTrustDomainRecord` values below.
enum OrgTrustDomain {
    static let schema = "org_trust_domains"

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

/// Immutable persistence result for one organization's SPIRE instance intent.
struct OrgTrustDomainRecord: Decodable, Equatable, Sendable {
    let id: UUID
    let organizationID: UUID
    let trustDomain: String
    let phase: OrgTrustDomainPhase
    let generation: Int64
    let observedGeneration: Int64
    let serverAddress: String?
    let bundleEndpointURL: String?
    let nodeAddress: String?
    let orgBundlePEM: String?
    let lastError: String?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?

    var acceptsIdentities: Bool {
        phase == .active && orgBundlePEM != nil
    }
}

/// Create intent. UUIDs are generated application-side; PostgreSQL supplies
/// lifecycle timestamps and the returned record is authoritative.
struct OrgTrustDomainWrite: Sendable {
    let id: UUID
    let organizationID: UUID
    let trustDomain: String
    let phase: OrgTrustDomainPhase
    let generation: Int64
    let observedGeneration: Int64
    let serverAddress: String?
    let bundleEndpointURL: String?
    let nodeAddress: String?
    let orgBundlePEM: String?
    let lastError: String?
    let deletedAt: Date?

    init(
        id: UUID = UUID(),
        organizationID: UUID,
        trustDomain: String,
        phase: OrgTrustDomainPhase = .pending,
        generation: Int64 = 1,
        observedGeneration: Int64 = 0,
        serverAddress: String? = nil,
        bundleEndpointURL: String? = nil,
        nodeAddress: String? = nil,
        orgBundlePEM: String? = nil,
        lastError: String? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.organizationID = organizationID
        self.trustDomain = trustDomain
        self.phase = phase
        self.generation = generation
        self.observedGeneration = observedGeneration
        self.serverAddress = serverAddress
        self.bundleEndpointURL = bundleEndpointURL
        self.nodeAddress = nodeAddress
        self.orgBundlePEM = orgBundlePEM
        self.lastError = lastError
        self.deletedAt = deletedAt
    }
}

enum OrgTrustDomainStore {
    enum Error: Swift.Error, Sendable {
        case unsupportedDatabase
    }

    private static let columns = """
        id,
        organization_id AS "organizationID",
        trust_domain AS "trustDomain",
        phase::text AS phase,
        generation,
        observed_generation AS "observedGeneration",
        server_address AS "serverAddress",
        bundle_endpoint_url AS "bundleEndpointURL",
        node_address AS "nodeAddress",
        org_bundle_pem AS "orgBundlePEM",
        last_error AS "lastError",
        created_at AS "createdAt",
        updated_at AS "updatedAt",
        deleted_at AS "deletedAt"
        """

    static func find(organizationID: UUID, on db: PostgresStoreContext) async throws -> OrgTrustDomainRecord? {
        let sql = try sqlDatabase(db)
        return try await sql.raw(
            "SELECT \(unsafeRaw: columns) FROM org_trust_domains WHERE organization_id = \(bind: organizationID)"
        ).first(decoding: OrgTrustDomainRecord.self)
    }

    static func find(trustDomain: String, on db: PostgresStoreContext) async throws -> OrgTrustDomainRecord? {
        let sql = try sqlDatabase(db)
        return try await sql.raw(
            "SELECT \(unsafeRaw: columns) FROM org_trust_domains WHERE trust_domain = \(bind: trustDomain)"
        ).first(decoding: OrgTrustDomainRecord.self)
    }

    static func active(on db: PostgresStoreContext) async throws -> [OrgTrustDomainRecord] {
        let sql = try sqlDatabase(db)
        return try await sql.raw(
            "SELECT \(unsafeRaw: columns) FROM org_trust_domains WHERE phase = 'active' ORDER BY id"
        ).all(decoding: OrgTrustDomainRecord.self)
    }

    @discardableResult
    static func insert(_ write: OrgTrustDomainWrite, on db: PostgresStoreContext) async throws
        -> OrgTrustDomainRecord
    {
        let sql = try sqlDatabase(db)
        guard let record = try await sql.raw(
            """
            INSERT INTO org_trust_domains (
                id, organization_id, trust_domain, phase, generation, observed_generation,
                server_address, bundle_endpoint_url, node_address, org_bundle_pem,
                last_error, created_at, updated_at, deleted_at
            ) VALUES (
                \(bind: write.id), \(bind: write.organizationID), \(bind: write.trustDomain),
                \(bind: write.phase.rawValue)::org_trust_domain_phase, \(bind: write.generation),
                \(bind: write.observedGeneration), \(bind: write.serverAddress),
                \(bind: write.bundleEndpointURL), \(bind: write.nodeAddress),
                \(bind: write.orgBundlePEM), \(bind: write.lastError),
                CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, \(bind: write.deletedAt)
            )
            RETURNING \(unsafeRaw: columns)
            """
        ).first(decoding: OrgTrustDomainRecord.self) else {
            throw Abort(.internalServerError, reason: "Trust-domain insert returned no row")
        }
        return record
    }

    /// Full state replacement used by the reconciler-facing contract tests.
    /// The immutable identity and trust-domain columns are intentionally absent.
    @discardableResult
    static func updateState(
        id: UUID,
        phase: OrgTrustDomainPhase,
        generation: Int64,
        observedGeneration: Int64,
        serverAddress: String?,
        bundleEndpointURL: String?,
        nodeAddress: String?,
        orgBundlePEM: String?,
        lastError: String?,
        deletedAt: Date?,
        on db: PostgresStoreContext
    ) async throws -> OrgTrustDomainRecord? {
        let sql = try sqlDatabase(db)
        return try await sql.raw(
            """
            UPDATE org_trust_domains
            SET phase = \(bind: phase.rawValue)::org_trust_domain_phase,
                generation = \(bind: generation),
                observed_generation = \(bind: observedGeneration),
                server_address = \(bind: serverAddress),
                bundle_endpoint_url = \(bind: bundleEndpointURL),
                node_address = \(bind: nodeAddress),
                org_bundle_pem = \(bind: orgBundlePEM),
                last_error = \(bind: lastError),
                deleted_at = \(bind: deletedAt),
                updated_at = CURRENT_TIMESTAMP
            WHERE id = \(bind: id)
            RETURNING \(unsafeRaw: columns)
            """
        ).first(decoding: OrgTrustDomainRecord.self)
    }

    /// Atomically records teardown intent and advances its convergence key.
    @discardableResult
    static func markForTeardown(organizationID: UUID, on db: PostgresStoreContext) async throws
        -> OrgTrustDomainRecord?
    {
        let sql = try sqlDatabase(db)
        return try await sql.raw(
            """
            UPDATE org_trust_domains
            SET phase = 'deleting', deleted_at = CURRENT_TIMESTAMP, last_error = NULL,
                generation = generation + 1, updated_at = CURRENT_TIMESTAMP
            WHERE organization_id = \(bind: organizationID)
            RETURNING \(unsafeRaw: columns)
            """
        ).first(decoding: OrgTrustDomainRecord.self)
    }

    static func count(organizationID: UUID, on db: PostgresStoreContext) async throws -> Int {
        struct CountRow: Decodable { let count: Int }
        let sql = try sqlDatabase(db)
        return try await sql.raw(
            "SELECT COUNT(*)::bigint AS count FROM org_trust_domains WHERE organization_id = \(bind: organizationID)"
        ).first(decoding: CountRow.self)?.count ?? 0
    }

    private static func sqlDatabase(_ db: PostgresStoreContext) throws -> PostgresStoreContext {
        guard let sql = db as? PostgresStoreContext else { throw Error.unsupportedDatabase }
        return sql
    }
}
