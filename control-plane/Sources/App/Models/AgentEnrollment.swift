import Fluent
import Vapor

/// A SPIRE enrollment for one agent node.
///
/// Enrollment is the operator half of onboarding: creating one provisions the
/// node in SPIRE (a one-time join token plus the workload entry that lets it
/// mint SVIDs) and records the site and organization scope the agent inherits
/// when it registers. Unlike the registration tokens this replaces, the row
/// holds no bearer secret of its own — the agent authenticates with its SVID,
/// and the join token is returned once from the create endpoint and never
/// persisted here.
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

    /// When the SPIRE join token stops being redeemable. The row deliberately
    /// outlives it: once the node has attested, its SVID — not this window — is
    /// what authenticates it, and the row remains as the record of which org
    /// and site the agent was enrolled into.
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
        expirationHours: Int = 1,
        siteID: UUID? = nil,
        organizationScope: OrganizationScope? = nil
    ) {
        self.id = id
        self.agentName = agentName
        self.spiffeID = spiffeID
        self.trustDomain = trustDomain
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

    /// Whether the SPIRE join token is still redeemable — that is, whether a
    /// node that has not yet attested can still do so with this enrollment.
    var isValid: Bool {
        guard let expires = expiresAt else { return false }
        return !isUsed && expires > Date()
    }

    /// Record that the named agent has registered.
    func markAsUsed() {
        self.isUsed = true
        self.usedAt = Date()
    }
}

// MARK: - DTOs for API responses

struct AgentEnrollmentResponse: Content {
    let id: UUID
    let agentName: String
    let spiffeId: String
    let expiresAt: Date
    /// SPIRE node-attestation material. Returned only from the create
    /// endpoint and never listed: the join token is a one-time bearer secret.
    let spire: SPIREProvisioningResponse
    /// Copy-paste one-liner that installs strato-agent and spire-agent, attests
    /// the node with the join token, and points it at this control plane.
    let bootstrapCommand: String

    init(
        from enrollment: AgentEnrollment,
        webSocketBaseURL: String,
        spire: SPIREAgentProvisioning
    ) throws {
        guard let id = enrollment.id else {
            throw Abort(.internalServerError, reason: "Agent enrollment missing ID")
        }

        self.id = id
        self.agentName = enrollment.agentName
        self.spiffeId = enrollment.spiffeID
        self.expiresAt = enrollment.expiresAt ?? Date()
        self.spire = SPIREProvisioningResponse(from: spire)
        // One curl-able installer (deploy/agent/install.sh) does everything:
        // downloads strato-agent + spire-agent, attests the node with the join
        // token, writes the agent config, and sets up host telemetry (Grafana
        // Alloy + spiffe-helper pushing to /ingest/* over mTLS). The agent name
        // is validated to SPIFFE path-segment characters before we get here, so
        // single-quoting it is safe.
        self.bootstrapCommand =
            "curl -fsSL https://raw.githubusercontent.com/samcat116/strato/main/deploy/agent/install.sh"
            + " | sudo bash -s --"
            + " --control-plane-url '\(webSocketBaseURL)/agent/ws'"
            + " --agent-name '\(enrollment.agentName)'"
            + " --spire-join-token '\(spire.joinToken)'"
            + " --spire-server-address '\(spire.serverAddress)'"
            + " --trust-domain '\(spire.trustDomain)'"
    }
}

/// The SPIRE material handed back when an enrollment is created. The join
/// token is a one-time bearer secret: it is returned only from the create
/// endpoint and never persisted or re-exposed.
struct SPIREProvisioningResponse: Content {
    let joinToken: String
    let joinTokenExpiresAt: Date
    let spiffeId: String
    let nodeId: String
    let trustDomain: String
    let serverAddress: String

    init(from provisioning: SPIREAgentProvisioning) {
        self.joinToken = provisioning.joinToken
        self.joinTokenExpiresAt = provisioning.joinTokenExpiresAt
        self.spiffeId = provisioning.spiffeID
        self.nodeId = provisioning.nodeID
        self.trustDomain = provisioning.trustDomain
        self.serverAddress = provisioning.serverAddress
    }
}

/// List-safe view of an enrollment. Deliberately omits everything from the
/// `spire` block: the join token is shown exactly once, at creation time.
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
