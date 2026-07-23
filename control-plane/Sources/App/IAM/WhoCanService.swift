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
    /// The grant is real but its holder's account is disabled, so they cannot
    /// currently act on it (`can()` returns false for them).
    ///
    /// Marked rather than filtered out: "who can reach this?" and "whose
    /// grants are still sitting here?" are both things this endpoint is asked,
    /// and dropping the row would make an un-revoked grant on a departed
    /// employee invisible to exactly the audit meant to catch it.
    let principalDisabled: Bool
    /// The principal lives outside the resource's organization: a user with
    /// no membership there, or a group owned by another org. Cross-org access
    /// is exactly what most needs to be visible (issue #485), so it is marked
    /// here the same way it is in the members lists — reported, never
    /// filtered.
    let principalExternalToOrg: Bool
    /// The grant is real but a ceiling (a guardrail or authored forbid) denies
    /// it: this principal cannot actually perform the action here, and the
    /// enforcer would agree (`can()` returns false for them). Marked rather than
    /// filtered, like `principalDisabled` — a grant that a ceiling neutralises
    /// is exactly what an admin auditing "who can reach this?" needs to see,
    /// alongside "whose grant is now dead weight?" (#610).
    let ceilinged: Bool
    /// The ceiling policy ids that deny this grant (`guardrail-<id>` /
    /// `policy-<id>`), when `ceilinged`. Nil otherwise.
    let ceilingPolicyIDs: [String]?

    init(
        principal: WhoCanPrincipalRef,
        source: WhoCanSource,
        role: String?,
        grantedOn: IAMNode?,
        via: WhoCanPrincipalRef?,
        expiresAt: Date?,
        principalDisabled: Bool = false,
        principalExternalToOrg: Bool = false,
        ceilinged: Bool = false,
        ceilingPolicyIDs: [String]? = nil
    ) {
        self.principal = principal
        self.source = source
        self.role = role
        self.grantedOn = grantedOn
        self.via = via
        self.expiresAt = expiresAt
        self.principalDisabled = principalDisabled
        self.principalExternalToOrg = principalExternalToOrg
        self.ceilinged = ceilinged
        self.ceilingPolicyIDs = ceilingPolicyIDs
    }

    fileprivate func markingPrincipalDisabled() -> WhoCanEntry {
        WhoCanEntry(
            principal: principal, source: source, role: role, grantedOn: grantedOn,
            via: via, expiresAt: expiresAt, principalDisabled: true,
            principalExternalToOrg: principalExternalToOrg,
            ceilinged: ceilinged, ceilingPolicyIDs: ceilingPolicyIDs)
    }

    fileprivate func markingPrincipalExternal() -> WhoCanEntry {
        WhoCanEntry(
            principal: principal, source: source, role: role, grantedOn: grantedOn,
            via: via, expiresAt: expiresAt, principalDisabled: principalDisabled,
            principalExternalToOrg: true,
            ceilinged: ceilinged, ceilingPolicyIDs: ceilingPolicyIDs)
    }

    fileprivate func markingCeilinged(_ policyIDs: [String]) -> WhoCanEntry {
        WhoCanEntry(
            principal: principal, source: source, role: role, grantedOn: grantedOn,
            via: via, expiresAt: expiresAt, principalDisabled: principalDisabled,
            principalExternalToOrg: principalExternalToOrg,
            ceilinged: true, ceilingPolicyIDs: policyIDs)
    }
}

/// A ceiling (a guardrail or an authored forbid policy) in force at the queried
/// node — the "what constrains this resource" half of a who-can answer (#610).
struct WhoCanCeiling: Content, Hashable, Sendable {
    enum Kind: String, Content, Sendable {
        case guardrail
        case policy
    }
    let kind: Kind
    let id: UUID
    let name: String
    /// The container the ceiling hangs on (guardrails) or the owner (policies).
    let node: IAMNode
}

