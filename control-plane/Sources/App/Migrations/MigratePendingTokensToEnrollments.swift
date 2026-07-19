import Fluent
import Vapor

/// Carries still-pending SPIRE-provisioned registration tokens over to
/// `agent_enrollments` before the token table is dropped.
///
/// An operator who created a SPIRE-provisioned token but whose node had not yet
/// registered would otherwise be stranded by the upgrade: spire-agent attests
/// first and strato-agent registers second, so the node can still redeem its
/// join token and present a valid SVID — but the only row carrying its
/// organization and site scope would be gone, and registration now reads scope
/// exclusively from `agent_enrollments`. The node would authenticate and then
/// be refused with `missingOrganizationScope`.
///
/// Only rows that can still matter are carried over: a SPIRE grant must exist
/// (without one the node has no way to authenticate at all), the scope must be
/// present, and no `agents` row may already exist for the name — once the agent
/// has registered its scope is durable on that row and this is moot. Expiry is
/// deliberately NOT a filter: an expired join token may already have been
/// redeemed, which is precisely the stranded case.
///
/// Uses private column snapshots rather than the live `AgentEnrollment` model,
/// so a later change to that model cannot retroactively alter what this
/// migration did.
struct MigratePendingTokensToEnrollments: AsyncMigration {
    func prepare(on database: Database) async throws {
        // Matches SPIREServiceConfig's default so a deployment that never set
        // the variable still derives the IDs SPIRE actually issued.
        let trustDomain = Environment.get("SPIRE_TRUST_DOMAIN") ?? "strato.local"

        let tokens = try await TokenRow.query(on: database)
            .filter(\.$spireProvisioned == true)
            .all()
        guard !tokens.isEmpty else { return }

        let registeredNames = Set(try await AgentNameRow.query(on: database).all().map(\.name))
        let enrolledNames = Set(try await EnrollmentRow.query(on: database).all().map(\.agentName))

        // Newest surviving grant per name. `agent_name` is unique on the target
        // table, and a name can own several token rows (successors), so collapse
        // before inserting — including on a created_at tie, which would
        // otherwise fail the migration and block the upgrade outright.
        var newestByName: [String: TokenRow] = [:]
        for token in tokens {
            guard token.organizationID != nil || token.organizationalUnitID != nil else { continue }
            guard !registeredNames.contains(token.agentName) else { continue }
            guard !enrolledNames.contains(token.agentName) else { continue }

            if let existing = newestByName[token.agentName],
                (existing.createdAt ?? .distantPast) >= (token.createdAt ?? .distantPast)
            {
                continue
            }
            newestByName[token.agentName] = token
        }

        guard !newestByName.isEmpty else { return }

        for (name, token) in newestByName {
            let row = EnrollmentRow()
            row.agentName = name
            // The shape SPIRERegistrationService provisions for an agent.
            row.spiffeID = "spiffe://\(trustDomain)/agent/\(name)"
            row.isUsed = false
            row.siteID = token.siteID
            row.organizationID = token.organizationID
            row.organizationalUnitID = token.organizationalUnitID
            row.expiresAt = token.expiresAt
            row.createdAt = token.createdAt ?? Date()
            try await row.create(on: database)
        }

        database.logger.notice(
            "Carried \(newestByName.count) pending SPIRE-provisioned agent registration(s) into agent_enrollments"
        )
    }

    func revert(on database: Database) async throws {
        // Intentionally a no-op. These rows are indistinguishable from natively
        // created enrollments, and the table they came from is dropped by a
        // later migration — deleting them on revert would strip scope from
        // nodes that may since have registered against it.
    }
}

// MARK: - Column snapshots

private final class TokenRow: Model, @unchecked Sendable {
    static let schema = "agent_registration_tokens"

    @ID(key: .id) var id: UUID?
    @Field(key: "agent_name") var agentName: String
    @Field(key: "spire_provisioned") var spireProvisioned: Bool
    @OptionalField(key: "site_id") var siteID: UUID?
    @OptionalField(key: "organization_id") var organizationID: UUID?
    @OptionalField(key: "organizational_unit_id") var organizationalUnitID: UUID?
    @Timestamp(key: "expires_at", on: .none) var expiresAt: Date?
    @Timestamp(key: "created_at", on: .none) var createdAt: Date?

    init() {}
}

private final class EnrollmentRow: Model, @unchecked Sendable {
    static let schema = "agent_enrollments"

    @ID(key: .id) var id: UUID?
    @Field(key: "agent_name") var agentName: String
    @Field(key: "spiffe_id") var spiffeID: String
    @Field(key: "is_used") var isUsed: Bool
    @OptionalField(key: "site_id") var siteID: UUID?
    @OptionalField(key: "organization_id") var organizationID: UUID?
    @OptionalField(key: "organizational_unit_id") var organizationalUnitID: UUID?
    @Timestamp(key: "expires_at", on: .none) var expiresAt: Date?
    @Timestamp(key: "created_at", on: .none) var createdAt: Date?
    @Timestamp(key: "used_at", on: .none) var usedAt: Date?

    init() {}
}

private final class AgentNameRow: Model, @unchecked Sendable {
    static let schema = "agents"

    @ID(key: .id) var id: UUID?
    @Field(key: "name") var name: String

    init() {}
}
