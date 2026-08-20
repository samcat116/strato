import Fluent
import SQLKit
import Vapor

/// A DNS zone: an arbitrarily-named, project-owned namespace that VMs resolve
/// and register into (issue #770, roadmap #769).
///
/// The shape is Route 53's private hosted zone: the zone is a first-class
/// resource attached many-to-many to logical networks, and
/// attaching it to a network means "VMs on this network can resolve this
/// zone". That maps directly onto OVN's `Logical_Switch.dns_records` being a
/// *set* of weak references — one switch can carry several zones' rows.
///
/// Names are deliberately unconstrained beyond being valid FQDNs: `.internal`
/// is a convention, not a rule, and a tenant serving `corp.example.com`
/// internally is what makes split-horizon possible later. Uniqueness is per
/// project, so two tenants may both serve `corp.example.com` without seeing
/// each other's records.
enum DNSZone {
    static let schema = "dns_zones"

    /// Hard cap on authored records per zone. A guard against unbounded
    /// growth in what every realization driver has to push down (OVN keeps a
    /// zone's whole record set in one row), not a billable quota — promote it
    /// to a `ResourceQuota` column if zones ever get one.
    static let maxRecordsPerZone = 1000
}

struct DNSZoneSnapshot: Equatable, Sendable {
    let id: UUID
    let name: String
    let zoneDescription: String?
    let projectID: UUID
    let createdByID: UUID?
    let createdAt: Date?
    let updatedAt: Date?
}

enum LegacyDNSZoneStore {
    static func zones(
        ids: [UUID]? = nil,
        projectIDs: [UUID]? = nil,
        on db: any Database
    ) async throws -> [DNSZoneSnapshot] {
        if let ids, ids.isEmpty { return [] }
        if let projectIDs, projectIDs.isEmpty { return [] }
        var query: SQLQueryString = "SELECT \(unsafeRaw: columns) FROM dns_zones WHERE TRUE"
        if let ids { query += " AND id = ANY(\(bind: ids))" }
        if let projectIDs { query += " AND project_id = ANY(\(bind: projectIDs))" }
        query += " ORDER BY name, id"
        return try await requireSQL(db).raw(query).all(decoding: Record.self).map(\.snapshot)
    }

    static func find(id: UUID, on db: any Database) async throws -> DNSZoneSnapshot? {
        try await zones(ids: [id], on: db).first
    }

    @discardableResult
    static func insert(
        id: UUID = UUID(),
        name: String,
        description: String? = nil,
        projectID: UUID,
        createdByID: UUID? = nil,
        on db: any Database
    ) async throws -> DNSZoneSnapshot {
        guard let row = try await requireSQL(db).raw(
            """
            INSERT INTO dns_zones (
                id, name, description, project_id, created_by_id, created_at, updated_at
            ) VALUES (
                \(bind: id), \(bind: name), \(bind: description), \(bind: projectID),
                \(bind: createdByID), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            )
            RETURNING \(unsafeRaw: columns)
            """
        ).first(decoding: Record.self) else {
            throw Abort(.internalServerError, reason: "Could not create DNS zone")
        }
        return row.snapshot
    }

    @discardableResult
    static func update(
        id: UUID,
        name: String,
        description: String?,
        on db: any Database
    ) async throws -> DNSZoneSnapshot? {
        try await requireSQL(db).raw(
            """
            UPDATE dns_zones
            SET name = \(bind: name), description = \(bind: description),
                updated_at = CURRENT_TIMESTAMP
            WHERE id = \(bind: id)
            RETURNING \(unsafeRaw: columns)
            """
        ).first(decoding: Record.self)?.snapshot
    }

    static func ids(projectIDs: [UUID], on db: any Database) async throws -> [UUID] {
        struct ID: Decodable { let id: UUID }
        guard !projectIDs.isEmpty else { return [] }
        return try await requireSQL(db).raw(
            "SELECT id FROM dns_zones WHERE project_id = ANY(\(bind: projectIDs))"
        ).all(decoding: ID.self).map(\.id)
    }