/// Whether an authored policy's action scope covers the queried action, as far
/// as its text can be read.
enum WhoCanPolicyActionMatch: String, Content, Sendable {
    /// The action is in the policy's scope (`action`, or an explicit list that
    /// contains it).
    case matches
    /// The scope cannot be enumerated from the text (an action-group
    /// reference), so the policy might or might not cover the action.
    case unknown
}

/// An authored policy (issue #606) that may bear on the queried action and
/// resource. Best-effort: which principals it actually permits or forbids —
/// and any `when`/`unless` conditions — cannot be enumerated from a reverse
/// lookup, which is why the whole `WhoCanResult.principals` list carries a
/// caveat whenever any of these are present.
struct WhoCanPolicyMatch: Content, Hashable, Sendable {
    let policyID: UUID
    let name: String
    let effect: IAMPolicyEffect
    /// The org or project that owns the policy.
    let owner: IAMNode
    let actionMatch: WhoCanPolicyActionMatch
}

/// The answer to a reverse lookup.
///
/// Not a bare list, because a list cannot express "everyone" — see
/// `openToAllAuthenticatedUsers` — nor the reach of authored policies, whose
/// principals a reverse lookup cannot enumerate (`authoredPolicyCaveat`).
/// Bundling the caveats with the list makes them impossible to read past.
struct WhoCanResult: Content, Sendable {
    let principals: [WhoCanEntry]
    /// When true, the action needs no grant on this resource at all: every
    /// authenticated user can perform it, so `principals` is *not* the whole
    /// answer.
    ///
    /// Reported as a flag rather than by enumerating every user, which would
    /// be unbounded and would go stale at the next signup.
    let openToAllAuthenticatedUsers: Bool
    /// Authored **permit** policies in force on this resource that may bear on
    /// the action (issue #606) — best-effort, matched on action scope and
    /// containment. Authored *forbids* are not here: they are reflected exactly
    /// in `ceilings` and per-entry `ceilinged` (#610), so only the permits —
    /// which *widen* access to principals a reverse lookup cannot enumerate —
    /// remain a caveat.
    let authoredPolicies: [WhoCanPolicyMatch]
    /// When true, at least one authored **permit** policy above bears on this
    /// query and its principals cannot be enumerated here, so `principals` is
    /// not the whole answer — someone the list does not name may also be able
    /// to act.
    let authoredPolicyCaveat: Bool
    /// The ceilings in force on this resource: guardrails inherited down the
    /// tree plus authored forbid policies scoped to it (#610). Which grants each
    /// one actually neutralises is on the entries themselves (`ceilinged`); this
    /// is the "what constrains this resource" summary.
    let ceilings: [WhoCanCeiling]
}

/// The reverse index: "who can do action A on resource R?" (issue #478).
///
/// The *candidates* are enumerated from `role_bindings` plus the resource tree
/// — an ancestor walk and a group expansion. A reverse query against a policy
/// evaluator means enumerating every principal and checking each; against
/// tables we own it is a bounded set of indexed reads. This is the property
/// the one-parent invariant buys (docs/architecture/iam.md). What each
/// candidate can *actually do* is then decided by `IAMDecisionEngine` — the
/// same evaluator that gates requests — so the enumeration explains grants and
/// the engine has the last word (the `ceilinged` marks, and every
/// `WhoCanService.can` verdict).
///
/// **Cross-org principals are in scope by design.** Bindings may name a
/// principal from another org, so nothing here filters principals by the
/// resource's organization — doing so would silently hide exactly the external
/// access that most needs to be visible.
enum WhoCanService {

    // MARK: - Reverse lookup

