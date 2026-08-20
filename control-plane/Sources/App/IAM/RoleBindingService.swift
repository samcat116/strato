import ControlPlanePostgres
import Fluent
import Foundation
import SQLKit
import Vapor

/// The authoritative write and read path for grants. `role_bindings` is the
/// only policy representation changed by a grant mutation.
enum RoleBindingService {
    private static func subject(
        _ type: IAMPrincipalType,
        _ id: UUID
    ) -> IAMOwnerReference {
        IAMOwnerReference(type: type.rawValue, id: id)
    }

    private static func nodeReference(
        _ type: IAMNodeType,
        _ id: UUID
    ) -> IAMNodeReference {
        IAMNodeReference(type: type.rawValue, id: id)
    }

    private static func snapshot(
        principalType: IAMPrincipalType,
        principalID: UUID,
        roleID: UUID,
        nodeType: IAMNodeType,
        nodeID: UUID,
        createdBy: UUID?,
        expiresAt: Date?
    ) -> IAMRoleBindingSnapshot {
        IAMRoleBindingSnapshot(
            principalType: principalType.rawValue,
            principalID: principalID,
            roleID: roleID,
            nodeType: nodeType.rawValue,
            nodeID: nodeID,
            expiresAt: expiresAt,
            createdBy: createdBy
        )
    }

    static func insertExclusiveGrant(
        principalType: IAMPrincipalType,
        principalID: UUID,
        roleID: UUID,
        node: IAMNode,
        createdBy: UUID?,
        using iam: IAMPersistence
    ) async throws {
        do {
            try await iam.withMembershipNodeLocked(
                node: nodeReference(node.type, node.id)
            ) { transaction in
                let owner = subject(principalType, principalID)
                let target = nodeReference(node.type, node.id)
                guard try await transaction.activeBindings(subject: owner, node: target).isEmpty else {
                    throw Abort(
                        .conflict,
                        reason: "Principal already has a role on this \(nodeLabel(node.type))"
                    )
                }
                _ = try await transaction.ensureGrant(
                    snapshot(
                        principalType: principalType,
                        principalID: principalID,
                        roleID: roleID,
                        nodeType: node.type,
                        nodeID: node.id,
                        createdBy: createdBy,
                        expiresAt: nil
                    )
                )
            }
        } catch IAMPersistenceError.membershipNodeNotFound {
            throw Abort(.notFound, reason: "Grant target not found")
        } catch IAMPersistenceError.unsupportedMembershipNodeType {
            throw Abort(
                .internalServerError,
                reason: "Exclusive membership grants are unsupported on \(node.type.rawValue)"
            )
        }
    }

    static func replaceExclusiveGrant(
        principalType: IAMPrincipalType,
        principalID: UUID,
        roleID: UUID,
        node: IAMNode,
        createdBy: UUID?,
        using iam: IAMPersistence
    ) async throws {
        try await iam.withMembershipNodeLocked(
            node: nodeReference(node.type, node.id)
        ) { transaction in
            let owner = subject(principalType, principalID)
            let target = nodeReference(node.type, node.id)
            guard !(try await transaction.activeBindings(subject: owner, node: target)).isEmpty else {
                throw Abort(
                    .notFound,
                    reason: "Principal has no role on this \(nodeLabel(node.type))"
                )
            }
            _ = try await transaction.revoke(subject: owner, node: target)
            _ = try await transaction.ensureGrant(
                snapshot(
                    principalType: principalType,
                    principalID: principalID,
                    roleID: roleID,
                    nodeType: node.type,
                    nodeID: node.id,
                    createdBy: createdBy,
                    expiresAt: nil
                )
            )
        }
    }

    static func setExclusiveGrant(
        principalType: IAMPrincipalType,
        principalID: UUID,
        roleID: UUID?,
        node: IAMNode,
        createdBy: UUID?,
        using iam: IAMPersistence
    ) async throws {
        try await iam.withMembershipNodeLocked(
            node: nodeReference(node.type, node.id)
        ) { transaction in
            let owner = subject(principalType, principalID)
            let target = nodeReference(node.type, node.id)
            _ = try await transaction.revoke(subject: owner, node: target)
            if let roleID {
                _ = try await transaction.ensureGrant(
                    snapshot(
                        principalType: principalType,
                        principalID: principalID,
                        roleID: roleID,
                        nodeType: node.type,
                        nodeID: node.id,
                        createdBy: createdBy,
                        expiresAt: nil
                    )
                )
            }
        }
    }

