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

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, name: String, description: String? = nil, networkControllerAgentID: UUID? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.$networkControllerAgent.id = networkControllerAgentID
    }
}

// MARK: - DTOs

struct SiteResponse: Content {
    let id: UUID
    let name: String
    let description: String?
    let networkControllerAgentId: UUID?
    let createdAt: Date?

    init(from site: Site) throws {
        self.id = try site.requireID()
        self.name = site.name
        self.description = site.description
        self.networkControllerAgentId = site.$networkControllerAgent.id
        self.createdAt = site.createdAt
    }
}

struct CreateSiteRequest: Content {
    let name: String
    let description: String?
}

/// Full-replace (PUT) semantics: every field is applied as given, so omitting
/// `networkControllerAgentId` clears the designation. Avoids the
/// absent-vs-null decoding ambiguity a PATCH would need.
struct UpdateSiteRequest: Content {
    let description: String?
    let networkControllerAgentId: UUID?
}
