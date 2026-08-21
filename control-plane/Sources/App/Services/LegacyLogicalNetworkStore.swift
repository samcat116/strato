import ControlPlanePostgres
import Foundation
import Vapor

/// Explicit logical-network access for code that still owns a Fluent
/// transaction. Only immutable values cross this compatibility boundary.
enum LegacyLogicalNetworkStore {
    static func network(id: UUID?, on db: PostgresStoreContext) async throws -> LogicalNetwork? {
        guard let id else { return nil }
        return try await networks(ids: [id], on: db).first
    }

    static func networks(
        ids: [UUID]? = nil,
        projectID: UUID? = nil,
        projectIDs: [UUID]? = nil,
        siteID: UUID? = nil,
        name: String? = nil,
        primaryDNSZoneID: UUID? = nil,
        primaryDNSZoneIDs: [UUID]? = nil,
        excludingID: UUID? = nil,
        resolverIndexPresent: Bool? = nil,
        on db: PostgresStoreContext
    ) async throws -> [LogicalNetwork] {
        if ids?.isEmpty == true || projectIDs?.isEmpty == true || primaryDNSZoneIDs?.isEmpty == true {
            return []
        }
        var query: PostgresSQLQuery =
            "SELECT \(unsafeRaw: columns) FROM logical_networks AS n WHERE TRUE"
        if let ids { query += " AND n.id = ANY(\(bind: ids))" }
        if let projectID { query += " AND n.project_id = \(bind: projectID)" }
        if let projectIDs { query += " AND n.project_id = ANY(\(bind: projectIDs))" }
        if let siteID { query += " AND n.site_id = \(bind: siteID)" }
        if let name { query += " AND n.name = \(bind: name)" }
        if let primaryDNSZoneID {
            query += " AND n.primary_dns_zone_id = \(bind: primaryDNSZoneID)"
        }
        if let primaryDNSZoneIDs {
            query += " AND n.primary_dns_zone_id = ANY(\(bind: primaryDNSZoneIDs))"
        }
        if let excludingID { query += " AND n.id <> \(bind: excludingID)" }
        if let resolverIndexPresent {
            query += resolverIndexPresent
                ? " AND n.resolver_index IS NOT NULL"
                : " AND n.resolver_index IS NULL"
        }
        query += " ORDER BY n.created_at, n.id"
        return try await requireSQL(db).raw(query).all(decoding: Record.self).map(\.network)
    }

    static func ids(projectIDs: [UUID], on db: PostgresStoreContext) async throws -> [UUID] {
        guard !projectIDs.isEmpty else { return [] }
        struct IDRecord: Decodable { let id: UUID }
        return try await requireSQL(db).raw(
            "SELECT id FROM logical_networks WHERE project_id = ANY(\(bind: projectIDs)) ORDER BY id"
        ).all(decoding: IDRecord.self).map(\.id)
    }

    static func count(on db: PostgresStoreContext) async throws -> Int {
        struct Count: Decodable { let count: Int }
        return try await requireSQL(db).raw(
            "SELECT count(*)::bigint AS count FROM logical_networks"
        ).first(decoding: Count.self)?.count ?? 0
    }

    @discardableResult
    static func upsert(_ network: LogicalNetwork, on db: PostgresStoreContext) async throws -> LogicalNetwork {
        let id = try network.requireID()
        guard let row = try await requireSQL(db).raw(
            """
            INSERT INTO logical_networks (
                id, name, subnet, gateway, subnet6, gateway6, dhcp_enabled,
                dns_servers, domain_name, lease_time, external_access,
                metadata_enabled, resolver_enabled, resolver_index, generation,
                project_id, site_id, primary_dns_zone_id, created_by_id,
                created_at, updated_at
            ) VALUES (
                \(bind: id), \(bind: network.name), \(bind: network.subnet),
                \(bind: network.gateway), \(bind: network.subnet6), \(bind: network.gateway6),
                \(bind: network.dhcpEnabled), \(bind: network.dnsServersRaw),
                \(bind: network.domainName), \(bind: network.leaseTime),
                \(bind: network.externalAccess), \(bind: network.metadataEnabled),
                \(bind: network.resolverEnabled), \(bind: network.resolverIndex),
                \(bind: network.generation), \(bind: network.projectID),
                \(bind: network.siteID), \(bind: network.primaryDNSZoneID),
                \(bind: network.createdByID), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            )
            ON CONFLICT (id) DO UPDATE SET
                name = EXCLUDED.name,
                subnet = EXCLUDED.subnet,
                gateway = EXCLUDED.gateway,
                subnet6 = EXCLUDED.subnet6,
                gateway6 = EXCLUDED.gateway6,
                dhcp_enabled = EXCLUDED.dhcp_enabled,
                dns_servers = EXCLUDED.dns_servers,
                domain_name = EXCLUDED.domain_name,
                lease_time = EXCLUDED.lease_time,
                external_access = EXCLUDED.external_access,
                metadata_enabled = EXCLUDED.metadata_enabled,
                resolver_enabled = EXCLUDED.resolver_enabled,
                resolver_index = EXCLUDED.resolver_index,
                generation = EXCLUDED.generation,
                project_id = EXCLUDED.project_id,
                site_id = EXCLUDED.site_id,
                primary_dns_zone_id = EXCLUDED.primary_dns_zone_id,
                created_by_id = EXCLUDED.created_by_id,
                updated_at = CURRENT_TIMESTAMP
            RETURNING \(unsafeRaw: returningColumns)
            """
        ).first(decoding: Record.self) else {
            throw Abort(.internalServerError, reason: "Could not persist logical network")
        }
        return row.network
    }

