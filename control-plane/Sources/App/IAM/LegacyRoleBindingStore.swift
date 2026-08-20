import ControlPlanePostgres
import Fluent
import Foundation
import SQLKit
import Vapor

struct LegacyRoleBindingRecord: Decodable, Equatable, Sendable {
    let id: UUID
    let principalType: String
    let principalID: UUID
    let roleID: UUID
    let nodeType: String
    let nodeID: UUID
    let condition: String?
    let expiresAt: Date?
    let createdBy: UUID?
    let createdAt: Date?
}

struct LegacyRoleBindingWrite: Sendable {
    let id: UUID
    let principalType: String
    let principalID: UUID
    let roleID: UUID
    let nodeType: String
    let nodeID: UUID
    let condition: String?
    let expiresAt: Date?
    let createdBy: UUID?

    init(
        id: UUID = UUID(),
        principalType: String,
        principalID: UUID,
        roleID: UUID,
        nodeType: String,
        nodeID: UUID,
        condition: String? = nil,
        expiresAt: Date? = nil,
        createdBy: UUID? = nil
    ) {
        self.id = id
        self.principalType = principalType
        self.principalID = principalID
        self.roleID = roleID
        self.nodeType = nodeType
        self.nodeID = nodeID
        self.condition = condition
        self.expiresAt = expiresAt
        self.createdBy = createdBy
    }
}

/// Immutable SQL bridge for binding operations that still share a caller-owned
/// Fluent transaction. New domain modules use `IAMPersistence` directly.
enum LegacyRoleBindingStore {
    static let conditionConstraintName = "ck_role_bindings_condition_unsupported"

    static func bindings(
        principalType: String? = nil,
        principalID: UUID? = nil,
        excludingPrincipalID: UUID? = nil,
        principalIDs: [UUID]? = nil,
        roleID: UUID? = nil,
        nodeType: String? = nil,
        nodeID: UUID? = nil,
        nodeIDs: [UUID]? = nil,
        subjects: [IAMOwnerReference] = [],
        nodes: [IAMNodeReference] = [],
        activeAt: Date? = nil,
        on db: any Database
    ) async throws -> [LegacyRoleBindingRecord] {
        if let principalIDs, principalIDs.isEmpty { return [] }
        if let nodeIDs, nodeIDs.isEmpty { return [] }
        let sql = try requireSQL(db)
        var query: SQLQueryString = "SELECT \(unsafeRaw: columns) FROM role_bindings WHERE TRUE"
        if let principalType { query += " AND principal_type = \(bind: principalType)" }
        if let principalID { query += " AND principal_id = \(bind: principalID)" }
        if let excludingPrincipalID { query += " AND principal_id != \(bind: excludingPrincipalID)" }
        if let principalIDs { query += " AND principal_id = ANY(\(bind: principalIDs))" }
        if let roleID { query += " AND role_id = \(bind: roleID)" }
        if let nodeType { query += " AND node_type = \(bind: nodeType)" }
        if let nodeID { query += " AND node_id = \(bind: nodeID)" }
        if let nodeIDs { query += " AND node_id = ANY(\(bind: nodeIDs))" }
        if !subjects.isEmpty {
            query += " AND (FALSE"
            for subject in subjects {
                query += " OR (principal_type = \(bind: subject.type) AND principal_id = \(bind: subject.id))"
            }
            query += ")"
        }
        if !nodes.isEmpty {
            query += " AND (FALSE"
            for node in nodes {
                query += " OR (node_type = \(bind: node.type) AND node_id = \(bind: node.id))"
            }
            query += ")"
        }
        if let activeAt {
            query += " AND (expires_at IS NULL OR expires_at > \(bind: activeAt))"
        }
        query += " ORDER BY created_at, id"
        return try await sql.raw(query).all(decoding: LegacyRoleBindingRecord.self)
    }

    static func binding(
        principalType: String,
        principalID: UUID,
        roleID: UUID,
        nodeType: String,
        nodeID: UUID,
        on db: any Database
    ) async throws -> LegacyRoleBindingRecord? {
        try await bindings(
            principalType: principalType,
            principalID: principalID,
            roleID: roleID,
            nodeType: nodeType,
            nodeID: nodeID,
            on: db).first
    }

    @discardableResult
    static func insert(
        _ write: LegacyRoleBindingWrite,
        on db: any Database
    ) async throws -> LegacyRoleBindingRecord {
        guard let binding = try await requireSQL(db).raw(
            """
            INSERT INTO role_bindings (
                id, principal_type, principal_id, role_id, node_type, node_id,
                condition, expires_at, created_by, created_at
            ) VALUES (
                \(bind: write.id), \(bind: write.principalType), \(bind: write.principalID),
                \(bind: write.roleID), \(bind: write.nodeType), \(bind: write.nodeID),
                \(bind: write.condition), \(bind: write.expiresAt), \(bind: write.createdBy),
                CURRENT_TIMESTAMP
            )
            RETURNING \(unsafeRaw: columns)
            """
        ).first(decoding: LegacyRoleBindingRecord.self) else {
            throw Abort(.internalServerError, reason: "Could not create role binding")
        }
        return binding
    }

    static func updateExpiry(
        id: UUID,
        expiresAt: Date?,
        on db: any Database
    ) async throws {
        try await requireSQL(db).raw(
            "UPDATE role_bindings SET expires_at = \(bind: expiresAt) WHERE id = \(bind: id)"
        ).run()
    }

    static func delete(ids: [UUID], on db: any Database) async throws {
        guard !ids.isEmpty else { return }
        try await requireSQL(db).raw(
            "DELETE FROM role_bindings WHERE id = ANY(\(bind: ids))"
        ).run()
    }

    static func countOtherUsableOrganizationAdmins(
        excluding userID: UUID,
        organizationID: UUID,
        adminRoleID: UUID,
        activeAt: Date = Date(),
        on db: any Database
    ) async throws -> Int {
        struct CountRow: Decodable { let count: Int }
        return try await requireSQL(db).raw(
            """
            SELECT count(*)::bigint AS count
            FROM role_bindings AS binding
            INNER JOIN users AS candidate ON candidate.id = binding.principal_id
            WHERE binding.principal_type = 'user'
              AND binding.principal_id != \(bind: userID)
              AND binding.role_id = \(bind: adminRoleID)
              AND binding.node_type = 'organization'
              AND binding.node_id = \(bind: organizationID)
              AND (binding.expires_at IS NULL OR binding.expires_at > \(bind: activeAt))
              AND candidate.disabled_at IS NULL
              AND (candidate.scim_provisioned = false OR candidate.scim_active = true)
            """
        ).first(decoding: CountRow.self)?.count ?? 0
    }

    private static let columns = """
        id,
        principal_type AS "principalType",
        principal_id AS "principalID",
        role_id AS "roleID",
        node_type AS "nodeType",
        node_id AS "nodeID",
        condition,
        expires_at AS "expiresAt",
        created_by AS "createdBy",
        created_at AS "createdAt"
        """

    private static func requireSQL(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "IAM role bindings require PostgreSQL")
        }
        return sql
    }
}
