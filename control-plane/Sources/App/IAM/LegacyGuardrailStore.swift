import ControlPlanePostgres
import Foundation
import Vapor

/// Immutable SQL bridge for guardrail operations that still share a
/// caller-owned Fluent transaction. New request paths use `IAMPersistence`.
enum LegacyGuardrailStore {
    static func guardrail(id: UUID, on db: PostgresStoreContext) async throws -> IAMGuardrailSnapshot? {
        try await requireSQL(db).raw(
            "SELECT \(unsafeRaw: columns) FROM iam_guardrails WHERE id = \(bind: id) LIMIT 1"
        ).first(decoding: Record.self)?.snapshot
    }

    static func count(on db: PostgresStoreContext) async throws -> Int {
        struct Count: Decodable { let count: Int }
        return try await requireSQL(db).raw(
            "SELECT count(*)::bigint AS count FROM iam_guardrails"
        ).first(decoding: Count.self)?.count ?? 0
    }

    static func insert(
        _ guardrail: IAMGuardrailSnapshot,
        on db: PostgresStoreContext
    ) async throws -> IAMGuardrailSnapshot {
        guard let record = try await requireSQL(db).raw(
            """
            INSERT INTO iam_guardrails (
                id, name, description, node_type, node_id, effect, actions,
                principal_match_kind, principal_match_id, resource_match_kind,
                resource_match_value, enabled, created_by, created_at, updated_at,
                cedar_text, authored
            ) VALUES (
                \(bind: guardrail.id), \(bind: guardrail.name), \(bind: guardrail.description),
                \(bind: guardrail.nodeType), \(bind: guardrail.nodeID), \(bind: guardrail.effect),
                \(bind: guardrail.actions), \(bind: guardrail.principalMatchKind),
                \(bind: guardrail.principalMatchID), \(bind: guardrail.resourceMatchKind),
                \(bind: guardrail.resourceMatchValue), \(bind: guardrail.enabled),
                \(bind: guardrail.createdBy), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP,
                \(bind: guardrail.cedarText), \(bind: guardrail.authored)
            )
            RETURNING \(unsafeRaw: columns)
            """
        ).first(decoding: Record.self) else {
            throw Abort(.internalServerError, reason: "Could not create guardrail")
        }
        return record.snapshot
    }

    static func replace(
        _ guardrail: IAMGuardrailSnapshot,
        on db: PostgresStoreContext
    ) async throws -> IAMGuardrailSnapshot? {
        try await requireSQL(db).raw(
            """
            UPDATE iam_guardrails
            SET name = \(bind: guardrail.name),
                description = \(bind: guardrail.description),
                node_type = \(bind: guardrail.nodeType),
                node_id = \(bind: guardrail.nodeID),
                effect = \(bind: guardrail.effect),
                actions = \(bind: guardrail.actions),
                principal_match_kind = \(bind: guardrail.principalMatchKind),
                principal_match_id = \(bind: guardrail.principalMatchID),
                resource_match_kind = \(bind: guardrail.resourceMatchKind),
                resource_match_value = \(bind: guardrail.resourceMatchValue),
                enabled = \(bind: guardrail.enabled),
                created_by = \(bind: guardrail.createdBy),
                cedar_text = \(bind: guardrail.cedarText),
                authored = \(bind: guardrail.authored),
                updated_at = CURRENT_TIMESTAMP
            WHERE id = \(bind: guardrail.id)
            RETURNING \(unsafeRaw: columns)
            """
        ).first(decoding: Record.self)?.snapshot
    }

    static func missingCedarText(on db: PostgresStoreContext) async throws -> [IAMGuardrailSnapshot] {
        try await requireSQL(db).raw(
            "SELECT \(unsafeRaw: columns) FROM iam_guardrails WHERE cedar_text IS NULL ORDER BY id"
        ).all(decoding: Record.self).map(\.snapshot)
    }

    @discardableResult
    static func setCedarText(
        id: UUID,
        cedarText: String?,
        onlyIfMissing: Bool = false,
        on db: PostgresStoreContext
    ) async throws -> Bool {
        var query: PostgresSQLQuery =
            "UPDATE iam_guardrails SET cedar_text = \(bind: cedarText), updated_at = CURRENT_TIMESTAMP WHERE id = \(bind: id)"
        if onlyIfMissing { query += " AND cedar_text IS NULL" }
        query += " RETURNING id"
        return try await requireSQL(db).raw(query).first() != nil
    }

    static func attached(
        to node: IAMNode,
        on db: PostgresStoreContext
    ) async throws -> [IAMGuardrailSnapshot] {
        try await requireSQL(db).raw(
            """
            SELECT \(unsafeRaw: columns)
            FROM iam_guardrails
            WHERE node_type = \(bind: node.type.rawValue) AND node_id = \(bind: node.id)
            ORDER BY name, id
            """
        ).all(decoding: Record.self).map(\.snapshot)
    }

    static func enabled(
        along chain: [IAMNode],
        on db: PostgresStoreContext
    ) async throws -> [IAMGuardrailSnapshot] {
        guard !chain.isEmpty else { return [] }
        let sql = try requireSQL(db)
        var query: PostgresSQLQuery =
            "SELECT \(unsafeRaw: columns) FROM iam_guardrails WHERE enabled = true AND (FALSE"
        for node in chain {
            query +=
                " OR (node_type = \(bind: node.type.rawValue) AND node_id = \(bind: node.id))"
        }
        query += ") ORDER BY name, id"
        return try await sql.raw(query).all(decoding: Record.self).map(\.snapshot)
    }

    private struct Record: Decodable, Sendable {
        let id: UUID
        let name: String
        let description: String?
        let nodeType: String
        let nodeID: UUID
        let effect: String
        let actions: [String]
        let principalMatchKind: String
        let principalMatchID: UUID?
        let resourceMatchKind: String
        let resourceMatchValue: String?
        let enabled: Bool
        let createdBy: UUID?
        let createdAt: Date?
        let updatedAt: Date?
        let cedarText: String?
        let authored: Bool

        var snapshot: IAMGuardrailSnapshot {
            IAMGuardrailSnapshot(
                id: id,
                name: name,
                description: description,
                nodeType: nodeType,
                nodeID: nodeID,
                effect: effect,
                actions: actions,
                principalMatchKind: principalMatchKind,
                principalMatchID: principalMatchID,
                resourceMatchKind: resourceMatchKind,
                resourceMatchValue: resourceMatchValue,
                enabled: enabled,
                createdBy: createdBy,
                createdAt: createdAt,
                updatedAt: updatedAt,
                cedarText: cedarText,
                authored: authored
            )
        }
    }

    private static let columns = """
        id,
        name,
        description,
        node_type AS "nodeType",
        node_id AS "nodeID",
        effect,
        actions,
        principal_match_kind AS "principalMatchKind",
        principal_match_id AS "principalMatchID",
        resource_match_kind AS "resourceMatchKind",
        resource_match_value AS "resourceMatchValue",
        enabled,
        created_by AS "createdBy",
        created_at AS "createdAt",
        updated_at AS "updatedAt",
        cedar_text AS "cedarText",
        authored
        """

    private static func requireSQL(_ db: PostgresStoreContext) throws -> PostgresStoreContext {
        guard let sql = db as? PostgresStoreContext else {
            throw Abort(.internalServerError, reason: "IAM guardrails require PostgreSQL")
        }
        return sql
    }
}
