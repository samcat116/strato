import ControlPlanePostgres
import Crypto
import Foundation
import Vapor

/// Application-side bearer generation. Durable enrollment state belongs to
/// `AgentEnrollmentsPersistence`; only its SHA-256 digest crosses that boundary.
enum AgentEnrollment {
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

}

extension AgentEnrollmentSnapshot {
    var organizationScope: OrganizationScope? {
        if let organizationID { return .organization(organizationID) }
        if let organizationalUnitID { return .organizationalUnit(organizationalUnitID) }
        return nil
    }

    var isValid: Bool { isValid() }
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
        from enrollment: AgentEnrollmentSnapshot,
        publicOrigin: String,
        bootstrapToken: String,
        spire: SPIREAgentConfiguration
    ) throws {
        self.id = enrollment.id
        self.agentName = enrollment.agentName
        self.spiffeId = enrollment.spiffeID
        self.expiresAt = enrollment.expiresAt
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

    init(from enrollment: AgentEnrollmentSnapshot) throws {
        self.id = enrollment.id
        self.agentName = enrollment.agentName
        self.spiffeId = enrollment.spiffeID
        self.expiresAt = enrollment.expiresAt
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
