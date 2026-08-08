import Fluent
import Vapor

/// A DNS zone: an arbitrarily-named, project-owned namespace that VMs resolve
/// and register into (issue #770, roadmap #769).
///
/// The shape is Route 53's private hosted zone: the zone is a first-class
/// resource attached many-to-many to logical networks (`DNSZoneNetwork`), and
/// attaching it to a network means "VMs on this network can resolve this
/// zone". That maps directly onto OVN's `Logical_Switch.dns_records` being a
/// *set* of weak references — one switch can carry several zones' rows.
///
/// Names are deliberately unconstrained beyond being valid FQDNs: `.internal`
/// is a convention, not a rule, and a tenant serving `corp.example.com`
/// internally is what makes split-horizon possible later. Uniqueness is per
/// project, so two tenants may both serve `corp.example.com` without seeing
/// each other's records.
final class DNSZone: Model, @unchecked Sendable {
    static let schema = "dns_zones"

    /// Hard cap on authored records per zone. A guard against unbounded
    /// growth in what every realization driver has to push down (OVN keeps a
    /// zone's whole record set in one row), not a billable quota — promote it
    /// to a `ResourceQuota` column if zones ever get one.
    static let maxRecordsPerZone = 1000

    @ID(key: .id)
    var id: UUID?

    /// The zone's fully-qualified name, lowercased with no trailing dot.
    /// Unique within the owning project (schema-enforced).
    @Field(key: "name")
    var name: String

    @OptionalField(key: "description")
    var zoneDescription: String?

    /// Project that owns the zone. Zones are tenant resources: their name,
    /// their records, and the networks they may attach to are all scoped by it.
    @Parent(key: "project_id")
    var project: Project

    @OptionalParent(key: "created_by_id")
    var createdBy: User?

    @Children(for: \.$zone)
    var records: [DNSRecord]

    @Children(for: \.$zone)
    var networkAttachments: [DNSZoneNetwork]

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        name: String,
        description: String? = nil,
        projectID: UUID,
        createdByID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.zoneDescription = description
        self.$project.id = projectID
        self.$createdBy.id = createdByID
    }
}

extension DNSZone: Content {}

// MARK: - Request/Response DTOs

struct CreateDNSZoneRequest: Content {
    /// Fully-qualified zone name, e.g. `acme.internal` or `corp.example.com`.
    let name: String
    let description: String?
    /// Required: there is no default project (issue #1059). Optional here so
    /// the refusal is `Request.projectIsRequired`'s, which names the remedy,
    /// rather than a `Codable` decode failure that names neither.
    let projectId: UUID?

    init(name: String, description: String? = nil, projectId: UUID? = nil) {
        self.name = name
        self.description = description
        self.projectId = projectId
    }
}

struct UpdateDNSZoneRequest: Content {
    let name: String?
    let description: String?

    init(name: String? = nil, description: String? = nil) {
        self.name = name
        self.description = description
    }
}

struct AttachDNSZoneRequest: Content {
    let networkId: UUID
    /// Also make this zone the network's primary — the zone its VMs
    /// auto-register into. Defaults to false: attaching grants resolution,
    /// registration is a separate, deliberate choice.
    let primary: Bool?

    init(networkId: UUID, primary: Bool? = nil) {
        self.networkId = networkId
        self.primary = primary
    }
}

/// One network a zone is attached to, as the zone's API reports it.
struct DNSZoneNetworkResponse: Content {
    let networkId: UUID
    let networkName: String
    /// Whether this zone is the network's primary — i.e. whether the
    /// network's VMs register their derived records here.
    let isPrimary: Bool
}

struct DNSZoneResponse: Content {
    let id: UUID
    let name: String
    let description: String?
    let projectId: UUID
    let networks: [DNSZoneNetworkResponse]
    /// Authored records in the zone. Derived records are not stored and are
    /// not counted here — fetch the assembled set for the effective view.
    let recordCount: Int
    let createdAt: Date?
    let updatedAt: Date?

    init(
        from zone: DNSZone,
        networks: [DNSZoneNetworkResponse],
        recordCount: Int
    ) throws {
        self.id = try zone.requireID()
        self.name = zone.name
        self.description = zone.zoneDescription
        self.projectId = zone.$project.id
        self.networks = networks
        self.recordCount = recordCount
        self.createdAt = zone.createdAt
        self.updatedAt = zone.updatedAt
    }
}
