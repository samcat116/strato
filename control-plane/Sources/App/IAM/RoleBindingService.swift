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

    /// Remove every binding held by a principal, on any node in any
    /// organization. Called when the principal itself ceases to exist (user or
    /// group deletion): a departing principal's bindings do not live only in
    /// its own org — cross-org bindings are supported by design (issue #485) —
    /// so the sweep keys on the principal alone.
    static func revokeAll(principalType: IAMPrincipalType, principalID: UUID, on db: Database) async throws {
        try await RoleBinding.query(on: db)
            .filter(\.$principalType == principalType.rawValue)
            .filter(\.$principalID == principalID)
            .delete()
    }

    /// Remove a principal's bindings on every node whose tree root is
    /// `organizationID` — the offboarding sweep for leaving one org. Bindings
    /// the principal holds in *other* orgs are deliberately untouched: those
    /// are the other orgs' grants to revoke, not this one's.
    ///
    /// Sweeping the whole subtree (not just the org node) matters: a removed
    /// member's project- and resource-level bindings inside the org would
    /// otherwise outlive the membership as cross-org access nobody gated
    /// through `iam:grantExternal` (issue #485). Bindings on nodes whose chain
    /// no longer resolves to any org are left alone — they cannot be
    /// attributed to this org, and a dangling node's bindings are dropped when
    /// the node deletion's own `revokeAll(nodeType:nodeID:)` runs.
    static func revokeAll(
        principalType: IAMPrincipalType,
        principalID: UUID,
        rootedInOrganization organizationID: UUID,
        on db: Database
    ) async throws {
        let bindings = try await RoleBinding.query(on: db)
            .filter(\.$principalType == principalType.rawValue)
            .filter(\.$principalID == principalID)
            .all()
        var rootByNode: [IAMNode: UUID?] = [:]
        for binding in bindings {
            guard let nodeType = IAMNodeType(rawValue: binding.nodeType) else { continue }
            let node = IAMNode(type: nodeType, id: binding.nodeID)
            let root: UUID?
            if let cached = rootByNode[node] {
                root = cached
            } else {
                let chain = try await IAMResourceTree.ancestors(of: node, on: db)
                root = chain.last?.type == .organization ? chain.last?.id : nil
                rootByNode[node] = root
            }
            if root == organizationID {
                try await binding.delete(on: db)
            }
        }
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