    @discardableResult
    static func delete(id: UUID, on db: any Database) async throws -> UUID? {
        struct Deleted: Decodable { let id: UUID }
        return try await requireSQL(db).raw(
            "DELETE FROM dns_zones WHERE id = \(bind: id) RETURNING id"
        ).first(decoding: Deleted.self)?.id
    }

    private struct Record: Decodable, Sendable {
        let id: UUID
        let name: String
        let zoneDescription: String?
        let projectID: UUID
        let createdByID: UUID?
        let createdAt: Date?
        let updatedAt: Date?

        var snapshot: DNSZoneSnapshot {
            DNSZoneSnapshot(
                id: id, name: name, zoneDescription: zoneDescription,
                projectID: projectID, createdByID: createdByID,
                createdAt: createdAt, updatedAt: updatedAt)
        }
    }

    private static let columns = """
        id, name, description AS "zoneDescription", project_id AS "projectID",
        created_by_id AS "createdByID", created_at AS "createdAt", updated_at AS "updatedAt"
        """

    private static func requireSQL(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "DNS zones require PostgreSQL")
        }
        return sql
    }
}

// MARK: - Request/Response DTOs

struct CreateDNSZoneRequest: Content, ValidatedRequestBody {
    /// Fully-qualified zone name, e.g. `acme.internal` or `corp.example.com`.
    ///
    /// Bounded here as well as parsed by `DNSName.normalizedZoneName` (STR-198),
    /// because this name leaves the database: `DNSZoneAssembler` renders it into
    /// every FQDN in the zone, the topology authority writes those into the OVN
    /// `DNS` table referenced from `Logical_Switch.dns_records`, and the network
    /// resolver serves them. The ceiling is the *grammar's* — see `validate()`.
    var name: String
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

    /// The zone name is held to `DNSName.maxNameLength`, not `Validate.nameLength`.
    ///
    /// `Validate`'s 128 was chosen so that adopting it fleet-wide could not make
    /// something that already fits stop fitting, and a zone name is the case
    /// where it would: RFC 1035 permits 253 characters, `normalizedZoneName`
    /// accepts them today, and a deep subdomain zone is an ordinary thing to
    /// serve. This is the "field with a grammar of its own" carve-out on
    /// `Validate` — the ceiling comes from the grammar, and what the DTO adds is
    /// that it is applied at decode, before a megabyte of name is lowercased and
    /// split into labels, and that create and update cannot drift apart.
    ///
    /// Measured before `normalizedZoneName` strips the root dot, so a
    /// 253-character name written with one is one character over. That is the
    /// price of bounding ahead of the parser rather than behind it, and one
    /// character at the RFC ceiling is a cheap thing to pay it with.
    ///
    /// `description` has no grammar and had no bound at all, which is the actual
    /// hole this closes.
    mutating func validate() throws {
        name = try Validate.name(name, "name", max: DNSName.maxNameLength)
        try Validate.text(description)
    }
}

struct UpdateDNSZoneRequest: Content, ValidatedRequestBody {
    var name: String?
    let description: String?

    init(name: String? = nil, description: String? = nil) {
        self.name = name
        self.description = description
    }

    mutating func validate() throws {
        name = try Validate.name(name, "name", max: DNSName.maxNameLength)
        try Validate.text(description)
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
    /// Why this network's guests will not resolve the zones attached to it, or
    /// nil when they will (STR-201).
    ///
    /// Carried here rather than only on the network so that the **attach
    /// response itself** answers: attaching is the moment the operator states
    /// the intent, and it is the only moment at which "this will not reach your
    /// guests" is worth reading. It is a property of the network, not of this
    /// zone, so every entry for one network repeats the same string.
    let zoneResolutionWarning: String?
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
        from zone: DNSZoneSnapshot,
        networks: [DNSZoneNetworkResponse],
        recordCount: Int
    ) {
        self.id = zone.id
        self.name = zone.name
        self.description = zone.zoneDescription
        self.projectId = zone.projectID
        self.networks = networks
        self.recordCount = recordCount
        self.createdAt = zone.createdAt
        self.updatedAt = zone.updatedAt
    }
}
