import Fluent
import Foundation
import Vapor

/// Why a principal holds an action. Not every grant is a role binding, so an
/// answer that only read `role_bindings` would under-report.
enum WhoCanSource: String, Content, Sendable {
    /// A row in `role_bindings`, on the resource or anywhere above it.
    case binding
    /// Bare org membership, which grants `org:read` + `project:create` with no
    /// binding behind it (see `IAMRoleRegistry.membershipDerivedActions`).
    case orgMembership
    /// A system administrator, who bypasses authorization entirely. Re-expressed
    /// as a tier-1 platform policy at cutover (#482); until then it is a
    /// separate source rather than a binding.
    case systemAdmin
}

/// A principal reference — the subject of a binding, or the group a user
/// inherited one through.
struct WhoCanPrincipalRef: Content, Hashable, Sendable {
    let type: IAMPrincipalType
    let id: UUID
}

/// One reason one principal can perform the queried action. A principal may
/// appear more than once — two groups granting the same role, or a direct
/// binding alongside an inherited one — because each entry explains a distinct
/// grant, and revoking access means revoking all of them.
struct WhoCanEntry: Content, Hashable, Sendable {
    let principal: WhoCanPrincipalRef
    let source: WhoCanSource
    /// The role that carries the action; nil for non-binding sources.
    let role: String?
    /// The tree node the binding is attached to — the resource itself when the
    /// grant is direct, an ancestor when it is inherited.
    let grantedOn: IAMNode?
    /// The group this user inherited the binding through; nil when the binding
    /// names the user directly.
    let via: WhoCanPrincipalRef?
    let expiresAt: Date?
}

/// The reverse index: "who can do action A on resource R?" (issue #478).
///
/// Answered from `role_bindings` plus the resource tree — an ancestor walk and
/// a group expansion — and never from the policy engine. A reverse query
/// against a policy evaluator means enumerating every principal and checking
/// each; against tables we own it is a bounded set of indexed reads. This is
/// the property the one-parent invariant buys (docs/architecture/iam.md).
///
/// **Cross-org principals are in scope by design.** Bindings may name a
/// principal from another org, so nothing here filters principals by the
/// resource's organization — doing so would silently hide exactly the external
/// access that most needs to be visible.
///
/// SpiceDB remains authoritative for enforcement during phase 1, so these
/// answers describe the bindings model, which is being dual-written to match.
enum WhoCanService {

    // MARK: - Reverse lookup

    /// Every principal that can perform `action` on `node`, with the reason.
    static func whoCan(action: String, node: IAMNode, on db: any Database) async throws -> [WhoCanEntry] {
        let chain = try await IAMResourceTree.ancestors(of: node, on: db)
        var entries: [WhoCanEntry] = []

        entries += try await bindingEntries(action: action, chain: chain, on: db)
        entries += try await membershipEntries(action: action, chain: chain, on: db)
        entries += try await systemAdminEntries(on: db)

        return dedupedAndSorted(entries)
    }

    /// Bindings along the chain whose role carries the action, plus the users
    /// each group binding expands to.
    private static func bindingEntries(
        action: String, chain: [IAMNode], on db: any Database
    ) async throws -> [WhoCanEntry] {
        let grantingRoles = IAMRoleRegistry.roles(granting: action)
        guard !grantingRoles.isEmpty, !chain.isEmpty else { return [] }

        let bindings = try await RoleBinding.query(on: db)
            .filter(\.$role ~~ grantingRoles.map(\.rawValue))
            .group(.or) { anyNode in
                for node in chain {
                    anyNode.group(.and) { thisNode in
                        thisNode.filter(\.$nodeType == node.type.rawValue)
                        thisNode.filter(\.$nodeID == node.id)
                    }
                }
            }
            .active()
            .all()
        guard !bindings.isEmpty else { return [] }

        var entries: [WhoCanEntry] = []
        for binding in bindings {
            guard
                let principalType = IAMPrincipalType(rawValue: binding.principalType),
                let nodeType = IAMNodeType(rawValue: binding.nodeType)
            else { continue }
            entries.append(
                WhoCanEntry(
                    principal: WhoCanPrincipalRef(type: principalType, id: binding.principalID),
                    source: .binding,
                    role: binding.role,
                    grantedOn: IAMNode(type: nodeType, id: binding.nodeID),
                    via: nil,
                    expiresAt: binding.expiresAt
                )
            )
        }

        // Expand group bindings to their members. Groups are flat (`user_groups`
        // has no group-in-group edge), so one pass fully resolves them; nested
        // groups would need this to iterate to a fixed point.
        let groupBindings = bindings.filter { $0.principalType == IAMPrincipalType.group.rawValue }
        guard !groupBindings.isEmpty else { return entries }

        let memberships = try await UserGroup.query(on: db)
            .filter(\.$group.$id ~~ Array(Set(groupBindings.map(\.principalID))))
            .all()
        let membersByGroup = Dictionary(grouping: memberships, by: { $0.$group.id })

        for binding in groupBindings {
            guard let nodeType = IAMNodeType(rawValue: binding.nodeType) else { continue }
            let group = WhoCanPrincipalRef(type: .group, id: binding.principalID)
            for membership in membersByGroup[binding.principalID] ?? [] {
                entries.append(
                    WhoCanEntry(
                        principal: WhoCanPrincipalRef(type: .user, id: membership.$user.id),
                        source: .binding,
                        role: binding.role,
                        grantedOn: IAMNode(type: nodeType, id: binding.nodeID),
                        via: group,
                        expiresAt: binding.expiresAt
                    )
                )
            }
        }
        return entries
    }