    @discardableResult
    static func revokeExclusiveGrant(
        principalType: IAMPrincipalType,
        principalID: UUID,
        node: IAMNode,
        using iam: IAMPersistence
    ) async throws -> [UUID] {
        try await iam.withMembershipNodeLocked(
            node: nodeReference(node.type, node.id)
        ) { transaction in
            let owner = subject(principalType, principalID)
            let target = nodeReference(node.type, node.id)
            let existing = try await transaction.activeBindings(subject: owner, node: target)
            guard !existing.isEmpty else {
                throw Abort(
                    .notFound,
                    reason: "Principal has no role on this \(nodeLabel(node.type))"
                )
            }
            _ = try await transaction.revoke(subject: owner, node: target)
            return existing.map(\.roleID)
        }
    }

    static func grant(
        principalType: IAMPrincipalType,
        principalID: UUID,
        role: IAMRole,
        nodeType: IAMNodeType,
        nodeID: UUID,
        createdBy: UUID?,
        expiresAt: Date? = nil,
        using iam: IAMPersistence
    ) async throws {
        try await grant(
            principalType: principalType,
            principalID: principalID,
            roleID: role.seededID,
            nodeType: nodeType,
            nodeID: nodeID,
            createdBy: createdBy,
            expiresAt: expiresAt,
            using: iam
        )
    }

    static func grant(
        principalType: IAMPrincipalType,
        principalID: UUID,
        roleID: UUID,
        nodeType: IAMNodeType,
        nodeID: UUID,
        createdBy: UUID?,
        expiresAt: Date? = nil,
        using iam: IAMPersistence
    ) async throws {
        _ = try await iam.ensureGrant(
            snapshot(
                principalType: principalType,
                principalID: principalID,
                roleID: roleID,
                nodeType: nodeType,
                nodeID: nodeID,
                createdBy: createdBy,
                expiresAt: expiresAt
            )
        )
    }

    static func revoke(
        principalType: IAMPrincipalType,
        principalID: UUID,
        role: IAMRole? = nil,
        nodeType: IAMNodeType,
        nodeID: UUID,
        using iam: IAMPersistence
    ) async throws {
        try await revoke(
            principalType: principalType,
            principalID: principalID,
            roleID: role?.seededID,
            nodeType: nodeType,
            nodeID: nodeID,
            using: iam
        )
    }

    static func revoke(
        principalType: IAMPrincipalType,
        principalID: UUID,
        roleID: UUID?,
        nodeType: IAMNodeType,
        nodeID: UUID,
        using iam: IAMPersistence
    ) async throws {
        let owner = subject(principalType, principalID)
        let target = nodeReference(nodeType, nodeID)
        if let roleID {
            _ = try await iam.revoke(subject: owner, roleID: roleID, node: target)
        } else {
            _ = try await iam.revoke(subject: owner, node: target)
        }
    }

    static func revokeAll(
        principalType: IAMPrincipalType,
        principalID: UUID,
        using iam: IAMPersistence
    ) async throws {
        _ = try await iam.revokeAll(forSubjects: [subject(principalType, principalID)])
    }

    static func revokeAll(
        principalType: IAMPrincipalType,
        principalID: UUID,
        rootedInOrganization organizationID: UUID,
        using iam: IAMPersistence
    ) async throws {
        let owner = subject(principalType, principalID)
        let bindings = try await iam.allBindings(forSubject: owner)
        let typed = bindings.compactMap { binding -> (IAMNode, IAMRoleBindingSnapshot)? in
            guard let type = IAMNodeType(rawValue: binding.nodeType) else { return nil }
            return (IAMNode(type: type, id: binding.nodeID), binding)
        }
        let resolutions = try await IAMResourceTree.resolve(typed.map { $0.0 }, using: iam)
        for (node, binding) in typed {
            guard resolutions[node]?.chain.last == IAMNode(type: .organization, id: organizationID)
            else { continue }
            _ = try await iam.revoke(
                subject: owner,
                roleID: binding.roleID,
                node: nodeReference(node.type, node.id)
            )
        }
    }

