import ControlPlanePostgres
import Foundation
import Vapor

/// The record types the model can carry.
///
/// Deliberately wider than any realization driver: the OVN `DNS` table
/// answers A/AAAA/PTR only, and a link-local CoreDNS (roadmap phase 4) is what
/// makes the rest resolvable. Drivers reject what they cannot do with a clear
/// error rather than the model pretending those records don't exist — an
/// operator authoring a `TXT` before phase 4 lands should get "no backend on
/// this network realizes TXT yet", not a validation error that implies Strato
/// will never support it.
enum DNSRecordType: String, Codable, Sendable, CaseIterable {
    case a = "A"
    case aaaa = "AAAA"
    case cname = "CNAME"
    case txt = "TXT"
    case srv = "SRV"
    case ptr = "PTR"
}

/// Which side of a split horizon a record belongs to.
///
/// Carried from phase 1 so split-horizon is not a retrofit onto a column that
/// doesn't exist. Nothing consumes it until external publication (roadmap
/// phase 6); until then every record is served internally regardless.
enum DNSRecordView: String, Codable, Sendable, CaseIterable {
    /// Served only to VMs inside the overlay.
    case `internal`
    /// Published only to the operator's external DNS.
    case external
    /// Both — the default, and what every record is until phase 6.
    case both
}

enum DNSRecord {
    static let schema = "dns_records"
    static let defaultTTL = 300
    static let ttlRange = 1...31_536_000
}

struct DNSRecordSnapshot: Equatable, Sendable {
    let id: UUID
    let zoneID: UUID
    let name: String
    let type: DNSRecordType
    let value: String
    let ttl: Int
    let view: DNSRecordView
    let createdByID: UUID?
    let createdAt: Date?
    let updatedAt: Date?
}

enum LegacyDNSRecordStore {
    static func records(zoneIDs: [UUID], on db: PostgresStoreContext) async throws -> [DNSRecordSnapshot] {
        guard !zoneIDs.isEmpty else { return [] }
        return try await snapshots(from: requireSQL(db).raw(
            "SELECT \(unsafeRaw: columns) FROM dns_records WHERE zone_id = ANY(\(bind: zoneIDs)) ORDER BY name, id"
        ).all(decoding: Record.self))
    }

    static func records(zoneID: UUID, on db: PostgresStoreContext) async throws -> [DNSRecordSnapshot] {
        try await records(zoneIDs: [zoneID], on: db)
    }

    static func records(zoneID: UUID, name: String, on db: PostgresStoreContext) async throws
        -> [DNSRecordSnapshot]
    {
        try await snapshots(from: requireSQL(db).raw(
            "SELECT \(unsafeRaw: columns) FROM dns_records WHERE zone_id = \(bind: zoneID) AND name = \(bind: name) ORDER BY id"
        ).all(decoding: Record.self))
    }

    static func records(ids: [UUID], on db: PostgresStoreContext) async throws -> [DNSRecordSnapshot] {
        guard !ids.isEmpty else { return [] }
        return try await snapshots(from: requireSQL(db).raw(
            "SELECT \(unsafeRaw: columns) FROM dns_records WHERE id = ANY(\(bind: ids)) ORDER BY id"
        ).all(decoding: Record.self))
    }

    static func record(id: UUID, zoneID: UUID? = nil, on db: PostgresStoreContext) async throws
        -> DNSRecordSnapshot?
    {
        var query: PostgresSQLQuery =
            "SELECT \(unsafeRaw: columns) FROM dns_records WHERE id = \(bind: id)"
        if let zoneID { query += " AND zone_id = \(bind: zoneID)" }
        query += " LIMIT 1"
        guard let row = try await requireSQL(db).raw(query).first(decoding: Record.self) else {
            return nil
        }
        return try row.snapshot()
    }

    static func first(zoneID: UUID, names: [String], on db: PostgresStoreContext) async throws
        -> DNSRecordSnapshot?
    {
        guard !names.isEmpty else { return nil }
        guard let row = try await requireSQL(db).raw(
            "SELECT \(unsafeRaw: columns) FROM dns_records WHERE zone_id = \(bind: zoneID) AND name = ANY(\(bind: names)) ORDER BY id LIMIT 1"
        ).first(decoding: Record.self) else { return nil }
        return try row.snapshot()
    }