    /// Every principal that can perform `action` on `node`, with the reason.
    ///
    /// Requires the compiled policy set (it is what the ceiling marks are
    /// decided against) and fails closed with the same 503 enforcement gives
    /// when the replica has none — a who-can that silently degraded to a
    /// weaker model would drift from what enforcement does.
    static func whoCan(
        action: String, node: IAMNode, app: Application, on db: any Database
    ) async throws -> WhoCanResult {
        let built = try await IAMDecisionEngine.compiledSet(app)
        let chain = try await IAMResourceTree.ancestors(of: node, on: db)
        var entries: [WhoCanEntry] = []

        entries += try await bindingEntries(action: action, chain: chain, on: db)
        entries += try await membershipEntries(action: action, chain: chain, on: db)
        entries += try await systemAdminEntries(on: db)

        var principals = try await markingDisabledPrincipals(dedupedAndSorted(entries), on: db)
        principals = try await markingExternalPrincipals(principals, chain: chain, on: db)
        principals = try await markingCeilingedPrincipals(
            principals, action: action, node: node, built: built, on: db)

        // Only authored *permits* are a caveat now — they widen access to
        // principals a reverse lookup cannot enumerate. Authored forbids are
        // reflected exactly in `ceilings` and per-entry `ceilinged`.
        let authoredPermits = try await authoredPolicyMatches(
            action: action, chain: chain, effect: .permit, on: db)
        let ceilings = try await ceilingsInForce(action: action, chain: chain, on: db)

        return WhoCanResult(
            principals: principals,
            openToAllAuthenticatedUsers: try await isOpenToAllAuthenticatedUsers(
                action: action, node: node, on: db),
            authoredPolicies: authoredPermits,
            authoredPolicyCaveat: !authoredPermits.isEmpty,
            ceilings: ceilings
        )
    }

    /// Flag entries a ceiling denies, so the list agrees with the enforcer:
    /// a granted principal a guardrail or authored forbid neutralises is marked
    /// rather than dropped (#610). Decided by `IAMDecisionEngine` — exact for
    /// every ceiling kind (matcher and authored guardrails, authored forbid
    /// policies), because it *is* the enforcement decision.
    ///
    /// Group entries are left alone — a group is not a request principal, and
    /// its members' own entries carry whether a ceiling reaches them. A
    /// truncated-chain denial marks the entry ceilinged with an empty id list
    /// (the structural fail-closed names no policy).
    private static func markingCeilingedPrincipals(
        _ entries: [WhoCanEntry], action: String, node: IAMNode,
        built: CedarPolicySetCache.Built, on db: any Database
    ) async throws -> [WhoCanEntry] {
        var result: [WhoCanEntry] = []
        result.reserveCapacity(entries.count)
        for entry in entries {
            guard
                let principal = IAMPrincipal.requestPrincipal(
                    type: entry.principal.type, id: entry.principal.id)
            else {
                result.append(entry)
                continue
            }
            let decision = try await IAMDecisionEngine.decide(
                principal: principal, action: action, node: node, built: built, on: db)
            if let ceilingIDs = decision.denyingCeilingIDs {
                result.append(entry.markingCeilinged(ceilingIDs))
            } else {
                result.append(entry)
            }
        }
        return result
    }