    static func revokeAll(
        nodeType: IAMNodeType,
        nodeID: UUID,
        using iam: IAMPersistence
    ) async throws {
        _ = try await iam.revokeAll(atNodes: [nodeReference(nodeType, nodeID)])
    }

    static func revokeAll(
        nodeType: IAMNodeType,
        nodeIDs: [UUID],
        using iam: IAMPersistence
    ) async throws {
        _ = try await iam.revokeAll(
            atNodes: nodeIDs.map { nodeReference(nodeType, $0) }
        )
    }

    static func revokeAll(
        principalType: IAMPrincipalType,
        principalIDs: [UUID],
        using iam: IAMPersistence
    ) async throws {
        _ = try await iam.revokeAll(
            forSubjects: principalIDs.map { subject(principalType, $0) }
        )
    }

    static func activeBindings(
        nodeType: IAMNodeType,
        nodeID: UUID,
        using iam: IAMPersistence
    ) async throws -> [IAMRoleBindingSnapshot] {
        try await iam.bindings(at: [nodeReference(nodeType, nodeID)])
    }

    static func activeBindings(
        principalType: IAMPrincipalType,
        principalID: UUID,
        nodeType: IAMNodeType,
        nodeID: UUID,
        using iam: IAMPersistence
    ) async throws -> [IAMRoleBindingSnapshot] {
        try await iam.activeBindings(
            subject: subject(principalType, principalID),
            node: nodeReference(nodeType, nodeID)
        )
    }

    static func activeBindings(
        principalType: IAMPrincipalType,
        principalID: UUID,
        using iam: IAMPersistence
    ) async throws -> [IAMRoleBindingSnapshot] {
        try await iam.activeBindings(forSubject: subject(principalType, principalID))
    }

    /// Insert the only active membership grant a principal may hold on one
    /// organization, folder, or project. The node row lock serializes grants
    /// of different roles, which the role-inclusive binding uniqueness key
    /// alone cannot do.
    static func insertExclusiveGrant(
        principalType: IAMPrincipalType,
        principalID: UUID,
        roleID: UUID,
        node: IAMNode,
        createdBy: UUID?,
        on db: Database
    ) async throws {
        try await withMembershipNodeLocked(node, on: db) { transaction in
            let existing = try await activeBindings(
                principalType: principalType, principalID: principalID,
                nodeType: node.type, nodeID: node.id, on: transaction)
            guard existing.isEmpty else {
                throw Abort(.conflict, reason: "Principal already has a role on this \(nodeLabel(node.type))")
            }
            try await grant(
                principalType: principalType, principalID: principalID, roleID: roleID,
                nodeType: node.type, nodeID: node.id, createdBy: createdBy, on: transaction)
        }
    }

    /// Replace all of a principal's bindings on a membership node with one
    /// canonical role binding.
    static func replaceExclusiveGrant(
        principalType: IAMPrincipalType,
        principalID: UUID,
        roleID: UUID,
        node: IAMNode,
        createdBy: UUID?,
        on db: Database
    ) async throws {
        try await withMembershipNodeLocked(node, on: db) { transaction in
            let existing = try await activeBindings(
                principalType: principalType, principalID: principalID,
                nodeType: node.type, nodeID: node.id, on: transaction)
            guard !existing.isEmpty else {
                throw Abort(.notFound, reason: "Principal has no role on this \(nodeLabel(node.type))")
            }
            try await revoke(
                principalType: principalType, principalID: principalID, roleID: nil,
                nodeType: node.type, nodeID: node.id, on: transaction)
            try await grant(
                principalType: principalType, principalID: principalID, roleID: roleID,
                nodeType: node.type, nodeID: node.id, createdBy: createdBy, on: transaction)
        }
    }

    /// Set a membership node to exactly one role, or to bare membership when
    /// `roleID` is nil. Unlike `replaceExclusiveGrant`, this accepts either a
    /// bound or bare current state and is used by organization membership.
    static func setExclusiveGrant(
        principalType: IAMPrincipalType,
        principalID: UUID,
        roleID: UUID?,
        node: IAMNode,
        createdBy: UUID?,
        on db: Database
    ) async throws {
        try await withMembershipNodeLocked(node, on: db) { transaction in
            try await revoke(
                principalType: principalType, principalID: principalID, roleID: nil,
                nodeType: node.type, nodeID: node.id, on: transaction)
            if let roleID {
                try await grant(
                    principalType: principalType, principalID: principalID, roleID: roleID,
                    nodeType: node.type, nodeID: node.id, createdBy: createdBy, on: transaction)
            }
        }
    }