    @discardableResult
    static func insert(
        id: UUID = UUID(), zoneID: UUID, name: String, type: DNSRecordType,
        value: String, ttl: Int = DNSRecord.defaultTTL, view: DNSRecordView = .both,
        createdByID: UUID? = nil, on db: PostgresStoreContext
    ) async throws -> DNSRecordSnapshot {
        guard let row = try await requireSQL(db).raw(
            """
            INSERT INTO dns_records (
                id, zone_id, name, type, value, ttl, view, created_by_id, created_at, updated_at
            ) VALUES (
                \(bind: id), \(bind: zoneID), \(bind: name), \(bind: type.rawValue),
                \(bind: value), \(bind: ttl), \(bind: view.rawValue), \(bind: createdByID),
                CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            )
            RETURNING \(unsafeRaw: columns)
            """
        ).first(decoding: Record.self) else {
            throw Abort(.internalServerError, reason: "Could not create DNS record")
        }
        return try row.snapshot()
    }

    @discardableResult
    static func update(
        id: UUID, value: String, ttl: Int, view: DNSRecordView, on db: PostgresStoreContext
    ) async throws -> DNSRecordSnapshot? {
        guard let row = try await requireSQL(db).raw(
            """
            UPDATE dns_records
            SET value = \(bind: value), ttl = \(bind: ttl), view = \(bind: view.rawValue),
                updated_at = CURRENT_TIMESTAMP
            WHERE id = \(bind: id)
            RETURNING \(unsafeRaw: columns)
            """
        ).first(decoding: Record.self) else { return nil }
        return try row.snapshot()
    }

    static func applyRRsetSettings(
        zoneID: UUID, name: String, type: DNSRecordType, ttl: Int,
        view: DNSRecordView, on db: PostgresStoreContext
    ) async throws {
        try await requireSQL(db).raw(
            """
            UPDATE dns_records
            SET ttl = \(bind: ttl), view = \(bind: view.rawValue), updated_at = CURRENT_TIMESTAMP
            WHERE zone_id = \(bind: zoneID) AND name = \(bind: name) AND type = \(bind: type.rawValue)
            """
        ).run()
    }

    static func count(zoneID: UUID, on db: PostgresStoreContext) async throws -> Int {
        struct Count: Decodable { let count: Int }
        return try await requireSQL(db).raw(
            "SELECT count(*)::bigint AS count FROM dns_records WHERE zone_id = \(bind: zoneID)"
        ).first(decoding: Count.self)?.count ?? 0
    }

    static func counts(zoneIDs: [UUID], on db: PostgresStoreContext) async throws -> [UUID: Int] {
        struct Count: Decodable { let zoneID: UUID; let count: Int }
        guard !zoneIDs.isEmpty else { return [:] }
        return Dictionary(uniqueKeysWithValues: try await requireSQL(db).raw(
            """
            SELECT zone_id AS "zoneID", count(*)::bigint AS count
            FROM dns_records WHERE zone_id = ANY(\(bind: zoneIDs)) GROUP BY zone_id
            """
        ).all(decoding: Count.self).map { ($0.zoneID, $0.count) })
    }

    static func ids(zoneIDs: [UUID], on db: PostgresStoreContext) async throws -> [UUID] {
        struct ID: Decodable { let id: UUID }
        guard !zoneIDs.isEmpty else { return [] }
        return try await requireSQL(db).raw(
            "SELECT id FROM dns_records WHERE zone_id = ANY(\(bind: zoneIDs))"
        ).all(decoding: ID.self).map(\.id)
    }

    @discardableResult
    static func delete(id: UUID, on db: PostgresStoreContext) async throws -> UUID? {
        struct ID: Decodable { let id: UUID }
        return try await requireSQL(db).raw(
            "DELETE FROM dns_records WHERE id = \(bind: id) RETURNING id"
        ).first(decoding: ID.self)?.id
    }

    private struct Record: Decodable, Sendable {
        let id: UUID
        let zoneID: UUID
        let name: String
        let type: String
        let value: String
        let ttl: Int
        let view: String
        let createdByID: UUID?
        let createdAt: Date?
        let updatedAt: Date?

