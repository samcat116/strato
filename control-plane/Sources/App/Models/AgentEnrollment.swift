import Fluent
import Crypto
import Foundation
import SQLKit
import Vapor

/// A SPIRE enrollment for one agent node.
///
/// Enrollment is the operator half of onboarding: creating one prepares the
/// SPIRE workload entry that lets the node mint SVIDs and records the site and
/// organization scope the agent inherits when it registers. The row stores
/// only a hash of the short-lived bootstrap bearer. A SPIRE join token is
/// minted just in time when that bearer is redeemed and is never persisted
/// here; after installation the agent authenticates only with its SVID.
/// Safety: this mutable Fluent model stays inside one logical operation; child tasks
/// receive IDs or immutable snapshots and reload their own instance.
final class AgentEnrollment: Model, Content, @unchecked Sendable {
    static let schema = "agent_enrollments"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "agent_name")
    var agentName: String

    /// Trust domain the node is enrolled into. Enrollment names are unique
    /// *within* a domain, not globally: once each organization has its own
    /// trust domain (issue #613), two organizations may each enroll `agent-1`
    /// and neither may shadow the other.
    @Field(key: "trust_domain")
    var trustDomain: String

    /// SPIFFE ID provisioned for this node. Recorded so listing and revocation
    /// can show the identity without a round trip to the SPIRE server.
    @Field(key: "spiffe_id")
    var spiffeID: String

    /// SHA-256 of the short-lived bearer token used only to fetch the
    /// server-owned bootstrap configuration. The raw token is returned once
    /// at creation and never persisted. Nullable so enrollments created before
    /// the one-token bootstrap cutover remain readable but cannot be redeemed
    /// through the new endpoint.
    @OptionalField(key: "bootstrap_token_hash")
    var bootstrapTokenHash: String?

    /// Whether the named agent has completed registration at least once.
    /// Informational only — nothing gates on it. An enrollment is not a
    /// single-use credential: it is a scope record that the agent's first
    /// registration reads and then leaves in place.
    @Field(key: "is_used")
    var isUsed: Bool

    /// Site the agent joins, read when its agent row is first created. Durable
    /// on that row afterwards and deliberately NOT re-read on reconnect, so an
    /// operator who later moves the agent to another site is not overruled by
    /// this value on the agent's next connection.
    @OptionalField(key: "site_id")
    var siteID: UUID?

    /// Owning organization scope (exactly one of the two), read alongside
    /// `siteID` when the agent row is first created. A brand-new agent whose
    /// enrollment carries no scope is REFUSED registration: unowned dedicated
    /// capacity would be schedulable by no one.
    @OptionalField(key: "organization_id")
    var organizationID: UUID?

    @OptionalField(key: "organizational_unit_id")
    var organizationalUnitID: UUID?

    /// When the bootstrap bearer stops being redeemable. Any SPIRE join token
    /// minted from it is capped to the same deadline. The row deliberately
    /// outlives the window as the record of which org and site the agent was
    /// enrolled into.
    @Timestamp(key: "expires_at", on: .none)
    var expiresAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "used_at", on: .none)
    var usedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        agentName: String,
        spiffeID: String,
        trustDomain: String = PlatformTrustDomain.current,
        bootstrapTokenHash: String? = nil,
        expirationHours: Int = 1,
        siteID: UUID? = nil,
        organizationScope: OrganizationScope? = nil
    ) {
        self.id = id
        self.agentName = agentName
        self.spiffeID = spiffeID
        self.trustDomain = trustDomain
        self.bootstrapTokenHash = bootstrapTokenHash
        self.isUsed = false
        self.siteID = siteID
        self.organizationID = organizationScope?.organizationID
        self.organizationalUnitID = organizationScope?.organizationalUnitID
        self.expiresAt = Date().addingTimeInterval(TimeInterval(expirationHours * 3600))
    }

    /// The scope a registering agent inherits.
    var organizationScope: OrganizationScope? {
        if let orgID = organizationID { return .organization(orgID) }
        if let ouID = organizationalUnitID { return .organizationalUnit(ouID) }
        return nil
    }

    /// Whether the unclaimed bootstrap bearer can still be exchanged for
    /// configuration and its single SPIRE join token.
    var isValid: Bool {
        guard bootstrapTokenHash != nil, let expires = expiresAt else { return false }
        return !isUsed && expires > Date()
    }

    /// A bootstrap token carries no configuration. It is only a high-entropy
    /// lookup credential whose hash identifies this enrollment.
    static func generateBootstrapToken() -> String {
        let key = SymmetricKey(size: .bits256)
        let random = key.withUnsafeBytes { Data($0) }
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "enroll_v1_\(random)"
    }

    static func hashBootstrapToken(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func findByBootstrapToken(_ token: String, on db: Database) async throws
        -> AgentEnrollment?
    {
        guard token.hasPrefix("enroll_v1_") else { return nil }
        return try await AgentEnrollment.query(on: db)
            .filter(\.$bootstrapTokenHash == hashBootstrapToken(token))
            .first()
    }

    /// Atomically claims an unexpired bearer before SPIRE mints any node
    /// credential. The conditional update is the security boundary: concurrent
    /// replays may all read the row, but exactly one can clear its unique hash
    /// and proceed. A failed mint deliberately does not restore the bearer;
    /// issuing another enrollment is safer than creating two node credentials.
    static func claimBootstrapToken(
        _ token: String, on db: any Database, now: Date = Date()
    ) async throws -> Bool {
        guard token.hasPrefix("enroll_v1_") else { return false }
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Agent enrollment requires an SQL database")
        }

        let claimed = try await sql.raw(
            """
            UPDATE \(ident: schema)
            SET bootstrap_token_hash = NULL
            WHERE bootstrap_token_hash = \(bind: hashBootstrapToken(token))
              AND is_used = FALSE
              AND expires_at > \(bind: now)
            RETURNING id
            """
        ).all()
        return claimed.count == 1
    }

    /// Record that the named agent has registered.
    func markAsUsed() {
        self.isUsed = true
        self.usedAt = Date()
        self.bootstrapTokenHash = nil
    }
}

