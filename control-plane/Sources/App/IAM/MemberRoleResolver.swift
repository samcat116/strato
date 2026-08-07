import Fluent
import Foundation
import Vapor

/// Resolves the `role` string the member endpoints accept onto a concrete
/// role-definition row, across the unified vocabulary (issue #608).
///
/// Four input shapes, tried in order:
///  1. a role **UUID** — an `iam_roles` row id, validated live and in-scope;
///  2. an **IAM role name** (`viewer`/`operator`/`editor`/`admin`) — mapped to
///     the seeded row's fixed id;
///  3. a **legacy relational name** — the project vocabulary (`admin`/`member`/
///     `viewer`), mapped exactly as `IAMRole.fromProjectRole` always has;
///  4. a **custom role's name**, resolved in the scope `GET /api/iam/roles/
///     bindable` publishes it in (STR-111).
///
/// The fixed vocabulary is tried before the custom names on purpose: `viewer`
/// and `member` mean what they have always meant, whatever a deployment names
/// its own roles (names are unique per owner, so an org may well define a
/// `viewer` of its own — reachable by id).
///
/// Shapes 1, 2 and 4 are the general path shared by project, folder and org
/// members; the legacy shape is project-only (org membership keeps its own
/// literal `admin`/`member` semantics, handled by the controller before it
/// reaches the resolver).
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

        // A custom role's name, scoped exactly the way `bindable` scopes it —
        // the listing offers names, so the write path takes the names it
        // offers (STR-111).
        if let role = try await resolveBindableName(raw, scopeNode: scopeNode, on: db) {
            return role
        }

        let legacyHint = acceptsLegacyProjectRoles ? ", a legacy project role (admin/member/viewer)," : ""
        throw Abort(
            .badRequest,
            reason:
                "Invalid role '\(raw)': expected a role id, an IAM role name (viewer/operator/editor/admin)\(legacyHint) or the name of a role bindable on this \(scopeNode.type.rawValue)."
        )
    }

    /// Resolve a name against the roles bindable at `scopeNode` — the same set
    /// `GET /api/iam/roles/bindable` answers with. Nil when no bindable role
    /// carries the name; a name carried by two of them is refused outright.
    ///
    /// Ambiguity is possible because names are unique per owner, not globally:
    /// an org and a project beneath it can each define `deployer`. Picking one
    /// would grant access the caller never chose, so both ids are named and
    /// the caller re-sends the one it meant.
    private static func resolveBindableName(
        _ raw: String, scopeNode: IAMNode, on db: any Database
    ) async throws -> Resolved? {
        let chain = try await IAMResourceTree.ancestors(of: scopeNode, on: db)
        let matches = try await RoleStore.bindable(named: raw, along: chain, on: db)
        guard let first = matches.first else { return nil }
        guard matches.count == 1 else {
            let candidates =
                matches
                .compactMap { role in role.id.map { "\($0) (owned by \(role.ownerType) \(role.ownerID))" } }
                .sorted()
                .joined(separator: ", ")
            throw Abort(
                .badRequest,
                reason:
                    "Role name '\(raw)' is ambiguous on this \(scopeNode.type.rawValue): it names \(matches.count) bindable roles — \(candidates). Grant by role id instead."
            )
        }
        return Resolved(id: try first.requireID(), displayName: first.name, actions: Set(first.actions))
    }

    private static func resolved(_ role: IAMRole) -> Resolved {
        Resolved(id: role.seededID, displayName: role.rawValue, actions: IAMRoleRegistry.actions(for: role))
    }

    // MARK: - Organization membership roles (issue #608/#611)

    /// An organization membership role resolved for storage and binding.
    struct ResolvedOrgRole: Sendable {
        /// What `UserOrganization.role` stores: a legacy literal, or a role id.
        let storedRole: String
        /// The role id to bind on the org node, or nil for bare membership.
        let bindingRoleID: UUID?
        /// The role's action set, for the guardrail write-check.
        let actions: Set<String>
        /// A human-readable label for logs and refusals.
        let label: String
    }

    /// Resolve a requested org membership role across the unified vocabulary —
    /// the shared path for the org member endpoints (issue #608) and the OIDC
    /// provisioning flow (issue #611).
    ///
    /// Legacy `admin`/`member` keep their literal semantics: stored verbatim,
    /// `admin` carrying the admin binding and `member` none, so the last-admin
    /// guards continue to key on the literal. Everything else — an IAM role
    /// name, or an org-owned role by id or by name — resolves through
    /// `resolve`, scoped to the org, and stores the role id.
    ///
    /// The seeded admin role — reachable by IAM name or by its well-known id —
    /// *is* the org-admin membership under another name, so it is stored as the
    /// literal `"admin"`; otherwise an admin granted by id would be invisible to
    /// the last-admin guards, which key on that literal (issue #608 review).
    static func resolveOrganizationRole(
        _ raw: String, organizationID: UUID, on db: any Database
    ) async throws -> ResolvedOrgRole {
        if raw == "admin" || raw == "member" {
            let iamRole = IAMRole.fromOrganizationRole(raw)
            return ResolvedOrgRole(
                storedRole: raw,
                bindingRoleID: iamRole?.seededID,
                actions: iamRole.map { IAMRoleRegistry.actions(for: $0) } ?? [],
                label: raw
            )
        }
        let resolved = try await resolve(
            raw,
            scopeNode: IAMNode(type: .organization, id: organizationID),
            acceptsLegacyProjectRoles: false,
            on: db
        )
        let storedRole = resolved.id == IAMRole.admin.seededID ? "admin" : resolved.id.uuidString
        return ResolvedOrgRole(
            storedRole: storedRole,
            bindingRoleID: resolved.id,
            actions: resolved.actions,
            label: resolved.displayName
        )
    }

    /// The role id a stored membership value names, for revoking its binding:
    /// a UUID directly, or a legacy literal via `fromOrganizationRole`
    /// (`member` names none).
    static func organizationStoredRoleID(_ stored: String) -> UUID? {
        if let uuid = UUID(uuidString: stored) { return uuid }
        return IAMRole.fromOrganizationRole(stored)?.seededID
    }

    /// A non-platform role is bindable only at or below its owner: the owner
    /// node must sit on the target's ancestor chain, or the grant is refused
    /// with the mismatch named (issue #608).
    ///
    /// Decided by `IAMRoleOwnerType.ownerIDs(along:)`, the same predicate
    /// `RoleStore.bindable` filters the listing with — so a role granted by id
    /// here is exactly a role the picker offers, and a new owner type cannot
    /// be accepted by one path while the other silently drops it (STR-111
    /// review).
    private static func requireInScope(
        _ role: IAMRoleDefinition, scopeNode: IAMNode, on db: any Database
    ) async throws {
        guard let ownerType = IAMRoleOwnerType(rawValue: role.ownerType) else {
            throw Abort(.internalServerError, reason: "Role row names an unknown owner type '\(role.ownerType)'.")
        }
        let chain = try await IAMResourceTree.ancestors(of: scopeNode, on: db)
        // Platform roles apply everywhere; only owned roles are scope-bound.
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

    /// Load names for role ids held directly, with no stored-value decoding in
    /// between — the shape of a surface backed by `role_bindings` alone, whose
    /// `role` column has always been a role id (folder grants, STR-109).
    static func forRoleIDs(_ ids: [UUID], on db: any Database) async throws -> RoleDisplayNames {
        try await load(ids, on: db)
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

    /// The display name for a role id; an id naming no surviving row renders as
    /// `"(deleted role)"`, same as everywhere else.
    func displayName(forRoleID id: UUID) -> String {
        namesByID[id] ?? Self.deletedRolePlaceholder
    }

    /// The display name for an org member's stored role value: a UUID resolves
    /// to its row name, while a legacy literal (`admin`/`member`) shows as-is.
    func organizationDisplayName(forStored stored: String) -> String {
        guard let id = UUID(uuidString: stored) else { return stored }
        return namesByID[id] ?? Self.deletedRolePlaceholder
    }
}
