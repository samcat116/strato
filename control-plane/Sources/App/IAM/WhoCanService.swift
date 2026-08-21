import ControlPlanePostgres
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
    /// The canonical role id that carries the action; nil for non-binding
    /// sources.
    let role: UUID?
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
        role: UUID?,
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
        action: String,
        node: IAMNode,
        app: Application,
        using iam: IAMPersistence,
        groups: GroupsPersistence,
        hierarchy: HierarchyPersistence,
        users: UserDirectoryPersistence,
        serviceAccounts: ServiceAccountsPersistence,
        workloads: WorkloadsPersistence
    ) async throws -> WhoCanResult {
        let built = try await IAMDecisionEngine.compiledSet(app)
        let chain = try await IAMResourceTree.ancestors(of: node, using: iam)
        var entries: [WhoCanEntry] = []

        entries += try await bindingEntries(action: action, chain: chain, using: iam, groups: groups)
        entries += try await membershipEntries(action: action, chain: chain, hierarchy: hierarchy)
        entries += try await systemAdminEntries(users: users)

        var principals = try await markingDisabledPrincipals(dedupedAndSorted(entries), users: users)
        principals = try await markingExternalPrincipals(principals, chain: chain, using: iam)
        principals = try await markingCeilingedPrincipals(
            principals,
            action: action,
            node: node,
            built: built,
            using: iam
        )

        // Only authored *permits* are a caveat now — they widen access to
        // principals a reverse lookup cannot enumerate. Authored forbids are
        // reflected exactly in `ceilings` and per-entry `ceilinged`.
        let authoredPermits = try await authoredPolicyMatches(
            action: action, chain: chain, effect: .permit, using: iam)
        let ceilings = try await ceilingsInForce(
            action: action,
            chain: chain,
            using: iam
        )

        return WhoCanResult(
            principals: principals,
            openToAllAuthenticatedUsers: isOpenToAllAuthenticatedUsers(action: action, node: node),
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
    ///
    /// Every entry asks about the *same* node, so the whole list is decided in
    /// one batch (#687): the ancestor chain and the resource attributes are
    /// resolved once for the enumeration instead of once per principal.
    private static func markingCeilingedPrincipals(
        _ entries: [WhoCanEntry], action: String, node: IAMNode,
        built: CedarPolicySetCache.Built,
        using iam: IAMPersistence
    ) async throws -> [WhoCanEntry] {
        let targets = entries.compactMap { entry in
            IAMPrincipal.requestPrincipal(type: entry.principal.type, id: entry.principal.id)
                .map { IAMCheckTarget(principal: $0, node: node) }
        }
        guard !targets.isEmpty else { return entries }
        let decisions = try await IAMDecisionEngine.decide(
            targets,
            action: action,
            built: built,
            using: iam
        )

        return entries.map { entry in
            guard
                let principal = IAMPrincipal.requestPrincipal(
                    type: entry.principal.type, id: entry.principal.id),
                let ceilingIDs = decisions[IAMCheckTarget(principal: principal, node: node)]?.denyingCeilingIDs
            else { return entry }
            return entry.markingCeilinged(ceilingIDs)
        }
    }

    /// The ceilings in force at the queried node: guardrails inherited down the
    /// tree whose actions cover `action`, plus authored forbid policies scoped
    /// to the resource (#610).
    private static func ceilingsInForce(
        action: String,
        chain: [IAMNode],
        using iam: IAMPersistence
    ) async throws -> [WhoCanCeiling] {
        var ceilings: [WhoCanCeiling] = []

        for guardrail in try await GuardrailStore.effective(along: chain, using: iam) {
            guard let node = guardrail.node else { continue }
            // A matcher row is filtered by its action patterns; an authored row
            // carries free-form Cedar whose action scope is not structurally
            // enumerable here, so it is always listed as in force.
            if !guardrail.authored, !GuardrailRendering.patternsCover(guardrail.actions, action: action) {
                continue
            }
            ceilings.append(
                WhoCanCeiling(kind: .guardrail, id: guardrail.id, name: guardrail.name, node: node)
            )
        }

        for match in try await authoredPolicyMatches(
            action: action, chain: chain, effect: .forbid, using: iam)
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
        action: String,
        chain: [IAMNode],
        effect wanted: IAMPolicyEffect,
        using iam: IAMPersistence
    ) async throws -> [WhoCanPolicyMatch] {
        let inScope = try await PolicyStore.inScope(along: chain, using: iam)
        guard !inScope.isEmpty else { return [] }
        let chainNodes = Set(chain)

        var matches: [WhoCanPolicyMatch] = []
        for policy in inScope {
            guard let owner = IAMRoleOwnerType(rawValue: policy.ownerType),
                let effect = IAMPolicyEffect(rawValue: policy.effect),
                let ownerNodeType = owner.nodeType
            else { continue }
            guard effect == wanted else { continue }
            guard
                let shape = try? CedarAuthoredPolicyInspector.describe(
                    cedarText: policy.cedarText,
                    policyID: PolicyDescriptor.policyID(policy.id))
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
                    policyID: policy.id,
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
        _ entries: [WhoCanEntry], chain: [IAMNode], using iam: IAMPersistence
    ) async throws -> [WhoCanEntry] {
        guard let root = chain.last, root.type == .organization else { return entries }
        let orgID = root.id
        var external: Set<WhoCanPrincipalRef> = []
        for principal in Set(entries.map(\.principal)) {
            if try await iam.principalIsExternal(
                type: principal.type.rawValue, id: principal.id, organizationID: orgID)
            {
                external.insert(principal)
            }
        }
        return entries.map { entry in
            external.contains(entry.principal) ? entry.markingPrincipalExternal() : entry
        }
    }

    /// Flag entries whose holder's account is disabled, so the list agrees with
    /// `can()` about who may actually act.
    private static func markingDisabledPrincipals(
        _ entries: [WhoCanEntry], users: UserDirectoryPersistence
    ) async throws -> [WhoCanEntry] {
        let userIDs = Set(entries.filter { $0.principal.type == .user }.map(\.principal.id))
        guard !userIDs.isEmpty else { return entries }

        let disabled = Set(
            try await users.users(filter: UserDirectoryFilter(ids: Array(userIDs), disabled: true))
                .map(\.id)
        )
        guard !disabled.isEmpty else { return entries }

        return entries.map { entry in
            guard entry.principal.type == .user, disabled.contains(entry.principal.id) else { return entry }
            return entry.markingPrincipalDisabled()
        }
    }

    /// Whether `action` on `node` is open to every authenticated user with no
    /// grant of any kind behind it — the reverse-lookup rendering of a tier-1
    /// permit whose principal is unconstrained, which the enumeration needs
    /// because "everyone" cannot be a list (`WhoCanResult.openToAllAuthenticatedUsers`).
    ///
    /// No such rule exists today. The one that did — a project-less network was
    /// readable by anyone, being the fallback every VM create landed on — went
    /// away with global networks themselves (issue #765). The hook and the
    /// result field stay so the next unconstrained permit has somewhere to
    /// render, and so the API shape does not churn.
    static func isOpenToAllAuthenticatedUsers(action: String, node: IAMNode) -> Bool {
        false
    }

    /// The role-definition ids of every role that grants `action` and is bindable somewhere on
    /// `chain`: the platform-owned rows plus rows owned by the chain's org or
    /// project. The action-set filter runs in Swift — the in-scope role set
    /// is small, and it keeps the query free of dialect-specific array
    /// operators.
    static func grantingRoleBindingValues(
        action: String,
        chain: [IAMNode],
        using iam: IAMPersistence
    ) async throws -> [UUID] {
        try await RoleStore.bindable(along: chain, using: iam)
            .filter { $0.actions.contains(action) }
            .map(\.id)
    }

    /// Bindings along the chain whose role carries the action, plus the users
    /// each group binding expands to.
    private static func bindingEntries(
        action: String,
        chain: [IAMNode],
        using iam: IAMPersistence,
        groups: GroupsPersistence
    ) async throws -> [WhoCanEntry] {
        guard !chain.isEmpty else { return [] }
        let grantingRoles = Set(
            try await grantingRoleBindingValues(action: action, chain: chain, using: iam)
        )
        guard !grantingRoles.isEmpty else { return [] }

        let bindings = try await iam.bindings(
            at: chain.map { IAMNodeReference(type: $0.type.rawValue, id: $0.id) }
        ).filter { grantingRoles.contains($0.roleID) }
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
                    role: binding.roleID,
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

        let memberships = try await groups.memberships(
            groupIDs: Array(Set(groupBindings.map(\.principalID))))
        let membersByGroup = Dictionary(grouping: memberships, by: \.groupID)

        for binding in groupBindings {
            guard let nodeType = IAMNodeType(rawValue: binding.nodeType) else { continue }
            let group = WhoCanPrincipalRef(type: .group, id: binding.principalID)
            for membership in membersByGroup[binding.principalID] ?? [] {
                entries.append(
                    WhoCanEntry(
                        principal: WhoCanPrincipalRef(type: .user, id: membership.userID),
                        source: .binding,
                        role: binding.roleID,
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
        action: String, chain: [IAMNode], hierarchy: HierarchyPersistence
    ) async throws -> [WhoCanEntry] {
        guard IAMRoleRegistry.membershipDerivedActions.contains(action),
            let orgNode = chain.first(where: { $0.type == .organization })
        else { return [] }

        let members = try await hierarchy.members(organizationID: orgNode.id)
        return members.map { membership in
            WhoCanEntry(
                principal: WhoCanPrincipalRef(type: .user, id: membership.userID),
                source: .orgMembership,
                role: nil,
                grantedOn: orgNode,
                via: nil,
                expiresAt: nil
            )
        }
    }

    /// System admins can perform any action on any resource.
    private static func systemAdminEntries(users: UserDirectoryPersistence) async throws -> [WhoCanEntry] {
        let admins = try await users.users(filter: UserDirectoryFilter(isSystemAdmin: true))
        return admins.map { admin in
            return WhoCanEntry(
                principal: WhoCanPrincipalRef(type: .user, id: admin.id),
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
            if lhs.role != rhs.role {
                return (lhs.role?.uuidString ?? "") < (rhs.role?.uuidString ?? "")
            }
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
        app: Application,
        cache: IAMRequestCache? = nil,
        using iam: IAMPersistence,
        groups: GroupsPersistence,
        users: UserDirectoryPersistence,
        serviceAccounts: ServiceAccountsPersistence,
        workloads: WorkloadsPersistence
    ) async throws -> Bool {
        try await can(
            principalType: principalType, principalID: principalID, action: action, nodes: [node],
            app: app, cache: cache, using: iam, groups: groups, users: users,
            serviceAccounts: serviceAccounts, workloads: workloads)[node] ?? false
    }

    /// The same answer for many resources at once (#687), so the batch check
    /// endpoint pays one entity-slice load rather than one per item. The
    /// single-resource form above is a batch of one.
    static func can(
        principalType: IAMPrincipalType, principalID: UUID, action: String, nodes: [IAMNode],
        app: Application,
        cache: IAMRequestCache? = nil,
        using iam: IAMPersistence,
        groups: GroupsPersistence,
        users: UserDirectoryPersistence,
        serviceAccounts: ServiceAccountsPersistence,
        workloads: WorkloadsPersistence
    ) async throws -> [IAMNode: Bool] {
        let distinct = Set(nodes)
        guard !distinct.isEmpty else { return [:] }

        guard let principal = IAMPrincipal.requestPrincipal(type: principalType, id: principalID)
        else {
            // A group is answered from the bindings model, not the evaluator,
            // so there is no slice to share — but the questions are still
            // independent and few.
            var answers: [IAMNode: Bool] = [:]
            for node in distinct {
                guard
                    try await groupIsGranted(
                        groupID: principalID,
                        action: action,
                        node: node,
                        using: iam
                    )
                else {
                    answers[node] = false
                    continue
                }
                let forbidding = try await GuardrailStore.forbidding(
                    action: action, principalType: principalType, principalID: principalID,
                    node: node, using: iam, groups: groups)
                answers[node] = forbidding.isEmpty
            }
            return answers
        }

        guard try await principalMayAct(
            principal, users: users, serviceAccounts: serviceAccounts, workloads: workloads)
        else {
            return Dictionary(uniqueKeysWithValues: distinct.map { ($0, false) })
        }

        let built = try await IAMDecisionEngine.compiledSet(app)
        let decisions = try await IAMDecisionEngine.decide(
            distinct.map { IAMCheckTarget(principal: principal, node: $0) },
            action: action,
            built: built,
            cache: cache,
            using: iam
        )
        return Dictionary(
            uniqueKeysWithValues: distinct.map {
                ($0, decisions[IAMCheckTarget(principal: principal, node: $0)]?.verdict.allowed ?? false)
            })
    }

    /// Whether the principal can reach the evaluator at all: its row exists,
    /// and (for a user) the account is not disabled. This has to precede the
    /// decision, because the compiled set may contain permits over *any*
    /// principal — an id nobody can authenticate as would otherwise be
    /// reported able to act. (No such permit exists today: the one that did,
    /// `platform-open-network-read`, went away with global networks in issue
    /// #765. The guard stays, since the next unconstrained permit must not
    /// silently reintroduce the hole.)
    private static func principalMayAct(
        _ principal: IAMPrincipal,
        users: UserDirectoryPersistence,
        serviceAccounts: ServiceAccountsPersistence,
        workloads: WorkloadsPersistence
    ) async throws -> Bool {
        switch principal.type {
        case .user:
            guard let user = try await users.user(id: principal.id) else { return false }
            return user.disabledAt == nil
        case .serviceAccount:
            return try await serviceAccounts.account(id: principal.id) != nil
        case .workload:
            return try await workloads.registration(id: principal.id) != nil
        case .group:
            return false
        }
    }

    /// Whether a granting binding names `groupID` on the node or anything
    /// above it — the group half of the forward check, answered from the
    /// bindings table because the evaluator has no group request principal.
    /// Membership, admin, and open-to-all sources cannot apply to a group.
    private static func groupIsGranted(
        groupID: UUID,
        action: String,
        node: IAMNode,
        using iam: IAMPersistence
    ) async throws -> Bool {
        let chain = try await IAMResourceTree.ancestors(of: node, using: iam)
        guard !chain.isEmpty else { return false }
        let grantingRoles = Set(
            try await grantingRoleBindingValues(action: action, chain: chain, using: iam)
        )
        guard !grantingRoles.isEmpty else { return false }

        return try await iam.bindings(
            at: chain.map { IAMNodeReference(type: $0.type.rawValue, id: $0.id) }
        ).contains {
            grantingRoles.contains($0.roleID)
                && $0.principalType == IAMPrincipalType.group.rawValue
                && $0.principalID == groupID
        }
    }

#if DEBUG
    package static func whoCan(
        action: String, node: IAMNode, app: Application,
        on _: PostgresStoreContext
    ) async throws -> WhoCanResult {
        try await whoCan(
            action: action, node: node, app: app,
            using: app.iamPersistence, groups: app.groupsPersistence,
            hierarchy: app.hierarchyPersistence, users: app.userDirectoryPersistence,
            serviceAccounts: app.serviceAccountsPersistence,
            workloads: app.workloadsPersistence)
    }

    package static func can(
        principalType: IAMPrincipalType, principalID: UUID,
        action: String, node: IAMNode, app: Application,
        cache: IAMRequestCache? = nil, on _: PostgresStoreContext
    ) async throws -> Bool {
        try await can(
            principalType: principalType, principalID: principalID, action: action,
            node: node, app: app, cache: cache,
            using: app.iamPersistence, groups: app.groupsPersistence,
            users: app.userDirectoryPersistence,
            serviceAccounts: app.serviceAccountsPersistence,
            workloads: app.workloadsPersistence)
    }

    package static func can(
        principalType: IAMPrincipalType, principalID: UUID,
        action: String, nodes: [IAMNode], app: Application,
        cache: IAMRequestCache? = nil, on _: PostgresStoreContext
    ) async throws -> [IAMNode: Bool] {
        try await can(
            principalType: principalType, principalID: principalID, action: action,
            nodes: nodes, app: app, cache: cache,
            using: app.iamPersistence, groups: app.groupsPersistence,
            users: app.userDirectoryPersistence,
            serviceAccounts: app.serviceAccountsPersistence,
            workloads: app.workloadsPersistence)
    }
#endif
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