        func snapshot() throws -> DNSRecordSnapshot {
            guard let type = DNSRecordType(rawValue: type), let view = DNSRecordView(rawValue: view) else {
                throw Abort(.internalServerError, reason: "DNS record has invalid persisted values")
            }
            return DNSRecordSnapshot(
                id: id, zoneID: zoneID, name: name, type: type, value: value,
                ttl: ttl, view: view, createdByID: createdByID,
                createdAt: createdAt, updatedAt: updatedAt)
        }
    }

    private static let columns = """
        id, zone_id AS "zoneID", name, type, value, ttl, view,
        created_by_id AS "createdByID", created_at AS "createdAt", updated_at AS "updatedAt"
        """

    private static func snapshots(from rows: [Record]) throws -> [DNSRecordSnapshot] {
        try rows.map { try $0.snapshot() }
    }

    private static func requireSQL(_ db: PostgresStoreContext) throws -> PostgresStoreContext {
        guard let sql = db as? PostgresStoreContext else {
            throw Abort(.internalServerError, reason: "DNS records require PostgreSQL")
        }
        return sql
    }
}

// MARK: - Request/Response DTOs

struct CreateDNSRecordRequest: Content, ValidatedRequestBody {
    /// Owner name relative to the zone; `@` (or omitted) means the apex.
    let name: String?
    let type: DNSRecordType
    let value: String
    /// Defaults to `DNSRecord.defaultTTL`.
    let ttl: Int?
    /// Defaults to `both`.
    let view: DNSRecordView?

    init(
        name: String? = nil, type: DNSRecordType, value: String, ttl: Int? = nil,
        view: DNSRecordView? = nil
    ) {
        self.name = name
        self.type = type
        self.value = value
        self.ttl = ttl
        self.view = view
    }

    /// Bounded, not normalized (STR-198). Both fields have a parser downstream
    /// and it owns their shape; this is the floor underneath it, applied before
    /// the parser does O(n) work on a value it will refuse anyway.
    ///
    /// `name` takes `Validate.text` rather than `Validate.name` because empty is
    /// meaningful here — `DNSName.normalizedRecordName` reads `""` as the apex,
    /// the same as `@` — so the non-empty rule that comes with a "required name"
    /// would turn a documented spelling into a `400`. Its ceiling is the
    /// grammar's, for the reason given on `CreateDNSZoneRequest.validate()`.
    ///
    /// `value` takes `Validate.textLength`, which is deliberately looser than
    /// anything `DNSZoneService.validatedValue` accepts (255 bytes for TXT, a
    /// domain name for CNAME/PTR/SRV, a parsed address for A/AAAA). A second
    /// content-shaped number would be the drift this whole helper exists to
    /// avoid; what this pins is the same ceiling the `dns_records.value` column
    /// carries, so the API and the backstop agree.
    mutating func validate() throws {
        try Validate.text(name, "name", max: DNSName.maxNameLength)
        try Validate.text(value, "value")
    }
}

struct UpdateDNSRecordRequest: Content, ValidatedRequestBody {
    let value: String?
    let ttl: Int?
    let view: DNSRecordView?

    init(value: String? = nil, ttl: Int? = nil, view: DNSRecordView? = nil) {
        self.value = value
        self.ttl = ttl
        self.view = view
    }

    /// The same ceiling on the same field as the create path — a record's name
    /// and type are its identity and are immutable, so `value` is the only text
    /// an update carries.
    mutating func validate() throws {
        try Validate.text(value, "value")
    }
}

struct DNSRecordResponse: Content {
    let id: UUID
    let zoneId: UUID
    /// The owner name as authored, relative to the zone (`@` for the apex).
    let name: String
    /// The same name fully qualified — what a resolver actually answers on.
    let fqdn: String
    let type: DNSRecordType
    let value: String
    let ttl: Int
    let view: DNSRecordView
    let createdAt: Date?
    let updatedAt: Date?

    init(from record: DNSRecordSnapshot, zoneName: String) {
        self.id = record.id
        self.zoneId = record.zoneID
        self.name = record.name
        self.fqdn = DNSName.qualified(name: record.name, inZone: zoneName)
        self.type = record.type
        self.value = record.value
        self.ttl = record.ttl
        self.view = record.view
        self.createdAt = record.createdAt
        self.updatedAt = record.updatedAt
    }
}
