import ControlPlanePostgres
import Foundation

/// A zone↔network attachment: "VMs on this network can resolve this zone."
///
/// Many-to-many on purpose. One network may resolve several zones (a shared
/// services zone plus the team's own), and one zone may serve several networks
/// — which is what `Logical_Switch.dns_records` being a set of weak refs
/// already permits. Where a network's VMs *register* is a separate, singular
/// decision: `LogicalNetwork.primaryDNSZone`, which must name one of these
/// attachments.
/// Immutable decoding state for an attachment. The join has no behavior of its
/// own; its intent-oriented store keeps attachment batches and counts inside
/// callers' existing transactions while the surrounding DNS cohort migrates.
struct DNSZoneNetworkRecord: Decodable, Equatable, Sendable {
    let id: UUID
    let zoneID: UUID
    let logicalNetworkID: UUID
    let createdAt: Date?
}

enum DNSZoneNetworkStoreError: Error, Equatable, Sendable {
    case requiresSQLDatabase
}

enum DNSZoneNetworkStore {
    private static let columns = """
        id, zone_id AS "zoneID", logical_network_id AS "logicalNetworkID",
        created_at AS "createdAt"
        """

    static func attachments(
        zoneIDs: [UUID]? = nil,
        networkIDs: [UUID]? = nil,
        on db: PostgresStoreContext
    ) async throws -> [DNSZoneNetworkRecord] {
        let sql = try requireSQL(db)
        var query: PostgresSQLQuery =
            "SELECT \(unsafeRaw: columns) FROM dns_zone_networks WHERE TRUE"
        if let zoneIDs {
            guard !zoneIDs.isEmpty else { return [] }
            query += " AND zone_id = ANY(\(bind: zoneIDs))"
        }
        if let networkIDs {
            guard !networkIDs.isEmpty else { return [] }
            query += " AND logical_network_id = ANY(\(bind: networkIDs))"
        }
        query += " ORDER BY created_at, id"
        return try await sql.raw(query).all(decoding: DNSZoneNetworkRecord.self)
    }

    static func count(
        zoneID: UUID? = nil,
        networkID: UUID? = nil,
        on db: PostgresStoreContext
    ) async throws -> Int {
        struct CountRow: Decodable { let count: Int }
        let sql = try requireSQL(db)
        var query: PostgresSQLQuery = "SELECT count(*)::bigint AS count FROM dns_zone_networks WHERE TRUE"
        if let zoneID { query += " AND zone_id = \(bind: zoneID)" }
        if let networkID { query += " AND logical_network_id = \(bind: networkID)" }
        return try await sql.raw(query).first(decoding: CountRow.self)?.count ?? 0
    }

    /// Idempotently attach one zone to one network. The database timestamp and
    /// application UUID retain the former Fluent model's representation.
    @discardableResult
    static func attach(zoneID: UUID, networkID: UUID, on db: PostgresStoreContext) async throws -> Bool {
        struct IdentifierRow: Decodable { let id: UUID }
        let sql = try requireSQL(db)
        let inserted = try await sql.raw(
            """
            INSERT INTO dns_zone_networks (id, zone_id, logical_network_id, created_at)
            VALUES (\(bind: UUID()), \(bind: zoneID), \(bind: networkID), CURRENT_TIMESTAMP)
            ON CONFLICT (zone_id, logical_network_id) DO NOTHING
            RETURNING id
            """
        ).first(decoding: IdentifierRow.self)
        return inserted != nil
    }

    @discardableResult
    static func detach(zoneID: UUID, networkID: UUID, on db: PostgresStoreContext) async throws -> Bool {
        struct IdentifierRow: Decodable { let id: UUID }
        let sql = try requireSQL(db)
        return try await sql.raw(
            """
            DELETE FROM dns_zone_networks
            WHERE zone_id = \(bind: zoneID) AND logical_network_id = \(bind: networkID)
            RETURNING id
            """
        ).first(decoding: IdentifierRow.self) != nil
    }

    static func counts(networkIDs: [UUID], on db: PostgresStoreContext) async throws -> [UUID: Int] {
        struct CountRow: Decodable {
            let logicalNetworkID: UUID
            let count: Int
        }
        guard !networkIDs.isEmpty else { return [:] }
        let sql = try requireSQL(db)
        let rows = try await sql.raw(
            """
            SELECT logical_network_id AS "logicalNetworkID", count(*)::bigint AS count
            FROM dns_zone_networks
            WHERE logical_network_id = ANY(\(bind: networkIDs))
            GROUP BY logical_network_id
            """
        ).all(decoding: CountRow.self)
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.logicalNetworkID, $0.count) })
    }

    private static func requireSQL(_ db: PostgresStoreContext) throws -> PostgresStoreContext {
        guard let sql = db as? PostgresStoreContext else {
            throw DNSZoneNetworkStoreError.requiresSQLDatabase
        }
        return sql
    }
}