    /// Revoke every binding a principal holds directly on a membership node,
    /// returning the active roles removed for audit rendering.
    @discardableResult
    static func revokeExclusiveGrant(
        principalType: IAMPrincipalType,
        principalID: UUID,
        node: IAMNode,
        on db: Database
    ) async throws -> [UUID] {
        try await withMembershipNodeLocked(node, on: db) { transaction in
            let existing = try await activeBindings(
                principalType: principalType, principalID: principalID,
                nodeType: node.type, nodeID: node.id, on: transaction)
            guard !existing.isEmpty else {
                throw Abort(.notFound, reason: "Principal has no role on this \(nodeLabel(node.type))")
            }
            try await revoke(
                principalType: principalType, principalID: principalID, roleID: nil,
                nodeType: node.type, nodeID: node.id, on: transaction)
            return existing.map(\.roleID)
        }
    }

    /// Serialize a membership mutation on its organization, folder, or project
    /// row. Organization callers also use this boundary to make last-admin
    /// checks atomic with the membership and binding writes.
    static func withMembershipNodeLocked<T: Sendable>(
        _ node: IAMNode,
        on db: Database,
        _ body: @Sendable @escaping (any Database) async throws -> T
    ) async throws -> T {
        let table: String
        switch node.type {
        case .organization: table = "organizations"
        case .organizationalUnit: table = "organizational_units"
        case .project: table = "projects"
        default:
            throw Abort(
                .internalServerError,
                reason: "Exclusive membership grants are unsupported on \(node.type.rawValue)")
        }
        return try await db.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw Abort(.internalServerError, reason: "Membership grant writes require a SQL database")
            }
            let rows = try await sql.raw(
                "SELECT id FROM \(ident: table) WHERE id = \(bind: node.id) FOR UPDATE"
            ).all()
            guard !rows.isEmpty else { throw Abort(.notFound, reason: "Grant target not found") }
            return try await body(transaction)
        }
    }

    private static func nodeLabel(_ type: IAMNodeType) -> String {
        type == .organizationalUnit ? "folder" : type.rawValue
    }

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
        func find() async throws -> LegacyRoleBindingRecord? {
            try await LegacyRoleBindingStore.binding(
                principalType: principalType.rawValue,
                principalID: principalID,
                roleID: roleID,
                nodeType: nodeType.rawValue,
                nodeID: nodeID,
                on: db)
        }
        func refresh(_ existing: LegacyRoleBindingRecord) async throws {
            if existing.expiresAt != expiresAt {
                try await LegacyRoleBindingStore.updateExpiry(
                    id: existing.id, expiresAt: expiresAt, on: db)
            }
        }

        if let existing = try await find() {
            try await refresh(existing)
            return
        }
        do {
            try await LegacyRoleBindingStore.insert(
                LegacyRoleBindingWrite(
                principalType: principalType.rawValue,
                principalID: principalID,
                roleID: roleID,
                nodeType: nodeType.rawValue,
                nodeID: nodeID,
                expiresAt: expiresAt,
                createdBy: createdBy
            ), on: db)
        } catch {
            guard let dbError = error as? any DatabaseError, dbError.isConstraintFailure else { throw error }
            // A concurrent writer won the insert race on the uniqueness key. Outside a
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
        let rows = try await LegacyRoleBindingStore.bindings(
            principalType: principalType.rawValue,
            principalID: principalID,
            roleID: roleID,
            nodeType: nodeType.rawValue,
            nodeID: nodeID,
            on: db)
        try await LegacyRoleBindingStore.delete(ids: rows.map(\.id), on: db)
    }

    /// Remove every binding held by a principal, on any node in any
    /// organization. Called when the principal itself ceases to exist (user or
    /// group deletion): a departing principal's bindings do not live only in
    /// its own org — cross-org bindings are supported by design (issue #485) —
    /// so the sweep keys on the principal alone.
    static func revokeAll(principalType: IAMPrincipalType, principalID: UUID, on db: Database) async throws {
        let rows = try await LegacyRoleBindingStore.bindings(
            principalType: principalType.rawValue, principalID: principalID, on: db)
        try await LegacyRoleBindingStore.delete(ids: rows.map(\.id), on: db)
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
        let bindings = try await LegacyRoleBindingStore.bindings(
            principalType: principalType.rawValue, principalID: principalID, on: db)
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
                try await LegacyRoleBindingStore.delete(ids: [binding.id], on: db)
            }
        }
    }

    /// Remove every binding attached to a node. Called when the node itself is
    /// deleted (bindings have no FK to the resources they protect).
    static func revokeAll(nodeType: IAMNodeType, nodeID: UUID, on db: Database) async throws {
        let rows = try await LegacyRoleBindingStore.bindings(
            nodeType: nodeType.rawValue, nodeID: nodeID, on: db)
        try await LegacyRoleBindingStore.delete(ids: rows.map(\.id), on: db)
    }

    /// Remove every binding attached to any of `nodeIDs`, all of one type —
    /// the form a cascade delete needs, where removing one row takes a set of
    /// child nodes with it (a VM's checkpoints, a sandbox's snapshots, or
    /// every image and volume in an organization).
    static func revokeAll(nodeType: IAMNodeType, nodeIDs: [UUID], on db: Database) async throws {
        for chunk in chunked(nodeIDs) {
            let rows = try await LegacyRoleBindingStore.bindings(
                nodeType: nodeType.rawValue, nodeIDs: Array(chunk), on: db)
            try await LegacyRoleBindingStore.delete(ids: rows.map(\.id), on: db)
        }
    }

    /// Remove every binding held by any of `principalIDs`, all of one type —
    /// the principal-side counterpart, for a delete that takes a set of
    /// principals with it (a project's service accounts, an organization's
    /// groups and registered workloads).
    static func revokeAll(
        principalType: IAMPrincipalType, principalIDs: [UUID], on db: Database
    ) async throws {
        for chunk in chunked(principalIDs) {
            let rows = try await LegacyRoleBindingStore.bindings(
                principalType: principalType.rawValue,
                principalIDs: Array(chunk),
                on: db)
            try await LegacyRoleBindingStore.delete(ids: rows.map(\.id), on: db)
        }
    }

    /// `IN` lists are bounded: Postgres refuses a statement with more than
    /// 65535 bind parameters, and plans a long list poorly well before that.
    /// Container deletes hand these sweeps whole-organization id sets, so the
    /// chunking lives here rather than at each call site.
    private static let deleteChunkSize = 1000

    private static func chunked(_ ids: [UUID]) -> [ArraySlice<UUID>] {
        stride(from: 0, to: ids.count, by: deleteChunkSize).map {
            ids[$0..<min($0 + deleteChunkSize, ids.count)]
        }
    }

    /// The unexpired bindings on a node.
    static func activeBindings(
        nodeType: IAMNodeType, nodeID: UUID, on db: Database
    ) async throws -> [LegacyRoleBindingRecord] {
        try await LegacyRoleBindingStore.bindings(
            nodeType: nodeType.rawValue,
            nodeID: nodeID,
            activeAt: Date(),
            on: db)
    }

    /// The unexpired bindings a principal holds on one node — the question the
    /// member surfaces ask ("does this user already have a role here?"),
    /// answered by the database rather than by loading a node's or a
    /// principal's whole binding set and filtering in Swift.
    static func activeBindings(
        principalType: IAMPrincipalType,
        principalID: UUID,
        nodeType: IAMNodeType,
        nodeID: UUID,
        on db: Database
    ) async throws -> [LegacyRoleBindingRecord] {
        try await LegacyRoleBindingStore.bindings(
            principalType: principalType.rawValue,
            principalID: principalID,
            nodeType: nodeType.rawValue,
            nodeID: nodeID,
            activeAt: Date(),
            on: db)
    }

    /// The unexpired bindings held by a principal.
    static func activeBindings(
        principalType: IAMPrincipalType, principalID: UUID, on db: Database
    ) async throws -> [LegacyRoleBindingRecord] {
        try await LegacyRoleBindingStore.bindings(
            principalType: principalType.rawValue,
            principalID: principalID,
            activeAt: Date(),
            on: db)
    }
}
