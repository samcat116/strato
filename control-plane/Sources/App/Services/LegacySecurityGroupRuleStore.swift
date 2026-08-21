import ControlPlanePostgres
import Foundation
import Vapor

/// Value vocabulary for security-group rules. The namespace deliberately has
/// no persistence behavior; rows cross the persistence seam as snapshots.
enum SecurityGroupRule {
    enum Direction: String, Codable, Sendable {
        case ingress
        case egress
    }

    enum Ethertype: String, Codable, Sendable {
        case ipv4
        case ipv6
    }

    static let allowedProtocols: Set<String> = ["tcp", "udp", "icmp"]
}

struct SecurityGroupRuleSnapshot: Equatable, Sendable {
    let id: UUID
    let securityGroupID: UUID
    let direction: SecurityGroupRule.Direction
    let ethertype: SecurityGroupRule.Ethertype
    let protocolName: String?
    let portRangeMin: Int?
    let portRangeMax: Int?
    let remoteCIDR: String?
    let remoteGroupID: UUID?
    let log: Bool
    let ruleDescription: String?
    let createdAt: Date?
}

/// Immutable SQL bridge for rule mutations that still share a caller-owned
/// Fluent transaction with the parent security group.
enum LegacySecurityGroupRuleStore {
    static func rules(
        securityGroupIDs: [UUID],
        on db: PostgresStoreContext
    ) async throws -> [SecurityGroupRuleSnapshot] {
        guard !securityGroupIDs.isEmpty else { return [] }
        let rows = try await requireSQL(db).raw(
            """
            SELECT \(unsafeRaw: columns)
            FROM security_group_rules
            WHERE security_group_id = ANY(\(bind: securityGroupIDs))
            ORDER BY created_at, id
            """
        ).all(decoding: Record.self)
        return try rows.map { try $0.snapshot() }
    }

    static func rules(
        securityGroupID: UUID,
        on db: PostgresStoreContext
    ) async throws -> [SecurityGroupRuleSnapshot] {
        try await rules(securityGroupIDs: [securityGroupID], on: db)
    }

    static func rule(
        id: UUID,
        securityGroupID: UUID,
        on db: PostgresStoreContext
    ) async throws -> SecurityGroupRuleSnapshot? {
        guard let row = try await requireSQL(db).raw(
            """
            SELECT \(unsafeRaw: columns)
            FROM security_group_rules
            WHERE id = \(bind: id) AND security_group_id = \(bind: securityGroupID)
            LIMIT 1
            """
        ).first(decoding: Record.self) else { return nil }
        return try row.snapshot()
    }

    @discardableResult
    static func insert(
        id: UUID = UUID(),
        securityGroupID: UUID,
        direction: SecurityGroupRule.Direction,
        ethertype: SecurityGroupRule.Ethertype,
        protocolName: String? = nil,
        portRangeMin: Int? = nil,
        portRangeMax: Int? = nil,
        remoteCIDR: String? = nil,
        remoteGroupID: UUID? = nil,
        log: Bool = false,
        description: String? = nil,
        on db: PostgresStoreContext
    ) async throws -> SecurityGroupRuleSnapshot {
        guard let row = try await requireSQL(db).raw(
            """
            INSERT INTO security_group_rules (
                id, security_group_id, direction, ethertype, protocol,
                port_range_min, port_range_max, remote_cidr, remote_group_id,
                log, description, created_at
            ) VALUES (
                \(bind: id), \(bind: securityGroupID), \(bind: direction.rawValue),
                \(bind: ethertype.rawValue), \(bind: protocolName), \(bind: portRangeMin),
                \(bind: portRangeMax), \(bind: remoteCIDR), \(bind: remoteGroupID),
                \(bind: log), \(bind: description), CURRENT_TIMESTAMP
            )
            RETURNING \(unsafeRaw: columns)
            """
        ).first(decoding: Record.self) else {
            throw Abort(.internalServerError, reason: "Could not create security-group rule")
        }
        return try row.snapshot()
    }

