import Fluent
import Vapor

final class AgentRegistrationToken: Model, Content, @unchecked Sendable {
    static let schema = "agent_registration_tokens"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "token")
    var token: String

    @Field(key: "agent_name")
    var agentName: String

    @Field(key: "is_used")
    var isUsed: Bool

    /// Whether creating this token also provisioned the node in SPIRE (join
    /// token + workload entry). Grant ownership during revocation is decided
    /// from this recorded fact, never from the current process configuration.
    @Field(key: "spire_provisioned")
    var spireProvisioned: Bool

    /// Site the agent joins when it redeems this token. Applied to the agent
    /// row at registration and durable there afterwards, so rotated reconnect
    /// tokens deliberately don't carry it (nil never clears an assignment).
    @OptionalField(key: "site_id")
    var siteID: UUID?

    /// Owning organization scope (exactly one of the two on freshly minted
    /// tokens) the agent inherits when it redeems this token. Like `siteID`,
    /// the assignment is durable on the agent row, so rotated reconnect tokens
    /// deliberately don't carry it — but unlike the site, a brand-new agent is
    /// REFUSED registration when its token has no scope: unowned dedicated
    /// capacity would be schedulable by no one.
    @OptionalField(key: "organization_id")
    var organizationID: UUID?

    @OptionalField(key: "organizational_unit_id")
    var organizationalUnitID: UUID?

    @Timestamp(key: "expires_at", on: .none)
    var expiresAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "used_at", on: .none)
    var usedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        token: String = UUID().uuidString,
        agentName: String,
        expirationHours: Int = 1,
        spireProvisioned: Bool = false,
        siteID: UUID? = nil,
        organizationScope: OrganizationScope? = nil
    ) {
        self.id = id
        self.token = token
        self.agentName = agentName
        self.isUsed = false
        self.spireProvisioned = spireProvisioned
        self.siteID = siteID
        self.organizationID = organizationScope?.organizationID
        self.organizationalUnitID = organizationScope?.organizationalUnitID
        self.expiresAt = Date().addingTimeInterval(TimeInterval(expirationHours * 3600))
    }

    /// The scope the redeeming agent inherits; nil on rotated reconnect tokens
    /// and rows predating mandatory scoping.
    var organizationScope: OrganizationScope? {
        if let orgID = organizationID { return .organization(orgID) }
        if let ouID = organizationalUnitID { return .organizationalUnit(ouID) }
        return nil
    }

    /// Check if the token is valid (not used and not expired)
    var isValid: Bool {
        guard let expires = expiresAt else { return false }
        return !isUsed && expires > Date()
    }

    /// Mark the token as used
    func markAsUsed() {
        self.isUsed = true
        self.usedAt = Date()
    }
}

// MARK: - DTO for API responses

struct AgentRegistrationTokenResponse: Content {
    let id: UUID
    let token: String
    let agentName: String
    let registrationURL: String
    let expiresAt: Date
    let isValid: Bool
    /// SPIRE node-attestation material, present only when the control plane
    /// provisions SPIRE as part of registration. Returned once, never listed.
    let spire: SPIREProvisioningResponse?
    /// Copy-paste one-liner for bootstrapping the node (spire-agent
    /// attestation + strato-agent join). Present only with `spire`.
    let bootstrapCommand: String?

    init(from tokenModel: AgentRegistrationToken, baseURL: String, spire: SPIREAgentProvisioning? = nil) throws {
        guard let id = tokenModel.id else {
            throw Abort(.internalServerError, reason: "Registration token missing ID")
        }

        self.id = id
        self.token = tokenModel.token
        self.agentName = tokenModel.agentName
        guard let encodedName = tokenModel.agentName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else {
            throw Abort(.internalServerError, reason: "Invalid agent name for URL encoding")
        }
        self.registrationURL = "\(baseURL)/agent/ws?token=\(tokenModel.token)&name=\(encodedName)"
        self.expiresAt = tokenModel.expiresAt ?? Date()
        self.isValid = tokenModel.isValid

        if let spire {
            self.spire = SPIREProvisioningResponse(from: spire)
            self.bootstrapCommand =
                "sudo strato-node-bootstrap"
                + " --registration-url '\(self.registrationURL)'"
                + " --spire-join-token '\(spire.joinToken)'"
                + " --spire-server-address '\(spire.serverAddress)'"
                + " --trust-domain '\(spire.trustDomain)'"
        } else {
            self.spire = nil
            self.bootstrapCommand = nil
        }
    }
}

/// The SPIRE half of a registration response. Like the WebSocket token, the
/// join token is a one-time bearer secret: it is returned only from the
/// create endpoint and never persisted or re-exposed.
struct SPIREProvisioningResponse: Content {
    let joinToken: String
    let joinTokenExpiresAt: Date
    let spiffeID: String
    let nodeID: String
    let trustDomain: String
    let serverAddress: String

    init(from provisioning: SPIREAgentProvisioning) {
        self.joinToken = provisioning.joinToken
        self.joinTokenExpiresAt = provisioning.joinTokenExpiresAt
        self.spiffeID = provisioning.spiffeID
        self.nodeID = provisioning.nodeID
        self.trustDomain = provisioning.trustDomain
        self.serverAddress = provisioning.serverAddress
    }
}

/// List-safe view of a registration token. Deliberately omits the plaintext
/// `token` and the `registrationURL` that embeds it: the secret is returned only
/// once, from the create endpoint. Listing tokens must not re-expose it.
struct AgentRegistrationTokenListItem: Content {
    let id: UUID
    let agentName: String
    let expiresAt: Date
    let isUsed: Bool
    let isValid: Bool
    let organizationId: UUID?
    let organizationalUnitId: UUID?
    let createdAt: Date?
    let usedAt: Date?

    init(from tokenModel: AgentRegistrationToken) throws {
        guard let id = tokenModel.id else {
            throw Abort(.internalServerError, reason: "Registration token missing ID")
        }

        self.id = id
        self.agentName = tokenModel.agentName
        self.expiresAt = tokenModel.expiresAt ?? Date()
        self.isUsed = tokenModel.isUsed
        self.isValid = tokenModel.isValid
        self.organizationId = tokenModel.organizationID
        self.organizationalUnitId = tokenModel.organizationalUnitID
        self.createdAt = tokenModel.createdAt
        self.usedAt = tokenModel.usedAt
    }
}

struct CreateAgentRegistrationTokenRequest: Content {
    let agentName: String
    let expirationHours: Int?
    /// Site the agent joins on registration; omitted keeps the agent site-less
    /// (legacy single-node OVN model). The site must belong to the same
    /// organization as the token's scope.
    let siteId: UUID?
    /// Owning scope the agent inherits at registration; exactly one of the two
    /// is required.
    let organizationId: UUID?
    let organizationalUnitId: UUID?

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

        if let hours = expirationHours {
            guard hours > 0 && hours <= 168 else {  // Max 1 week
                throw Abort(.badRequest, reason: "Expiration hours must be between 1 and 168 (1 week)")
            }
        }

        _ = try organizationScope()
    }
}
