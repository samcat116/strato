import Fluent
import Vapor

/// Operational lifecycle of a `Site`. String-backed so it stores as a plain
/// column and round-trips over JSON as a stable slug.
enum SiteStatus: String, Codable, CaseIterable, Sendable {
    /// Normal operation — the default for a newly created site.
    case active
    /// Being wound down: operators should stop placing new capacity here.
    case draining
    /// Temporarily out for planned work.
    case maintenance
    /// Retired; kept for history rather than deleted.
    case decommissioned
}

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

    /// Operational lifecycle of the availability zone. Advisory today (nothing
    /// in scheduling reads it yet), but it gives operators a first-class way to
    /// quiesce a site — `draining`/`maintenance` mark "don't grow this zone"
    /// without deleting it, and `decommissioned` records a retired zone that is
    /// kept for history. Defaults to `active`.
    @Enum(key: "status")
    var status: SiteStatus

    // MARK: Location (advisory)
    //
    // A site is a logical OVN blast radius, not necessarily a physical place,
    // so every location field is optional and purely descriptive: map display,
    // "nearest zone" hints, region grouping. Nothing here is authoritative
    // infrastructure — an operator can leave it all unset.

    /// Decimal degrees, WGS84, range −90…90. Paired with `longitude`.
    @OptionalField(key: "latitude")
    var latitude: Double?

    /// Decimal degrees, WGS84, range −180…180. Paired with `latitude`.
    @OptionalField(key: "longitude")
    var longitude: Double?

    /// Human-readable location ("Equinix DC1, Ashburn VA") — lat/long alone is
    /// unreadable in a UI, and many logical zones have a place name but no
    /// meaningful coordinates.
    @OptionalField(key: "location_label")
    var locationLabel: String?

    /// Short operator-defined region/zone slug (e.g. `us-east-1`) for compact
    /// display and future affinity rules. Free-form; not validated against any
    /// canonical region list.
    @OptionalField(key: "region_code")
    var regionCode: String?

    /// Free-form operator labels — the escape hatch that keeps the next
    /// "can we add field X to sites" from needing a migration. Intended for
    /// grouping, cost attribution, and future scheduler affinity/anti-affinity
    /// rules. Empty map (never null) when unset.
    @Field(key: "labels")
    var labels: [String: String]

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
        status: SiteStatus = .active,
        latitude: Double? = nil,
        longitude: Double? = nil,
        locationLabel: String? = nil,
        regionCode: String? = nil,
        labels: [String: String] = [:],
        networkControllerAgentID: UUID? = nil,
        organizationScope: OrganizationScope? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.status = status
        self.latitude = latitude
        self.longitude = longitude
        self.locationLabel = locationLabel
        self.regionCode = regionCode
        self.labels = labels
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
    let status: SiteStatus
    let latitude: Double?
    let longitude: Double?
    let locationLabel: String?
    let regionCode: String?
    let labels: [String: String]
    let networkControllerAgentId: UUID?
    let organizationId: UUID?
    let organizationalUnitId: UUID?
    let createdAt: Date?
    let updatedAt: Date?

    init(from site: Site) throws {
        self.id = try site.requireID()
        self.name = site.name
        self.description = site.description
        self.status = site.status
        self.latitude = site.latitude
        self.longitude = site.longitude
        self.locationLabel = site.locationLabel
        self.regionCode = site.regionCode
        self.labels = site.labels
        self.networkControllerAgentId = site.$networkControllerAgent.id
        self.organizationId = site.$organization.id
        self.organizationalUnitId = site.$organizationalUnit.id
        self.createdAt = site.createdAt
        self.updatedAt = site.updatedAt
    }
}

struct CreateSiteRequest: Content {
    let name: String
    let description: String?
    /// Owning scope; exactly one of the two is required.
    let organizationId: UUID?
    let organizationalUnitId: UUID?
    /// Optional lifecycle at creation; defaults to `.active` when omitted.
    let status: SiteStatus?
    let latitude: Double?
    let longitude: Double?
    let locationLabel: String?
    let regionCode: String?
    let labels: [String: String]?

    init(
        name: String,
        description: String? = nil,
        organizationId: UUID? = nil,
        organizationalUnitId: UUID? = nil,
        status: SiteStatus? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        locationLabel: String? = nil,
        regionCode: String? = nil,
        labels: [String: String]? = nil
    ) {
        self.name = name
        self.description = description
        self.organizationId = organizationId
        self.organizationalUnitId = organizationalUnitId
        self.status = status
        self.latitude = latitude
        self.longitude = longitude
        self.locationLabel = locationLabel
        self.regionCode = regionCode
        self.labels = labels
    }
}

/// Full-replace (PUT) semantics for descriptive fields: `description`,
/// `networkControllerAgentId`, the location fields, and `labels` are all
/// applied as given, so omitting one clears it (labels omitted → empty map).
/// Avoids the absent-vs-null decoding ambiguity a PATCH would need.
///
/// `status` is the deliberate exception: it has no natural "cleared" value and
/// resetting a drained/maintenance site to `active` on an unrelated edit would
/// be a real footgun, so an omitted `status` leaves the current value
/// unchanged. Send it explicitly to change it.
struct UpdateSiteRequest: Content {
    let description: String?
    let networkControllerAgentId: UUID?
    let status: SiteStatus?
    let latitude: Double?
    let longitude: Double?
    let locationLabel: String?
    let regionCode: String?
    let labels: [String: String]?

    init(
        description: String? = nil,
        networkControllerAgentId: UUID? = nil,
        status: SiteStatus? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        locationLabel: String? = nil,
        regionCode: String? = nil,
        labels: [String: String]? = nil
    ) {
        self.description = description
        self.networkControllerAgentId = networkControllerAgentId
        self.status = status
        self.latitude = latitude
        self.longitude = longitude
        self.locationLabel = locationLabel
        self.regionCode = regionCode
        self.labels = labels
    }
}
