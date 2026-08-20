import Fluent
import Foundation
import SQLKit
import Vapor

/// Fixed-shape SQL used only where a still-Fluent aggregate must inspect or
/// update a site on the aggregate's pinned transaction.
///
/// Site-owned API operations use `SitesPersistence` and PostgresNIO directly.
package enum LegacySiteStore {
    package enum NetworkControllerCondition: Sendable {
        case any
        case unset
        case equals(UUID)
    }

    package static func site(id: UUID?, on db: any Database) async throws -> Site? {
        guard let id else { return nil }
        let matches = try await sites(ids: [id], on: db)
        guard matches.count <= 1 else {
            throw Abort(.internalServerError, reason: "Site lookup returned duplicate rows")
        }
        return matches.first
    }

    package static func sites(
        ids: [UUID]? = nil,
        name: String? = nil,
        networkControllerAgentID: UUID? = nil,
        organizationID: UUID? = nil,
        organizationalUnitID: UUID? = nil,
        excludingID: UUID? = nil,
        on db: any Database
    ) async throws -> [Site] {
        if let ids, ids.isEmpty { return [] }
        var query: SQLQueryString =
            "SELECT \(unsafeRaw: columns) FROM sites AS s WHERE TRUE"
        if let ids { query += " AND s.id = ANY(\(bind: ids))" }
        if let name { query += " AND s.name = \(bind: name)" }
        if let networkControllerAgentID {
            query += " AND s.network_controller_agent_id = \(bind: networkControllerAgentID)"
        }
        if let organizationID { query += " AND s.organization_id = \(bind: organizationID)" }
        if let organizationalUnitID {
            query += " AND s.organizational_unit_id = \(bind: organizationalUnitID)"
        }
        if let excludingID { query += " AND s.id <> \(bind: excludingID)" }
        query += " ORDER BY s.name, s.id"
        return try await requireSQL(db).raw(query).all(decoding: Record.self).map { try $0.site }
    }

    package static func count(
        networkControllerAgentID: UUID,
        excludingID: UUID? = nil,
        on db: any Database
    ) async throws -> Int {
        struct Count: Decodable { let count: Int }
        var query: SQLQueryString = """
            SELECT count(*)::bigint AS count
            FROM sites
            WHERE network_controller_agent_id = \(bind: networkControllerAgentID)
            """
        if let excludingID { query += " AND id <> \(bind: excludingID)" }
        return try await requireSQL(db).raw(query).first(decoding: Count.self)?.count ?? 0
    }

    @discardableResult
    static func insert(_ site: Site, on db: any Database) async throws -> Site {
        let id = try site.requireID()
        let labels = String(
            data: try JSONEncoder().encode(site.labels),
            encoding: .utf8
        ) ?? "{}"
        guard let row = try await requireSQL(db).raw(
            """
            INSERT INTO sites (
                id, name, description, network_controller_agent_id,
                organization_id, organizational_unit_id, status,
                latitude, longitude, location_label, region_code, labels,
                created_at, updated_at
            ) VALUES (
                \(bind: id), \(bind: site.name), \(bind: site.description),
                \(bind: site.networkControllerAgentID), \(bind: site.organizationID),
                \(bind: site.organizationalUnitID), \(bind: site.status.rawValue),
                \(bind: site.latitude), \(bind: site.longitude),
                \(bind: site.locationLabel), \(bind: site.regionCode),
                \(bind: labels)::jsonb, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            )
            RETURNING \(unsafeRaw: returningColumns)
            """
        ).first(decoding: Record.self) else {
            throw Abort(.internalServerError, reason: "Could not create site")
        }
        return try row.site
    }

    @discardableResult
    package static func setNetworkController(
        siteID: UUID,
        agentID: UUID?,
        condition: NetworkControllerCondition = .any,
        on db: any Database
    ) async throws -> Site? {
        var query: SQLQueryString = """
            UPDATE sites
            SET network_controller_agent_id = \(bind: agentID),
                updated_at = CURRENT_TIMESTAMP
            WHERE id = \(bind: siteID)
            """
        switch condition {
        case .any:
            break
        case .unset:
            query += " AND network_controller_agent_id IS NULL"
        case .equals(let expected):
            query += " AND network_controller_agent_id = \(bind: expected)"
        }
        query += " RETURNING \(unsafeRaw: returningColumns)"
        return try await requireSQL(db).raw(query).first(decoding: Record.self).map { try $0.site }
    }

    @discardableResult
    static func delete(id: UUID, on db: any Database) async throws -> UUID? {
        struct Deleted: Decodable { let id: UUID }
        return try await requireSQL(db).raw(
            "DELETE FROM sites WHERE id = \(bind: id) RETURNING id"
        ).first(decoding: Deleted.self)?.id
    }

    private struct Record: Decodable, Sendable {
        let id: UUID
        let name: String
        let description: String?
        let status: String
        let latitude: Double?
        let longitude: Double?
        let locationLabel: String?
        let regionCode: String?
        let labelsJSON: String
        let networkControllerAgentID: UUID?
        let organizationID: UUID?
        let organizationalUnitID: UUID?
        let createdAt: Date?
        let updatedAt: Date?

        var site: Site {
            get throws {
                guard let status = SiteStatus(rawValue: status),
                    let data = labelsJSON.data(using: .utf8),
                    let labels = try? JSONDecoder().decode([String: String].self, from: data)
                else {
                    throw Abort(.internalServerError, reason: "Site row has invalid stored values")
                }
                let scope: OrganizationScope?
                if let organizationID {
                    scope = .organization(organizationID)
                } else if let organizationalUnitID {
                    scope = .organizationalUnit(organizationalUnitID)
                } else {
                    scope = nil
                }
                return Site(
                    id: id,
                    name: name,
                    description: description,
                    status: status,
                    latitude: latitude,
                    longitude: longitude,
                    locationLabel: locationLabel,
                    regionCode: regionCode,
                    labels: labels,
                    networkControllerAgentID: networkControllerAgentID,
                    organizationScope: scope,
                    createdAt: createdAt,
                    updatedAt: updatedAt)
            }
        }
    }

    private static let columns = """
        s.id,
        s.name,
        s.description,
        s.status,
        s.latitude,
        s.longitude,
        s.location_label AS "locationLabel",
        s.region_code AS "regionCode",
        s.labels::text AS "labelsJSON",
        s.network_controller_agent_id AS "networkControllerAgentID",
        s.organization_id AS "organizationID",
        s.organizational_unit_id AS "organizationalUnitID",
        s.created_at AS "createdAt",
        s.updated_at AS "updatedAt"
        """

    private static let returningColumns = """
        id,
        name,
        description,
        status,
        latitude,
        longitude,
        location_label AS "locationLabel",
        region_code AS "regionCode",
        labels::text AS "labelsJSON",
        network_controller_agent_id AS "networkControllerAgentID",
        organization_id AS "organizationID",
        organizational_unit_id AS "organizationalUnitID",
        created_at AS "createdAt",
        updated_at AS "updatedAt"
        """

    private static func requireSQL(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Site compatibility access requires PostgreSQL")
        }
        return sql
    }
}
