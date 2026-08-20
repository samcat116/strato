import ControlPlanePostgres
import Fluent
import Foundation
import Vapor

/// Validates a canonical role id for a membership grant.
///
/// Role names and the retired project/organization literals are deliberately
/// not accepted. Grant clients choose an id from `GET /api/iam/roles/bindable`,
/// and the UUID-typed request and storage columns keep that identity exact from
/// the API boundary through policy evaluation.
enum MemberRoleResolver {
    struct Resolved: Sendable {
        let id: UUID
        let displayName: String
        let actions: Set<String>
    }

    static func resolve(
        _ roleID: UUID,
        scopeNode: IAMNode,
        using iam: IAMPersistence
    ) async throws -> Resolved {
        guard let role = try await iam.role(id: roleID) else {
            throw Abort(.badRequest, reason: "No role with id \(roleID) exists.")
        }
        try await requireInScope(role, scopeNode: scopeNode, using: iam)
        return Resolved(id: roleID, displayName: role.name, actions: Set(role.actions))
    }

    private static func requireInScope(
        _ role: IAMRoleSnapshot,
        scopeNode: IAMNode,
        using iam: IAMPersistence
    ) async throws {
        guard let ownerType = IAMRoleOwnerType(rawValue: role.ownerType) else {
            throw Abort(
                .internalServerError,
                reason: "Role row names an unknown owner type '\(role.ownerType)'."
            )
        }
        guard ownerType != .platform else { return }
        let chain = try await IAMResourceTree.ancestors(of: scopeNode, using: iam)
        guard let ownerIDs = ownerType.ownerIDs(along: chain) else { return }
        guard ownerIDs.contains(role.ownerID) else {
            throw Abort(
                .badRequest,
                reason:
                    "Role '\(role.name)' is owned by \(ownerType.rawValue) \(role.ownerID), which is not in the hierarchy of \(scopeNode.type.rawValue) \(scopeNode.id); a role can only be bound at or below its owner."
            )
        }
    }

    static func resolve(
        _ roleID: UUID,
        scopeNode: IAMNode,
        on db: any Database
    ) async throws -> Resolved {
        guard let role = try await RoleStore.legacyRole(id: roleID, on: db) else {
            throw Abort(.badRequest, reason: "No role with id \(roleID) exists.")
        }
        try await requireInScope(role, scopeNode: scopeNode, on: db)
        return Resolved(id: roleID, displayName: role.name, actions: Set(role.actions))
    }

    /// A non-platform role is bindable only at or below its owner.
    private static func requireInScope(
        _ role: LegacyIAMRoleRecord, scopeNode: IAMNode, on db: any Database
    ) async throws {
        guard let ownerType = IAMRoleOwnerType(rawValue: role.ownerType) else {
            throw Abort(
                .internalServerError,
                reason: "Role row names an unknown owner type '\(role.ownerType)'.")
        }
        guard ownerType != .platform else { return }
        let chain = try await IAMResourceTree.ancestors(of: scopeNode, on: db)
        guard let ownerIDs = ownerType.ownerIDs(along: chain) else { return }
        guard ownerIDs.contains(role.ownerID) else {
            throw Abort(
                .badRequest,
                reason:
                    "Role '\(role.name)' is owned by \(ownerType.rawValue) \(role.ownerID), which is not in the hierarchy of \(scopeNode.type.rawValue) \(scopeNode.id); a role can only be bound at or below its owner."
            )
        }
    }
}

/// Batch-loaded role display names for grant listings.
struct RoleDisplayNames {
    static let deletedRolePlaceholder = "(deleted role)"

    private let namesByID: [UUID: String]

    private init(namesByID: [UUID: String]) {
        self.namesByID = namesByID
    }

    static func forRoleIDs(
        _ ids: [UUID],
        using iam: IAMPersistence
    ) async throws -> RoleDisplayNames {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return RoleDisplayNames(namesByID: [:]) }
        let rows = try await iam.roles(ids: unique)
        return RoleDisplayNames(
            namesByID: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.name) })
        )
    }

    static func forRoleIDs(_ ids: [UUID], on db: any Database) async throws -> RoleDisplayNames {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return RoleDisplayNames(namesByID: [:]) }
        let rows = try await RoleStore.legacyRoles(ids: unique, on: db)
        var namesByID: [UUID: String] = [:]
        for row in rows {
            namesByID[row.id] = row.name
        }
        return RoleDisplayNames(namesByID: namesByID)
    }

    func displayName(forRoleID id: UUID) -> String {
        namesByID[id] ?? Self.deletedRolePlaceholder
    }
}
