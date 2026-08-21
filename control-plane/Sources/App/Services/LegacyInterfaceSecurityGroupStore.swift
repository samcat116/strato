import ControlPlanePostgres
import Foundation
import Vapor

enum InterfaceWorkloadKind: Sendable {
    case vm
    case sandbox

    fileprivate var table: String {
        switch self {
        case .vm: "vm_interface_security_groups"
        case .sandbox: "sandbox_interface_security_groups"
        }
    }
}

struct InterfaceSecurityGroupSnapshot: Equatable, Sendable {
    let id: UUID
    let interfaceID: UUID
    let securityGroupID: UUID
    let createdAt: Date?
}

/// Immutable SQL bridge for the two deliberately separate NIC membership
/// tables. The table name comes only from `InterfaceWorkloadKind`; values are
/// always bound.
enum LegacyInterfaceSecurityGroupStore {
    static func memberships(
        kind: InterfaceWorkloadKind,
        interfaceIDs: [UUID]? = nil,
        securityGroupID: UUID? = nil,
        on db: PostgresStoreContext
    ) async throws -> [InterfaceSecurityGroupSnapshot] {
        if let interfaceIDs, interfaceIDs.isEmpty { return [] }
        let sql = try requireSQL(db)
        var query: PostgresSQLQuery =
            "SELECT \(unsafeRaw: columns) FROM \(unsafeRaw: kind.table) WHERE TRUE"
        if let interfaceIDs { query += " AND interface_id = ANY(\(bind: interfaceIDs))" }
        if let securityGroupID { query += " AND security_group_id = \(bind: securityGroupID)" }
        query += " ORDER BY created_at, id"
        return try await sql.raw(query).all(decoding: Record.self).map(\.snapshot)
    }

    static func membership(
        kind: InterfaceWorkloadKind,
        id: UUID,
        on db: PostgresStoreContext
    ) async throws -> InterfaceSecurityGroupSnapshot? {
        try await requireSQL(db).raw(
            """
            SELECT \(unsafeRaw: columns)
            FROM \(unsafeRaw: kind.table)
            WHERE id = \(bind: id)
            LIMIT 1
            """
        ).first(decoding: Record.self)?.snapshot
    }

    @discardableResult
    static func insert(
        kind: InterfaceWorkloadKind,
        id: UUID = UUID(),
        interfaceID: UUID,
        securityGroupID: UUID,
        on db: PostgresStoreContext
    ) async throws -> InterfaceSecurityGroupSnapshot {
        guard let row = try await requireSQL(db).raw(
            """
            INSERT INTO \(unsafeRaw: kind.table) (
                id, interface_id, security_group_id, created_at
            ) VALUES (
                \(bind: id), \(bind: interfaceID), \(bind: securityGroupID), CURRENT_TIMESTAMP
            )
            RETURNING \(unsafeRaw: columns)
            """
        ).first(decoding: Record.self) else {
            throw Abort(.internalServerError, reason: "Could not attach security group to interface")
        }
        return row.snapshot
    }

    @discardableResult
    static func delete(
        kind: InterfaceWorkloadKind,
        interfaceID: UUID,
        securityGroupID: UUID,
        on db: PostgresStoreContext
    ) async throws -> [UUID] {
        struct Deleted: Decodable { let id: UUID }
        return try await requireSQL(db).raw(
            """
            DELETE FROM \(unsafeRaw: kind.table)
            WHERE interface_id = \(bind: interfaceID)
              AND security_group_id = \(bind: securityGroupID)
            RETURNING id
            """
        ).all(decoding: Deleted.self).map(\.id)
    }

    static func count(
        kind: InterfaceWorkloadKind,
        interfaceIDs: [UUID]? = nil,
        securityGroupID: UUID? = nil,
        on db: PostgresStoreContext
    ) async throws -> Int {
        if let interfaceIDs, interfaceIDs.isEmpty { return 0 }
        struct Count: Decodable { let count: Int }
        let sql = try requireSQL(db)
        var query: PostgresSQLQuery =
            "SELECT count(*)::bigint AS count FROM \(unsafeRaw: kind.table) WHERE TRUE"
        if let interfaceIDs { query += " AND interface_id = ANY(\(bind: interfaceIDs))" }
        if let securityGroupID { query += " AND security_group_id = \(bind: securityGroupID)" }
        return try await sql.raw(query).first(decoding: Count.self)?.count ?? 0
    }

    static func securityGroupIDsByInterface(
        kind: InterfaceWorkloadKind,
        interfaceIDs: [UUID],
        on db: PostgresStoreContext
    ) async throws -> [UUID: [UUID]] {
        let memberships = try await memberships(
            kind: kind, interfaceIDs: interfaceIDs, on: db)
        return Dictionary(grouping: memberships, by: \.interfaceID).mapValues { rows in
            rows.map(\.securityGroupID).sorted { $0.uuidString < $1.uuidString }
        }
    }

    private struct Record: Decodable, Sendable {
        let id: UUID
        let interfaceID: UUID
        let securityGroupID: UUID
        let createdAt: Date?

        var snapshot: InterfaceSecurityGroupSnapshot {
            InterfaceSecurityGroupSnapshot(
                id: id,
                interfaceID: interfaceID,
                securityGroupID: securityGroupID,
                createdAt: createdAt)
        }
    }

    private static let columns = """
        id,
        interface_id AS "interfaceID",
        security_group_id AS "securityGroupID",
        created_at AS "createdAt"
        """

    private static func requireSQL(_ db: PostgresStoreContext) throws -> PostgresStoreContext {
        guard let sql = db as? PostgresStoreContext else {
            throw Abort(.internalServerError, reason: "Interface security groups require PostgreSQL")
        }
        return sql
    }
}
