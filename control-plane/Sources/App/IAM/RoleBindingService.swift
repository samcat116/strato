import Fluent
import Foundation
import Vapor

/// Writes and reads `role_bindings` rows. During the migration these rows are
/// dual-written next to the authoritative SpiceDB tuples; call sites pass the
/// transaction `Database` of the mutation they accompany so binding rows never
/// diverge from the relational rows they mirror.
enum RoleBindingService {
    /// Idempotently grant `role` to a principal on a node. An existing row for
    /// the same (principal, role, node) is refreshed (its `expires_at` takes
    /// the new value) rather than duplicated.
    static func grant(
        principalType: IAMPrincipalType,
        principalID: UUID,
        role: IAMRole,
        nodeType: IAMNodeType,
        nodeID: UUID,
        createdBy: UUID?,
        expiresAt: Date? = nil,
        on db: Database
    ) async throws {
        if let existing = try await RoleBinding.query(on: db)
            .filter(\.$principalType == principalType.rawValue)
            .filter(\.$principalID == principalID)
            .filter(\.$role == role.rawValue)
            .filter(\.$nodeType == nodeType.rawValue)
            .filter(\.$nodeID == nodeID)
            .first()
        {
            if existing.expiresAt != expiresAt {
                existing.expiresAt = expiresAt
                try await existing.save(on: db)
            }
            return
        }
        try await RoleBinding(
            principalType: principalType,
            principalID: principalID,
            role: role,
            nodeType: nodeType,
            nodeID: nodeID,
            expiresAt: expiresAt,
            createdBy: createdBy
        ).save(on: db)
    }

    /// Revoke a principal's binding(s) on a node — one role, or all of the
    /// principal's roles there when `role` is nil (e.g. membership removal).
    static func revoke(
        principalType: IAMPrincipalType,
        principalID: UUID,
        role: IAMRole? = nil,
        nodeType: IAMNodeType,
        nodeID: UUID,
        on db: Database
    ) async throws {
        let query = RoleBinding.query(on: db)
            .filter(\.$principalType == principalType.rawValue)
            .filter(\.$principalID == principalID)
            .filter(\.$nodeType == nodeType.rawValue)
            .filter(\.$nodeID == nodeID)
        if let role {
            query.filter(\.$role == role.rawValue)
        }
        try await query.delete()
    }

    /// Remove every binding attached to a node. Called when the node itself is
    /// deleted (bindings have no FK to the resources they protect).
    static func revokeAll(nodeType: IAMNodeType, nodeID: UUID, on db: Database) async throws {
        try await RoleBinding.query(on: db)
            .filter(\.$nodeType == nodeType.rawValue)
            .filter(\.$nodeID == nodeID)
            .delete()
    }

    /// The unexpired bindings on a node.
    static func activeBindings(nodeType: IAMNodeType, nodeID: UUID, on db: Database) async throws -> [RoleBinding] {
        try await RoleBinding.query(on: db)
            .filter(\.$nodeType == nodeType.rawValue)
            .filter(\.$nodeID == nodeID)
            .active()
            .all()
    }

    /// The unexpired bindings held by a principal.
    static func activeBindings(
        principalType: IAMPrincipalType, principalID: UUID, on db: Database
    ) async throws -> [RoleBinding] {
        try await RoleBinding.query(on: db)
            .filter(\.$principalType == principalType.rawValue)
            .filter(\.$principalID == principalID)
            .active()
            .all()
    }
}
