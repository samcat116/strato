import Fluent
import Vapor

/// A site (availability zone): a group of agents whose hypervisors share a
/// routable underlay and one OVN deployment (NB/SB/northd). A logical network
/// pinned to a site spans that site's nodes over geneve; the site is the OVN
/// blast radius.
///
/// Exactly one agent per site is the **network controller** — the single
/// topology writer for the site's shared northbound DB (switches, routers,
/// NAT, teardown). Every agent in the site still connects to the shared NB to
/// bind its own VMs' ports, but only the controller receives the site's full
/// network list with `networksAuthoritative = true`. The control plane stays
/// out of OVN entirely: it orchestrates over the agent WebSocket, and agents
/// dial out, so nothing here requires inbound reachability to a customer site.
///
/// Agents without a site keep the legacy single-node model: a private local
/// NB they are always authoritative over.
final class Site: Model, Content, @unchecked Sendable {
    static let schema = "sites"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "name")
    var name: String

    @OptionalField(key: "description")
    var description: String?

    /// The agent that authors the site's shared OVN NB topology. Assigned
    /// explicitly by the operator (it is the node running ovn-central, a
    /// deployment-time fact the control plane cannot infer). While unset, no
    /// agent in the site reconciles network topology — VMs still place and
    /// their ports bind, but switches/routers won't be realized.
    @OptionalParent(key: "network_controller_agent_id")
    var networkControllerAgent: Agent?

    /// Owning organization (exactly one of organization / organizational
    /// unit). All agents in a site must share the site's root organization —
    /// a site is one OVN deployment, and dedicated capacity must not mix
    /// tenants on a shared SDN.
    @OptionalParent(key: "organization_id")
    var organization: Organization?

    @OptionalParent(key: "organizational_unit_id")
    var organizationalUnit: OrganizationalUnit?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        name: String,
        description: String? = nil,
        networkControllerAgentID: UUID? = nil,
        organizationScope: OrganizationScope? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.$networkControllerAgent.id = networkControllerAgentID
        self.$organization.id = organizationScope?.organizationID
        self.$organizationalUnit.id = organizationScope?.organizationalUnitID
    }

    /// The site's org-or-OU owner; nil only for rows that predate mandatory
    /// scoping and were never backfilled.
    var organizationScope: OrganizationScope? {
        get {
            if let orgID = self.$organization.id { return .organization(orgID) }
            if let ouID = self.$organizationalUnit.id { return .organizationalUnit(ouID) }
            return nil
        }
        set {
            self.$organization.id = newValue?.organizationID
            self.$organizationalUnit.id = newValue?.organizationalUnitID
        }
    }

    func rootOrganizationID(on db: Database) async throws -> UUID? {
        try await organizationScope?.rootOrganizationID(on: db)
    }
}

// MARK: - Default site

extension Site {
    /// Name of the availability zone auto-created for each organization so a
    /// brand-new org can enroll agents immediately — enrollment requires a
    /// site. Site names are globally unique and organization names are too, so
    /// composing them yields a unique, human-readable default.
    static func defaultName(forOrganizationNamed orgName: String) -> String {
        "\(orgName) Default Site"
    }

    /// Creates the organization's default site. Called when an org is created
    /// (API and bootstrap); pre-existing orgs are covered by the
    /// `BackfillDefaultSites` migration. Org-scoped and controller-less: the
    /// operator designates a network controller once nodes are enrolled.
    @discardableResult
    static func createDefault(
        forOrganization organizationID: UUID, named orgName: String, on db: Database
    ) async throws -> Site {
        let site = Site(
            name: defaultName(forOrganizationNamed: orgName),
            description: "Default availability zone for \(orgName)",
            organizationScope: .organization(organizationID)
        )
        try await site.save(on: db)
        return site
    }
}

// MARK: - DTOs

struct SiteResponse: Content {
    let id: UUID
    let name: String
    let description: String?
    let networkControllerAgentId: UUID?
    let organizationId: UUID?
    let organizationalUnitId: UUID?
    let createdAt: Date?

    init(from site: Site) throws {
        self.id = try site.requireID()
        self.name = site.name
        self.description = site.description
        self.networkControllerAgentId = site.$networkControllerAgent.id
        self.organizationId = site.$organization.id
        self.organizationalUnitId = site.$organizationalUnit.id
        self.createdAt = site.createdAt
    }
}

struct CreateSiteRequest: Content {
    let name: String
    let description: String?
    /// Owning scope; exactly one of the two is required.
    let organizationId: UUID?
    let organizationalUnitId: UUID?
}

/// Full-replace (PUT) semantics: every field is applied as given, so omitting
/// `networkControllerAgentId` clears the designation. Avoids the
/// absent-vs-null decoding ambiguity a PATCH would need.
struct UpdateSiteRequest: Content {
    let description: String?
    let networkControllerAgentId: UUID?
}