    @discardableResult
    static func delete(
        id: UUID,
        securityGroupID: UUID,
        on db: PostgresStoreContext
    ) async throws -> UUID? {
        struct Deleted: Decodable { let id: UUID }
        return try await requireSQL(db).raw(
            """
            DELETE FROM security_group_rules
            WHERE id = \(bind: id) AND security_group_id = \(bind: securityGroupID)
            RETURNING id
            """
        ).first(decoding: Deleted.self)?.id
    }

    static func delete(
        securityGroupIDs: [UUID],
        on db: PostgresStoreContext
    ) async throws {
        guard !securityGroupIDs.isEmpty else { return }
        try await requireSQL(db).raw(
            "DELETE FROM security_group_rules WHERE security_group_id = ANY(\(bind: securityGroupIDs))"
        ).run()
    }

    static func count(
        securityGroupID: UUID,
        on db: PostgresStoreContext
    ) async throws -> Int {
        struct Count: Decodable { let count: Int }
        return try await requireSQL(db).raw(
            """
            SELECT count(*)::bigint AS count
            FROM security_group_rules
            WHERE security_group_id = \(bind: securityGroupID)
            """
        ).first(decoding: Count.self)?.count ?? 0
    }

    static func externalReferenceCount(
        remoteGroupID: UUID,
        excludingSecurityGroupID: UUID,
        on db: PostgresStoreContext
    ) async throws -> Int {
        struct Count: Decodable { let count: Int }
        return try await requireSQL(db).raw(
            """
            SELECT count(*)::bigint AS count
            FROM security_group_rules
            WHERE remote_group_id = \(bind: remoteGroupID)
              AND security_group_id <> \(bind: excludingSecurityGroupID)
            """
        ).first(decoding: Count.self)?.count ?? 0
    }

    static func remoteGroupIDs(
        securityGroupIDs: [UUID],
        on db: PostgresStoreContext
    ) async throws -> [UUID] {
        guard !securityGroupIDs.isEmpty else { return [] }
        struct RemoteGroup: Decodable { let id: UUID }
        return try await requireSQL(db).raw(
            """
            SELECT DISTINCT remote_group_id AS id
            FROM security_group_rules
            WHERE security_group_id = ANY(\(bind: securityGroupIDs))
              AND remote_group_id IS NOT NULL
            ORDER BY remote_group_id
            """
        ).all(decoding: RemoteGroup.self).map(\.id)
    }

    private struct Record: Decodable, Sendable {
        let id: UUID
        let securityGroupID: UUID
        let direction: String
        let ethertype: String
        let protocolName: String?
        let portRangeMin: Int?
        let portRangeMax: Int?
        let remoteCIDR: String?
        let remoteGroupID: UUID?
        let log: Bool
        let ruleDescription: String?
        let createdAt: Date?

        func snapshot() throws -> SecurityGroupRuleSnapshot {
            guard let direction = SecurityGroupRule.Direction(rawValue: direction),
                let ethertype = SecurityGroupRule.Ethertype(rawValue: ethertype)
            else {
                throw Abort(.internalServerError, reason: "Security-group rule has invalid persisted values")
            }
            return SecurityGroupRuleSnapshot(
                id: id,
                securityGroupID: securityGroupID,
                direction: direction,
                ethertype: ethertype,
                protocolName: protocolName,
                portRangeMin: portRangeMin,
                portRangeMax: portRangeMax,
                remoteCIDR: remoteCIDR,
                remoteGroupID: remoteGroupID,
                log: log,
                ruleDescription: ruleDescription,
                createdAt: createdAt)
        }
    }

    private static let columns = """
        id,
        security_group_id AS "securityGroupID",
        direction,
        ethertype,
        protocol AS "protocolName",
        port_range_min AS "portRangeMin",
        port_range_max AS "portRangeMax",
        remote_cidr AS "remoteCIDR",
        remote_group_id AS "remoteGroupID",
        log,
        description AS "ruleDescription",
        created_at AS "createdAt"
        """

    private static func requireSQL(_ db: PostgresStoreContext) throws -> PostgresStoreContext {
        guard let sql = db as? PostgresStoreContext else {
            throw Abort(.internalServerError, reason: "Security-group rules require PostgreSQL")
        }
        return sql
    }
}