    @discardableResult
    static func delete(id: UUID, on db: PostgresStoreContext) async throws -> UUID? {
        struct Deleted: Decodable { let id: UUID }
        return try await requireSQL(db).raw(
            "DELETE FROM logical_networks WHERE id = \(bind: id) RETURNING id"
        ).first(decoding: Deleted.self)?.id
    }

    private struct Record: Decodable, Sendable {
        let id: UUID
        let name: String
        let subnet: String
        let gateway: String?
        let subnet6: String?
        let gateway6: String?
        let dhcpEnabled: Bool
        let dnsServersRaw: String?
        let domainName: String?
        let leaseTime: Int?
        let externalAccess: Bool
        let metadataEnabled: Bool
        let resolverEnabled: Bool
        let resolverIndex: Int?
        let generation: Int
        let projectID: UUID
        let siteID: UUID
        let primaryDNSZoneID: UUID?
        let createdByID: UUID?
        let createdAt: Date?
        let updatedAt: Date?

        var network: LogicalNetwork {
            LogicalNetwork(
                id: id,
                name: name,
                subnet: subnet,
                gateway: gateway,
                subnet6: subnet6,
                gateway6: gateway6,
                projectID: projectID,
                createdByID: createdByID,
                dhcpEnabled: dhcpEnabled,
                dnsServers: LogicalNetwork.splitDNS(dnsServersRaw),
                domainName: domainName,
                leaseTime: leaseTime,
                externalAccess: externalAccess,
                metadataEnabled: metadataEnabled,
                resolverEnabled: resolverEnabled,
                resolverIndex: resolverIndex,
                generation: generation,
                siteID: siteID,
                primaryDNSZoneID: primaryDNSZoneID,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
    }

    private static let columns = """
        n.id,
        n.name,
        n.subnet,
        n.gateway,
        n.subnet6,
        n.gateway6,
        n.dhcp_enabled AS "dhcpEnabled",
        n.dns_servers AS "dnsServersRaw",
        n.domain_name AS "domainName",
        n.lease_time AS "leaseTime",
        n.external_access AS "externalAccess",
        n.metadata_enabled AS "metadataEnabled",
        n.resolver_enabled AS "resolverEnabled",
        n.resolver_index AS "resolverIndex",
        n.generation,
        n.project_id AS "projectID",
        n.site_id AS "siteID",
        n.primary_dns_zone_id AS "primaryDNSZoneID",
        n.created_by_id AS "createdByID",
        n.created_at AS "createdAt",
        n.updated_at AS "updatedAt"
        """

    private static let returningColumns = """
        id,
        name,
        subnet,
        gateway,
        subnet6,
        gateway6,
        dhcp_enabled AS "dhcpEnabled",
        dns_servers AS "dnsServersRaw",
        domain_name AS "domainName",
        lease_time AS "leaseTime",
        external_access AS "externalAccess",
        metadata_enabled AS "metadataEnabled",
        resolver_enabled AS "resolverEnabled",
        resolver_index AS "resolverIndex",
        generation,
        project_id AS "projectID",
        site_id AS "siteID",
        primary_dns_zone_id AS "primaryDNSZoneID",
        created_by_id AS "createdByID",
        created_at AS "createdAt",
        updated_at AS "updatedAt"
        """

    private static func requireSQL(_ db: PostgresStoreContext) throws -> PostgresStoreContext {
        guard let sql = db as? PostgresStoreContext, sql.dialect.name == "postgresql" else {
            throw Abort(
                .internalServerError,
                reason: "Logical-network compatibility access requires PostgreSQL"
            )
        }
        return sql
    }
}