// MARK: - DTOs for API responses

struct AgentEnrollmentResponse: Content {
    let id: UUID
    let agentName: String
    let spiffeId: String
    let expiresAt: Date
    let trustDomain: String
    let spireServerAddress: String
    /// Short-lived bearer token used by the installer to fetch the rest of the
    /// bootstrap configuration. Returned once and stored only as a hash.
    let bootstrapToken: String
    /// Copy-paste one-liner that installs strato-agent and spire-agent, attests
    /// the node with the join token, and points it at this control plane.
    let bootstrapCommand: String

    init(
        from enrollment: AgentEnrollment,
        publicOrigin: String,
        bootstrapToken: String,
        spire: SPIREAgentConfiguration
    ) throws {
        guard let id = enrollment.id else {
            throw Abort(.internalServerError, reason: "Agent enrollment missing ID")
        }

        self.id = id
        self.agentName = enrollment.agentName
        self.spiffeId = enrollment.spiffeID
        self.expiresAt = enrollment.expiresAt ?? Date()
        self.trustDomain = spire.trustDomain
        self.spireServerAddress = spire.serverAddress
        self.bootstrapToken = bootstrapToken
        // The public installer wrapper fixes the control-plane origin. The
        // operator supplies only the opaque token; every identity and network
        // value is selected again by the control plane when it is redeemed.
        let installerURL = "\(publicOrigin)/api/agent-enrollments/install"
        self.bootstrapCommand =
            "curl -fsSL \(Self.shellQuote(installerURL))"
            + " | sudo bash -s -- \(Self.shellQuote(bootstrapToken))"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

/// The private line protocol consumed before the installer can assume `jq` or
/// any Strato binary exists. Every value is base64 encoded on its own line, so
/// URLs and future punctuation never acquire shell parsing semantics.
struct AgentBootstrapBundle: Sendable {
    static let mediaType = "application/vnd.strato.agent-bootstrap.v1"

    let controlPlaneURL: String
    let agentName: String
    let joinToken: String
    let spireServerAddress: String
    let trustDomain: String
    let controlPlaneSPIFFEID: String

    func serialized() -> String {
        let values = [
            controlPlaneURL, agentName, joinToken, spireServerAddress, trustDomain,
            controlPlaneSPIFFEID,
        ]
        return (["STRATO_AGENT_BOOTSTRAP_V1"] + values.map(Self.encode)).joined(separator: "\n") + "\n"
    }

    private static func encode(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }
}

/// List-safe view of an enrollment. Deliberately omits the bootstrap token,
/// which is shown exactly once at creation time.
struct AgentEnrollmentListItem: Content {
    let id: UUID
    let agentName: String
    let spiffeId: String
    let expiresAt: Date
    let isUsed: Bool
    let isValid: Bool
    let organizationId: UUID?
    let organizationalUnitId: UUID?
    let createdAt: Date?
    let usedAt: Date?

    init(from enrollment: AgentEnrollment) throws {
        guard let id = enrollment.id else {
            throw Abort(.internalServerError, reason: "Agent enrollment missing ID")
        }

        self.id = id
        self.agentName = enrollment.agentName
        self.spiffeId = enrollment.spiffeID
        self.expiresAt = enrollment.expiresAt ?? Date()
        self.isUsed = enrollment.isUsed
        self.isValid = enrollment.isValid
        self.organizationId = enrollment.organizationID
        self.organizationalUnitId = enrollment.organizationalUnitID
        self.createdAt = enrollment.createdAt
        self.usedAt = enrollment.usedAt
    }
}

struct CreateAgentEnrollmentRequest: Content {
    let agentName: String
    let expirationHours: Int?
    /// Site the agent joins on registration. Required: every newly enrolled
    /// agent must be placed in an availability zone so its networking has a
    /// single owning OVN deployment — there is no longer a site-less enrollment
    /// path. The site must belong to the same organization as the enrollment's
    /// scope. (The column itself stays nullable for pre-existing rows and the
    /// registration-time inheritance path.)
    let siteId: UUID?
    /// Owning scope the agent inherits at registration; exactly one of the two
    /// is required.
    let organizationId: UUID?
    let organizationalUnitId: UUID?

    /// Characters SPIRE accepts in a SPIFFE ID path segment. Validated here so
    /// a bad agent name fails as a 400 rather than a 502 relayed from the
    /// SPIRE server — and so the name is safe to single-quote into the
    /// bootstrap command.
    private static let allowedNameCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")

    /// The validated one-of org/OU scope.
    func organizationScope() throws -> OrganizationScope {
        guard
            let scope = try OrganizationScope.from(
                organizationID: organizationId, organizationalUnitID: organizationalUnitId)
        else {
            throw Abort(.badRequest, reason: "Either organizationId or organizationalUnitId is required")
        }
        return scope
    }

    func validate() throws {
        guard !agentName.isEmpty else {
            throw Abort(.badRequest, reason: "Agent name is required")
        }

        guard agentName.count <= 100 else {
            throw Abort(.badRequest, reason: "Agent name must be 100 characters or less")
        }

        guard agentName.unicodeScalars.allSatisfy({ Self.allowedNameCharacters.contains($0) }) else {
            throw Abort(
                .badRequest,
                reason: "Agent name must contain only ASCII letters, digits, '-', '_', or '.'")
        }

        if let hours = expirationHours {
            guard hours > 0 && hours <= 168 else {  // Max 1 week
                throw Abort(.badRequest, reason: "Expiration hours must be between 1 and 168 (1 week)")
            }
        }

        _ = try organizationScope()

        // Every enrollment now joins a site: an agent's networking must have a
        // single owning OVN deployment, so operators pick the availability zone
        // up front rather than leaving the node site-less.
        guard siteId != nil else {
            throw Abort(.badRequest, reason: "A site is required to enroll an agent")
        }
    }
}
