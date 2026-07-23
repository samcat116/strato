import Fluent
import Foundation
import Vapor

/// Resolves the `role` string the member endpoints accept onto a concrete
/// role-definition row, across the unified vocabulary (issue #608).
///
/// Three input shapes, tried in order:
///  1. a role **UUID** — an `iam_roles` row id, validated live and in-scope;
///  2. an **IAM role name** (`viewer`/`operator`/`editor`/`admin`) — mapped to
///     the seeded row's fixed id;
///  3. a **legacy relational name** — the project vocabulary (`admin`/`member`/
///     `viewer`), mapped exactly as `IAMRole.fromProjectRole` always has.
///
/// The first two shapes are the general path shared by project and org members;
/// the legacy shape is project-only (org membership keeps its own literal
/// `admin`/`member` semantics, handled by the controller before it reaches the
/// resolver).
enum MemberRoleResolver {
    /// A resolved role: the row id to store, the name to display, and the
    /// action set the guardrail write-check needs.
    struct Resolved: Sendable {
        /// The `iam_roles` row id — what the mirror row and the binding store.
        let id: UUID
        /// The role's display name, for response DTOs.
        let displayName: String
        /// The full expanded action set the role grants.
        let actions: Set<String>
    }

    /// Resolve `raw` against the vocabulary, scoping any non-platform role to
    /// `scopeNode`'s ancestor chain.
    ///
    /// - Parameters:
    ///   - acceptsLegacyProjectRoles: also accept the `admin`/`member`/`viewer`
    ///     project vocabulary. Project members pass `true`; org members `false`.
    static func resolve(
        _ raw: String,
        scopeNode: IAMNode,
        acceptsLegacyProjectRoles: Bool,
        on db: any Database
    ) async throws -> Resolved {
        // A role UUID names a definition row directly — the one shape that can
        // point at a user-created role, so the one shape that needs a scope
        // check.
        if let roleID = UUID(uuidString: raw) {
            guard let role = try await IAMRoleDefinition.find(roleID, on: db) else {
                throw Abort(.badRequest, reason: "No role with id \(roleID) exists.")
            }
            try await requireInScope(role, scopeNode: scopeNode, on: db)
            return Resolved(id: roleID, displayName: role.name, actions: Set(role.actions))
        }

        // An IAM role name is one of the seeded defaults — platform-owned, so
        // bindable everywhere, no scope check needed.
        if let iamRole = IAMRole(rawValue: raw) {
            return resolved(iamRole)
        }

        // The legacy project vocabulary, mapped the way it always has been:
        // `member` → editor, `admin` → admin, `viewer` → viewer.
        if acceptsLegacyProjectRoles, let projectRole = ProjectRole(rawValue: raw) {
            return resolved(IAMRole.fromProjectRole(projectRole))
        }

        let legacyHint = acceptsLegacyProjectRoles ? ", or a legacy project role (admin/member/viewer)" : ""
        throw Abort(
            .badRequest,
            reason:
                "Invalid role '\(raw)': expected a role id, an IAM role name (viewer/operator/editor/admin)\(legacyHint)."
        )
    }

    private static func resolved(_ role: IAMRole) -> Resolved {
        Resolved(id: role.seededID, displayName: role.rawValue, actions: IAMRoleRegistry.actions(for: role))
    }

    /// A non-platform role is bindable only at or below its owner: the owner
    /// node must sit on the target's ancestor chain, or the grant is refused
    /// with the mismatch named (issue #608).
    private static func requireInScope(
        _ role: IAMRoleDefinition, scopeNode: IAMNode, on db: any Database
    ) async throws {
        guard let ownerType = IAMRoleOwnerType(rawValue: role.ownerType) else {
            throw Abort(.internalServerError, reason: "Role row names an unknown owner type '\(role.ownerType)'.")
        }
        // Platform roles apply everywhere; only owned roles are scope-bound.
        guard let ownerNodeType = ownerType.nodeType else { return }
        let ownerNode = IAMNode(type: ownerNodeType, id: role.ownerID)
        let chain = try await IAMResourceTree.ancestors(of: scopeNode, on: db)
        guard chain.contains(ownerNode) else {
            throw Abort(
                .badRequest,
                reason:
                    "Role '\(role.name)' is owned by \(ownerType.rawValue) \(role.ownerID), which is not in the hierarchy of \(scopeNode.type.rawValue) \(scopeNode.id); a role can only be bound at or below its owner."
            )
        }
    }
}

/// Batch-loads role display names for a members listing, translating each
/// stored `role` value — a UUID going forward, a legacy relational name on
/// older rows — into a name the UI can show (issue #608).
///
/// A stored UUID with no surviving row renders as `"(deleted role)"`: a role
/// dropped out from under a binding is a harmless under-grant everywhere else,
/// and here it is simply labelled as gone rather than crashing the list.
struct RoleDisplayNames {
    static let deletedRolePlaceholder = "(deleted role)"

    private let namesByID: [UUID: String]

    private init(namesByID: [UUID: String]) {
        self.namesByID = namesByID
    }

    /// Load names for every role id the stored values reference — directly as a
    /// UUID, or via a legacy project name mapped to its seeded id.
    static func forProjectRoles(_ storedValues: [String], on db: any Database) async throws -> RoleDisplayNames {
        try await load(storedValues.compactMap(projectRoleID(forStored:)), on: db)
    }

    /// Load names for the UUID-valued stored values; legacy org literals
    /// (`admin`/`member`) name no row and are displayed verbatim.
    static func forOrganizationRoles(_ storedValues: [String], on db: any Database) async throws -> RoleDisplayNames {
        try await load(storedValues.compactMap { UUID(uuidString: $0) }, on: db)
    }

    private static func load(_ ids: [UUID], on db: any Database) async throws -> RoleDisplayNames {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return RoleDisplayNames(namesByID: [:]) }
        let rows = try await IAMRoleDefinition.query(on: db)
            .filter(\.$id ~~ unique)
            .all()
        var namesByID: [UUID: String] = [:]
        for row in rows { if let id = row.id { namesByID[id] = row.name } }
        return RoleDisplayNames(namesByID: namesByID)
    }

    /// The canonical role UUID string a stored project value denotes — the
    /// stored UUID as-is, or a legacy name mapped to its seeded id, so the
    /// response's `role` field is always a UUID string (issue #608).
    static func projectRoleID(forStored stored: String) -> UUID? {
        if let uuid = UUID(uuidString: stored) { return uuid }
        if let projectRole = ProjectRole(rawValue: stored) { return IAMRole.fromProjectRole(projectRole).seededID }
        return nil
    }

    /// The display name for a project member's stored role value.
    func projectDisplayName(forStored stored: String) -> String {
        guard let id = Self.projectRoleID(forStored: stored) else { return stored }
        return namesByID[id] ?? Self.deletedRolePlaceholder
    }

    /// The display name for an org member's stored role value: a UUID resolves
    /// to its row name, while a legacy literal (`admin`/`member`) shows as-is.
    func organizationDisplayName(forStored stored: String) -> String {
        guard let id = UUID(uuidString: stored) else { return stored }
        return namesByID[id] ?? Self.deletedRolePlaceholder
    }
}
