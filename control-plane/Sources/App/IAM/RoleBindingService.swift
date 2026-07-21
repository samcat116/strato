import Fluent
import Foundation
import Vapor

/// Writes and reads `role_bindings` rows — the grants the Cedar evaluator
/// answers from. Call sites pass the transaction `Database` of the mutation
/// they accompany so binding rows never diverge from the relational rows they
/// mirror.
enum RoleBindingService {
    /// Idempotently grant the seeded role `role` to a principal on a node —
    /// the form nearly every code path uses.
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
        try await grant(
            principalType: principalType,
            principalID: principalID,
            roleID: role.seededID,
            nodeType: nodeType,
            nodeID: nodeID,
            createdBy: createdBy,
            expiresAt: expiresAt,
            on: db
        )
    }

    /// Idempotently grant the role with definition-row id `roleID` to a
    /// principal on a node. An existing row for the same (principal, role,
    /// node) is refreshed (its `expires_at` takes the new value) rather than
    /// duplicated.
    ///
    /// Callers validate the id names a live, in-scope role *before* granting
    /// (the member controllers' resolver, issue #608); the binding row itself
    /// stores it blind — a dangling id is dropped by every read path.
    static func grant(
        principalType: IAMPrincipalType,
        principalID: UUID,
        roleID: UUID,
        nodeType: IAMNodeType,
        nodeID: UUID,
        createdBy: UUID?,
        expiresAt: Date? = nil,
        on db: Database
    ) async throws {
        func find() async throws -> RoleBinding? {
            try await RoleBinding.query(on: db)
                .filter(\.$principalType == principalType.rawValue)
                .filter(\.$principalID == principalID)
                .filter(\.$role == roleID.uuidString)
                .filter(\.$nodeType == nodeType.rawValue)
                .filter(\.$nodeID == nodeID)
                .first()
        }
        func refresh(_ existing: RoleBinding) async throws {
            if existing.expiresAt != expiresAt {
                existing.expiresAt = expiresAt
                try await existing.save(on: db)
            }
        }

        if let existing = try await find() {
            try await refresh(existing)
            return
        }
        do {
            try await RoleBinding(
                principalType: principalType,
                principalID: principalID,
                roleID: roleID,
                nodeType: nodeType,
                nodeID: nodeID,
                expiresAt: expiresAt,
                createdBy: createdBy
            ).save(on: db)
        } catch {
            guard let dbError = error as? any DatabaseError, dbError.isConstraintFailure else { throw error }
            // A concurrent writer (another request, or another replica's boot
            // backfill) won the insert race on the uniqueness key. Outside a
            // transaction this is recoverable: adopt the winner's row and
            // apply our expiry. Inside an already-aborted Postgres transaction
            // the re-read below fails and propagates, which is the correct
            // outcome — the whole transaction retries or errors as a unit.
            guard let existing = try await find() else { throw error }
            try await refresh(existing)
        }
    }

    /// Revoke a principal's binding(s) on a node — one seeded role, or all of
    /// the principal's roles there when `role` is nil (e.g. membership
    /// removal).
    static func revoke(
        principalType: IAMPrincipalType,
        principalID: UUID,
        role: IAMRole? = nil,
        nodeType: IAMNodeType,
        nodeID: UUID,
        on db: Database
    ) async throws {
        try await revoke(
            principalType: principalType,
            principalID: principalID,
            roleID: role?.seededID,
            nodeType: nodeType,
            nodeID: nodeID,
            on: db
        )
    }

    /// Revoke a principal's binding(s) on a node — one role by definition-row
    /// id, or all of the principal's roles there when `roleID` is nil.
    static func revoke(
        principalType: IAMPrincipalType,
        principalID: UUID,
        roleID: UUID?,
        nodeType: IAMNodeType,
        nodeID: UUID,
        on db: Database
    ) async throws {
        let query = RoleBinding.query(on: db)
            .filter(\.$principalType == principalType.rawValue)
            .filter(\.$principalID == principalID)
            .filter(\.$nodeType == nodeType.rawValue)
            .filter(\.$nodeID == nodeID)
        if let roleID {
            query.filter(\.$role == roleID.uuidString)
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