    /// The ceilings in force at the queried node: guardrails inherited down the
    /// tree whose actions cover `action`, plus authored forbid policies scoped
    /// to the resource (#610).
    private static func ceilingsInForce(
        action: String, chain: [IAMNode], on db: any Database
    ) async throws -> [WhoCanCeiling] {
        var ceilings: [WhoCanCeiling] = []

        for guardrail in try await GuardrailStore.effective(along: chain, on: db) {
            guard let id = guardrail.id, let node = guardrail.node else { continue }
            // A matcher row is filtered by its action patterns; an authored row
            // carries free-form Cedar whose action scope is not structurally
            // enumerable here, so it is always listed as in force.
            if !guardrail.authored, !GuardrailActions.matches(guardrail.actions, action: action) {
                continue
            }
            ceilings.append(WhoCanCeiling(kind: .guardrail, id: id, name: guardrail.name, node: node))
        }

        for match in try await authoredPolicyMatches(
            action: action, chain: chain, effect: .forbid, on: db)
        {
            ceilings.append(
                WhoCanCeiling(kind: .policy, id: match.policyID, name: match.name, node: match.owner))
        }

        return ceilings.sorted {
            ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name)
        }
    }

    /// The authored policies in force on the queried node that may bear on the
    /// action (issue #606).
    ///
    /// Best-effort by construction, and honestly so: a policy is included when
    /// its resource scope is on the queried node's ancestor chain (so it
    /// reaches this resource) *and* its action scope could cover the action.
    /// Neither its principal scope nor its `when`/`unless` conditions are read
    /// — those are exactly what a reverse lookup cannot invert, and what the
    /// caveat flag warns about. Formal enumeration waits on #484.
    private static func authoredPolicyMatches(
        action: String, chain: [IAMNode], effect wanted: IAMPolicyEffect, on db: any Database
    ) async throws -> [WhoCanPolicyMatch] {
        let inScope = try await PolicyStore.inScope(along: chain, on: db)
        guard !inScope.isEmpty else { return [] }
        let chainNodes = Set(chain)

        var matches: [WhoCanPolicyMatch] = []
        for policy in inScope {
            guard let id = policy.id, let owner = policy.owner, let effect = policy.policyEffect,
                let ownerNodeType = owner.nodeType
            else { continue }
            guard effect == wanted else { continue }
            guard
                let shape = try? CedarAuthoredPolicyInspector.describe(
                    cedarText: policy.cedarText, policyID: PolicyDescriptor.policyID(id))
            else { continue }

            // Containment-node-on-chain: the resource the policy is scoped to
            // has to sit on this node's chain, or the policy governs a
            // different subtree and does not bear on this resource.
            guard let scope = shape.resourceScope, let scopeNodeType = scope.type.nodeType,
                chainNodes.contains(IAMNode(type: scopeNodeType, id: scope.id))
            else { continue }

            guard shape.actionScope.couldMatch(action) else { continue }

            matches.append(
                WhoCanPolicyMatch(
                    policyID: id,
                    name: policy.name,
                    effect: effect,
                    owner: IAMNode(type: ownerNodeType, id: policy.ownerID),
                    actionMatch: shape.actionScope == .unknown ? .unknown : .matches
                ))
        }
        return matches.sorted { $0.name < $1.name }
    }

    /// Flag entries whose holder lives outside the chain's organization —
    /// cross-org grants are deliberately loud everywhere they surface
    /// (issue #485). No org in the chain means nothing to be external to.
    private static func markingExternalPrincipals(
        _ entries: [WhoCanEntry], chain: [IAMNode], on db: any Database
    ) async throws -> [WhoCanEntry] {
        guard let root = chain.last, root.type == .organization else { return entries }
        let orgID = root.id

        let userIDs = Set(entries.filter { $0.principal.type == .user }.map(\.principal.id))
        var internalUsers: Set<UUID> = []
        if !userIDs.isEmpty {
            internalUsers = Set(
                try await UserOrganization.query(on: db)
                    .filter(\.$organization.$id == orgID)
                    .filter(\.$user.$id ~~ Array(userIDs))
                    .all()
                    .map { $0.$user.id }
            )
        }

        let groupIDs = Set(entries.filter { $0.principal.type == .group }.map(\.principal.id))
        var internalGroups: Set<UUID> = []
        if !groupIDs.isEmpty {
            internalGroups = Set(
                try await Group.query(on: db)
                    .filter(\.$id ~~ Array(groupIDs))
                    .filter(\.$organization.$id == orgID)
                    .all()
                    .compactMap(\.id)
            )
        }

        // Machine principals (issue #491): a service account is internal when
        // its project's chain reaches this org; a registered workload when
        // its registration row is scoped to it. Same rules as the write-time
        // gate (`CrossOrgBindingGate.isExternal`).
        var internalMachines: Set<UUID> = []
        for entry in entries where entry.principal.type == .serviceAccount || entry.principal.type == .workload {
            let external = try await CrossOrgBindingGate.isExternal(
                principalType: entry.principal.type, principalID: entry.principal.id,
                organizationID: orgID, on: db)
            if !external { internalMachines.insert(entry.principal.id) }
        }

        return entries.map { entry in
            let isInternal =
                switch entry.principal.type {
                case .user: internalUsers.contains(entry.principal.id)
                case .group: internalGroups.contains(entry.principal.id)
                case .serviceAccount, .workload: internalMachines.contains(entry.principal.id)
                }
            return isInternal ? entry : entry.markingPrincipalExternal()
        }
    }

    /// Flag entries whose holder's account is disabled, so the list agrees with
    /// `can()` about who may actually act.
    private static func markingDisabledPrincipals(
        _ entries: [WhoCanEntry], on db: any Database
    ) async throws -> [WhoCanEntry] {
        let userIDs = Set(entries.filter { $0.principal.type == .user }.map(\.principal.id))
        guard !userIDs.isEmpty else { return entries }

        let disabled = Set(
            try await User.query(on: db)
                .filter(\.$id ~~ Array(userIDs))
                .filter(\.$disabledAt != nil)
                .all()
                .compactMap(\.id)
        )
        guard !disabled.isEmpty else { return entries }

        return entries.map { entry in
            guard entry.principal.type == .user, disabled.contains(entry.principal.id) else { return entry }
            return entry.markingPrincipalDisabled()
        }
    }

    /// Whether `action` on `node` is open to every authenticated user with no
    /// grant of any kind behind it — the reverse-lookup rendering of the
    /// `platform-open-network-read` tier-1 permit, which the enumeration needs
    /// because "everyone" cannot be a list (`WhoCanResult.openToAllAuthenticatedUsers`).
    ///
    /// Today this is exactly one rule: a global network — a `LogicalNetwork`
    /// with no project — is readable by anyone, because it is the fallback
    /// every VM create can land on (`NetworkController.fetchNetworkWithPermission`).
    /// The rule keys on the *project* alone, matching that handler and the
    /// permit's `openToAllUsers` attribute; a site-scoped network still has no
    /// project and so is still openly readable, even though the tree walk can
    /// climb it to an org.
    static func isOpenToAllAuthenticatedUsers(
        action: String, node: IAMNode, on db: any Database
    ) async throws -> Bool {
        guard node.type == .network, action == "network:read" else { return false }
        guard let network = try await LogicalNetwork.find(node.id, on: db) else { return false }
        return network.$project.id == nil
    }

    /// The `role_bindings.role` values (role-definition ids in uuidString
    /// form) of every role that grants `action` and is bindable somewhere on
    /// `chain`: the platform-owned rows plus rows owned by the chain's org or
    /// project. The action-set filter runs in Swift — the in-scope role set
    /// is small, and it keeps the query free of dialect-specific array
    /// operators.
    static func grantingRoleBindingValues(
        action: String, chain: [IAMNode], on db: any Database
    ) async throws -> [String] {
        let orgID = chain.first { $0.type == .organization }?.id
        let projectID = chain.first { $0.type == .project }?.id
        let candidates = try await IAMRoleDefinition.query(on: db)
            .group(.or) { anyOwner in
                anyOwner.filter(\.$ownerType == IAMRoleOwnerType.platform.rawValue)
                if let orgID {
                    anyOwner.group(.and) { owner in
                        owner.filter(\.$ownerType == IAMRoleOwnerType.organization.rawValue)
                        owner.filter(\.$ownerID == orgID)
                    }
                }
                if let projectID {
                    anyOwner.group(.and) { owner in
                        owner.filter(\.$ownerType == IAMRoleOwnerType.project.rawValue)
                        owner.filter(\.$ownerID == projectID)
                    }
                }
            }
            .all()
        return
            candidates
            .filter { $0.actions.contains(action) }
            .compactMap { $0.id?.uuidString }
    }

    /// Bindings along the chain whose role carries the action, plus the users
    /// each group binding expands to.
    private static func bindingEntries(
        action: String, chain: [IAMNode], on db: any Database
    ) async throws -> [WhoCanEntry] {
        guard !chain.isEmpty else { return [] }
        let grantingRoles = try await grantingRoleBindingValues(action: action, chain: chain, on: db)
        guard !grantingRoles.isEmpty else { return [] }

        let bindings = try await RoleBinding.query(on: db)
            .filter(\.$role ~~ grantingRoles)
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
                    role: roleLabel(binding.role),
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
                        role: roleLabel(binding.role),
                        grantedOn: IAMNode(type: nodeType, id: binding.nodeID),
                        via: group,
                        expiresAt: binding.expiresAt
                    )
                )
            }
        }
        return entries
    }

    /// Seeded roles keep reporting their names ("admin"), not their row ids —
    /// the who-can API's role field predates row identity and its consumers
    /// render it. User-created roles surface their id until the API grows
    /// display names (issue #605).
    private static func roleLabel(_ bindingValue: String) -> String {
        UUID(uuidString: bindingValue).flatMap { IAMRole(seededID: $0)?.rawValue } ?? bindingValue
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

    /// Whether one principal can perform `action` on `node` — the
    /// arbitrary-principal form of `can-i`, decided by `IAMDecisionEngine`:
    /// the same evaluator, over the same compiled policy set, that gates
    /// requests. Agreement with enforcement is by construction, not by keeping
    /// a second model in sync — grants, membership, platform permits, authored
    /// policies, and ceilings all land exactly as a real request would.
    ///
    /// Two things sit outside the evaluator, here as in production traffic:
    ///
    /// - A principal that could never *reach* the evaluator answers `false`:
    ///   a disabled user (`UserSecurityMiddleware` rejects it before any
    ///   protected operation) and a principal whose row does not exist (the
    ///   authenticator admits nobody by that id).
    /// - A group is a binding subject, not a request principal — no request
    ///   the evaluator sees ever carries one. Its answer comes from the
    ///   bindings model: a granting binding on the chain, minus the matcher
    ///   guardrails that can name a group.
    static func can(
        principalType: IAMPrincipalType, principalID: UUID, action: String, node: IAMNode,
        app: Application, on db: any Database
    ) async throws -> Bool {
        guard let principal = IAMPrincipal.requestPrincipal(type: principalType, id: principalID)
        else {
            guard try await groupIsGranted(groupID: principalID, action: action, node: node, on: db)
            else { return false }
            let forbidding = try await GuardrailStore.forbidding(
                action: action, principalType: principalType, principalID: principalID,
                node: node, on: db)
            return forbidding.isEmpty
        }

        guard try await principalMayAct(principal, on: db) else { return false }

        let built = try await IAMDecisionEngine.compiledSet(app)
        let decision = try await IAMDecisionEngine.decide(
            principal: principal, action: action, node: node, built: built, on: db)
        return decision.verdict.allowed
    }

    /// Whether the principal can reach the evaluator at all: its row exists,
    /// and (for a user) the account is not disabled. This has to precede the
    /// decision — the compiled set contains permits over *any* principal
    /// (`platform-open-network-read`), so an id nobody can authenticate as
    /// would otherwise be reported able to act.
    private static func principalMayAct(_ principal: IAMPrincipal, on db: any Database) async throws -> Bool {
        switch principal.type {
        case .user:
            guard let user = try await User.find(principal.id, on: db) else { return false }
            return user.disabledAt == nil
        case .serviceAccount:
            return try await ServiceAccount.find(principal.id, on: db) != nil
        case .workload:
            return try await WorkloadRegistration.find(principal.id, on: db) != nil
        case .group:
            return false
        }
    }

    /// Whether a granting binding names `groupID` on the node or anything
    /// above it — the group half of the forward check, answered from the
    /// bindings table because the evaluator has no group request principal.
    /// Membership, admin, and open-to-all sources cannot apply to a group.
    private static func groupIsGranted(
        groupID: UUID, action: String, node: IAMNode, on db: any Database
    ) async throws -> Bool {
        let chain = try await IAMResourceTree.ancestors(of: node, on: db)
        guard !chain.isEmpty else { return false }
        let grantingRoles = try await grantingRoleBindingValues(action: action, chain: chain, on: db)
        guard !grantingRoles.isEmpty else { return false }

        let matches = try await RoleBinding.query(on: db)
            .filter(\.$role ~~ grantingRoles)
            .filter(\.$principalType == IAMPrincipalType.group.rawValue)
            .filter(\.$principalID == groupID)
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
        return matches > 0
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