    /// Org members, for the two actions membership grants directly.
    private static func membershipEntries(
        action: String, chain: [IAMNode], on db: any Database
    ) async throws -> [WhoCanEntry] {
        guard IAMRoleRegistry.membershipDerivedActions.contains(action),
            let orgNode = chain.first(where: { $0.type == .organization })
        else { return [] }

        let members = try await UserOrganization.query(on: db)
            .filter(\.$organization.$id == orgNode.id)
            .all()
        return members.map { membership in
            WhoCanEntry(
                principal: WhoCanPrincipalRef(type: .user, id: membership.$user.id),
                source: .orgMembership,
                role: nil,
                grantedOn: orgNode,
                via: nil,
                expiresAt: nil
            )
        }
    }

    /// System admins can perform any action on any resource.
    private static func systemAdminEntries(on db: any Database) async throws -> [WhoCanEntry] {
        let admins = try await User.query(on: db).filter(\.$isSystemAdmin == true).all()
        return admins.compactMap { admin in
            guard let id = admin.id else { return nil }
            return WhoCanEntry(
                principal: WhoCanPrincipalRef(type: .user, id: id),
                source: .systemAdmin,
                role: nil,
                grantedOn: nil,
                via: nil,
                expiresAt: nil
            )
        }
    }

    /// Stable ordering so callers (and tests) see a deterministic list.
    private static func dedupedAndSorted(_ entries: [WhoCanEntry]) -> [WhoCanEntry] {
        var seen: Set<WhoCanEntry> = []
        let unique = entries.filter { seen.insert($0).inserted }
        return unique.sorted { lhs, rhs in
            if lhs.source != rhs.source { return lhs.source.sortOrder < rhs.source.sortOrder }
            if lhs.principal.type != rhs.principal.type {
                return lhs.principal.type.rawValue < rhs.principal.type.rawValue
            }
            if lhs.principal.id != rhs.principal.id {
                return lhs.principal.id.uuidString < rhs.principal.id.uuidString
            }
            if lhs.role != rhs.role { return (lhs.role ?? "") < (rhs.role ?? "") }
            return (lhs.via?.id.uuidString ?? "") < (rhs.via?.id.uuidString ?? "")
        }
    }

    // MARK: - Forward check

    /// Whether one principal can perform `action` on `node`, answered from the
    /// same bindings + tree the reverse lookup uses.
    ///
    /// This is the arbitrary-principal form of `can-i`. It deliberately does
    /// *not* consult SpiceDB: it reports what the bindings model says, which is
    /// what will enforce after cutover (#482). Until then the caller-scoped
    /// path in `AuthorizationController.check` stays on SpiceDB, because that
    /// is what actually gates requests today.
    static func can(
        principalType: IAMPrincipalType, principalID: UUID, action: String, node: IAMNode, on db: any Database
    ) async throws -> Bool {
        if principalType == .user, let user = try await User.find(principalID, on: db), user.isSystemAdmin {
            return true
        }

        let chain = try await IAMResourceTree.ancestors(of: node, on: db)
        guard !chain.isEmpty else { return false }

        // The principal itself, plus (for a user) every group it belongs to.
        var principals: [(IAMPrincipalType, UUID)] = [(principalType, principalID)]
        if principalType == .user {
            let groupIDs = try await UserGroup.query(on: db)
                .filter(\.$user.$id == principalID)
                .all()
                .map { $0.$group.id }
            principals += groupIDs.map { (.group, $0) }
        }

        let grantingRoles = IAMRoleRegistry.roles(granting: action)
        if !grantingRoles.isEmpty {
            let matches = try await RoleBinding.query(on: db)
                .filter(\.$role ~~ grantingRoles.map(\.rawValue))
                .group(.or) { anyPrincipal in
                    for (type, id) in principals {
                        anyPrincipal.group(.and) { thisPrincipal in
                            thisPrincipal.filter(\.$principalType == type.rawValue)
                            thisPrincipal.filter(\.$principalID == id)
                        }
                    }
                }
                .group(.or) { anyNode in
                    for node in chain {
                        anyNode.group(.and) { thisNode in
                            thisNode.filter(\.$nodeType == node.type.rawValue)
                            thisNode.filter(\.$nodeID == node.id)
                        }
                    }
                }
                .active()
                .count()
            if matches > 0 { return true }
        }

        if principalType == .user, IAMRoleRegistry.membershipDerivedActions.contains(action),
            let orgNode = chain.first(where: { $0.type == .organization })
        {
            let memberships = try await UserOrganization.query(on: db)
                .filter(\.$user.$id == principalID)
                .filter(\.$organization.$id == orgNode.id)
                .count()
            if memberships > 0 { return true }
        }

        return false
    }
}

extension WhoCanSource {
    /// Bindings first — they are the actionable, revocable grants; the blanket
    /// sources are context.
    fileprivate var sortOrder: Int {
        switch self {
        case .binding: return 0
        case .orgMembership: return 1
        case .systemAdmin: return 2
        }
    }
}
