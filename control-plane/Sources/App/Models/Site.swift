import ControlPlanePostgres
import Fluent
import Foundation
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
/// Immutable application snapshot of one site.
///
/// Native PostgresNIO persistence owns writes and HTTP reads. The explicit
/// legacy store below this layer exists only while the remaining Fluent
/// aggregates are migrated and need a site lookup on their pinned transaction.
package struct Site: Content, Equatable, Sendable {
    static let schema = "sites"

    let id: UUID?
    let name: String
    let description: String?

    /// Operational lifecycle of the availability zone. Advisory today (nothing
    /// in scheduling reads it yet), but it gives operators a first-class way to
    /// quiesce a site — `draining`/`maintenance` mark "don't grow this zone"
    /// without deleting it, and `decommissioned` records a retired zone that is
    /// kept for history. Defaults to `active`.
    let status: SiteStatus

    // MARK: Location (advisory)
    //
    // A site is a logical OVN blast radius, not necessarily a physical place,
    // so every location field is optional and purely descriptive: map display,
    // "nearest zone" hints, region grouping. Nothing here is authoritative
    // infrastructure — an operator can leave it all unset.

    /// Decimal degrees, WGS84, range −90…90. Paired with `longitude`.
    let latitude: Double?

    /// Decimal degrees, WGS84, range −180…180. Paired with `latitude`.
    let longitude: Double?

    /// Human-readable location ("Equinix DC1, Ashburn VA") — lat/long alone is
    /// unreadable in a UI, and many logical zones have a place name but no
    /// meaningful coordinates.
    let locationLabel: String?

    /// Short operator-defined region/zone slug (e.g. `us-east-1`) for compact
    /// display and future affinity rules. Free-form; not validated against any
    /// canonical region list.
    let regionCode: String?

    /// Free-form operator labels — the escape hatch that keeps the next
    /// "can we add field X to sites" from needing a migration. Intended for
    /// grouping, cost attribution, and future scheduler affinity/anti-affinity
    /// rules. Empty map (never null) when unset.
    let labels: [String: String]

    /// The agent that authors the site's shared OVN NB topology. Claimed by the
    /// site's first OVN-capable member (`SiteNetworkAuthority.designateIfUnset`)
    /// and changeable by the operator through `PUT /api/sites/:id`. While unset
    /// — or while the designated agent is offline or no longer able to author —
    /// no agent in the site reconciles network topology: VMs still place and
    /// their ports bind, but switches/routers won't be realized, which is why
    /// the preconditions built on `SiteNetworkAuthority.refusal` reject new
    /// topology-dependent work rather than accept a 202 that can't complete.
    let networkControllerAgentID: UUID?

    /// Owning organization (exactly one of organization / organizational
    /// unit). All agents in a site must share the site's root organization —
    /// a site is one OVN deployment, and dedicated capacity must not mix
    /// tenants on a shared SDN.
    let organizationID: UUID?
    let organizationalUnitID: UUID?
    let createdAt: Date?
    let updatedAt: Date?

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
        organizationScope: OrganizationScope? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id ?? UUID()
        self.name = name
        self.description = description
        self.status = status
        self.latitude = latitude
        self.longitude = longitude
        self.locationLabel = locationLabel
        self.regionCode = regionCode
        self.labels = labels
        self.networkControllerAgentID = networkControllerAgentID
        self.organizationID = organizationScope?.organizationID
        self.organizationalUnitID = organizationScope?.organizationalUnitID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from snapshot: SiteSnapshot) throws {
        guard let status = SiteStatus(rawValue: snapshot.status) else {
            throw Abort(
                .internalServerError,
                reason: "Site has invalid status '\(snapshot.status)'")
        }
        self.id = snapshot.id
        self.name = snapshot.name
        self.description = snapshot.description
        self.status = status
        self.latitude = snapshot.latitude
        self.longitude = snapshot.longitude
        self.locationLabel = snapshot.locationLabel
        self.regionCode = snapshot.regionCode
        self.labels = snapshot.labels
        self.networkControllerAgentID = snapshot.networkControllerAgentID
        self.organizationID = snapshot.organizationID
        self.organizationalUnitID = snapshot.organizationalUnitID
        self.createdAt = snapshot.createdAt
        self.updatedAt = snapshot.updatedAt
    }

    /// The site's org-or-OU owner; nil only for rows that predate mandatory
    /// scoping and were never backfilled.
    var organizationScope: OrganizationScope? {
        if let organizationID { return .organization(organizationID) }
        if let organizationalUnitID { return .organizationalUnit(organizationalUnitID) }
        return nil
    }

    func rootOrganizationID(on db: Database) async throws -> UUID? {
        try await organizationScope?.rootOrganizationID(on: db)
    }

    func requireID() throws -> UUID {
        guard let id else {
            throw Abort(.internalServerError, reason: "Site has no identifier")
        }
        return id
    }

    /// Transitional test-builder convenience. Production writes use
    /// `SitesPersistence` through the native persistence root.
    @discardableResult
    func save(on db: any Database) async throws -> Self {
        try await LegacySiteStore.insert(self, on: db)
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
    /// The designated controller's heartbeat-derived status; nil when the site
    /// designates none. Reported the moment the heartbeat lapses, so the site
    /// page shows a controller going quiet before the API starts refusing work.
    let networkControllerStatus: AgentStatus?
    /// Why the designation cannot author topology right now, in the same words
    /// the 409 uses; nil while it can. Non-nil means new networked workloads,
    /// site-pinned networks and floating-IP attaches in this site are being
    /// refused (issue #833).
    let networkControllerIssue: String?
    let organizationId: UUID?
    let organizationalUnitId: UUID?
    let createdAt: Date?
    let updatedAt: Date?

    /// `controller` is the designated agent's row, loaded by the caller (the
    /// list endpoint batches them). Required rather than optional-with-default
    /// so no producer can accidentally report a sick controller as healthy.
    init(from site: Site, controller: Agent?) throws {
        let health = SiteNetworkAuthority.controllerHealth(controller: controller)
        self.networkControllerStatus = health.status
        self.networkControllerIssue = health.issue
        self.id = try site.requireID()
        self.name = site.name
        self.description = site.description
        self.status = site.status
        self.latitude = site.latitude
        self.longitude = site.longitude
        self.locationLabel = site.locationLabel
        self.regionCode = site.regionCode
        self.labels = site.labels
        self.networkControllerAgentId = site.networkControllerAgentID
        self.organizationId = site.organizationID
        self.organizationalUnitId = site.organizationalUnitID
        self.createdAt = site.createdAt
        self.updatedAt = site.updatedAt
    }

    init(from site: SiteSnapshot, now: Date = Date()) throws {
        guard let status = SiteStatus(rawValue: site.status) else {
            throw Abort(.internalServerError, reason: "Site has invalid status '\(site.status)'")
        }
        self.id = site.id
        self.name = site.name
        self.description = site.description
        self.status = status
        self.latitude = site.latitude
        self.longitude = site.longitude
        self.locationLabel = site.locationLabel
        self.regionCode = site.regionCode
        self.labels = site.labels
        self.networkControllerAgentId = site.networkControllerAgentID
        self.organizationId = site.organizationID
        self.organizationalUnitId = site.organizationalUnitID
        self.createdAt = site.createdAt
        self.updatedAt = site.updatedAt

        guard let controller = site.controller else {
            self.networkControllerStatus = nil
            self.networkControllerIssue = nil
            return
        }
        guard var controllerStatus = AgentStatus(rawValue: controller.status) else {
            throw Abort(
                .internalServerError,
                reason: "Site network controller has invalid status '\(controller.status)'"
            )
        }
        let heartbeatAge = controller.lastHeartbeat.map { now.timeIntervalSince($0) }
        let online = heartbeatAge.map { $0 < 60 } ?? false
        if online && controllerStatus == .offline {
            controllerStatus = .online
        } else if !online && controllerStatus == .online {
            controllerStatus = .offline
        }
        self.networkControllerStatus = controllerStatus

        if !controller.supportsInterVMNetworking {
            self.networkControllerIssue =
                "Network controller '\(controller.name)' re-registered without overlay (OVN) networking capability"
        } else if let heartbeatAge, heartbeatAge > SiteNetworkAuthority.controllerOfflineGrace {
            self.networkControllerIssue =
                "Network controller '\(controller.name)' is offline (no heartbeat for \(SiteNetworkAuthority.compactAge(heartbeatAge)))"
        } else if controller.lastHeartbeat == nil {
            self.networkControllerIssue =
                "Network controller '\(controller.name)' is offline (it has never sent a heartbeat)"
        } else {
            self.networkControllerIssue = nil
        }
    }
}

struct CreateSiteRequest: Content, ValidatedRequestBody {
    var name: String
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

    mutating func validate() throws {
        name = try Validate.name(name)
        try Validate.text(description)
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
struct UpdateSiteRequest: Content, ValidatedRequestBody {
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

    mutating func validate() throws {
        try Validate.text(description)
    }
}
