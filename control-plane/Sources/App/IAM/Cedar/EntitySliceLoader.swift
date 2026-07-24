import Fluent
import Foundation
import Vapor

// IAM phase 3 (issue #480): the entity-slice loader.
//
// **This is the security-critical component of the Cedar integration.** Cedar
// only knows what it is given: a missing edge here is an authorization bug —
// a false deny for permits, or worse, a false ALLOW where a guardrail's
// evidence (a group parent edge, an org membership, an environment attribute)
// failed to load. It gets the heaviest test investment in the system
// (`EntitySliceLoaderTests`, including the cross-check of slice-derived
// decisions against an independent hand-simulation of the static policies).

/// The flattened role grants for one check: which users and groups hold each
/// role (by role-definition row id) on the target resource or anything above
/// it, from the active, unconditioned `role_bindings` along the ancestor
/// chain.
struct CedarRoleGrants: Equatable, Sendable {
    private(set) var users: [UUID: Set<UUID>] = [:]
    private(set) var groups: [UUID: Set<UUID>] = [:]
    private(set) var serviceAccounts: [UUID: Set<UUID>] = [:]
    private(set) var workloads: [UUID: Set<UUID>] = [:]

    mutating func addUser(_ id: UUID, roleID: UUID) {
        users[roleID, default: []].insert(id)
    }

    mutating func addGroup(_ id: UUID, roleID: UUID) {
        groups[roleID, default: []].insert(id)
    }

    mutating func addServiceAccount(_ id: UUID, roleID: UUID) {
        serviceAccounts[roleID, default: []].insert(id)
    }

    mutating func addWorkload(_ id: UUID, roleID: UUID) {
        workloads[roleID, default: []].insert(id)
    }

    func users(for roleID: UUID) -> Set<UUID> { users[roleID] ?? [] }
    func groups(for roleID: UUID) -> Set<UUID> { groups[roleID] ?? [] }
    func serviceAccounts(for roleID: UUID) -> Set<UUID> { serviceAccounts[roleID] ?? [] }
    func workloads(for roleID: UUID) -> Set<UUID> { workloads[roleID] ?? [] }

    /// The role ids the chain's bindings named — for logging what a stale
    /// schema dropped.
    var roleIDs: Set<UUID> {
        Set(users.keys).union(groups.keys).union(serviceAccounts.keys).union(workloads.keys)
    }

    /// The `Grants` record for `context.grants`: one field pair for **every**
    /// role the compiled schema declares (they are required fields — empty
    /// sets when no binding matched), and nothing else — a field the schema
    /// doesn't know fails strict validation for the whole request. Grants for
    /// a role id outside `roleIDs` (a role created seconds ago that this
    /// replica hasn't recompiled for, or deleted out from under a binding)
    /// are dropped: under-grant, never over-grant, converging on the next
    /// version nudge or 30s re-read.
    func contextValue(roleIDs: Set<UUID>) -> CedarValue {
        func set(_ ids: Set<UUID>, type: CedarEntityType) -> CedarValue {
            .set(
                ids
                    .map { CedarEntityUID(type: type, id: $0) }
                    .sorted { $0.id < $1.id }
                    .map { .entity($0) })
        }
        var fields: [String: CedarValue] = [:]
        for roleID in roleIDs {
            fields[RoleDescriptor.grantsUsersField(roleID)] = set(users(for: roleID), type: .user)
            fields[RoleDescriptor.grantsGroupsField(roleID)] = set(groups(for: roleID), type: .group)
            fields[RoleDescriptor.grantsServiceAccountsField(roleID)] = set(
                serviceAccounts(for: roleID), type: .serviceAccount)
            fields[RoleDescriptor.grantsWorkloadsField(roleID)] = set(workloads(for: roleID), type: .workload)
        }
        return .record(fields)
    }
}

/// Everything one authorization check hands to Cedar: the principal and
/// resource entities (with hierarchy and attributes) and the flattened grants
/// destined for the request context.
struct CedarEntitySlice: Equatable, Sendable {
    let principal: CedarEntityUID
    let resource: CedarEntityUID
    /// The resource's ancestor chain, leaf first — the same walk the entity
    /// parent edges encode, kept in tree vocabulary so callers (the decision
    /// log) can name the containing organization without re-walking the tree.
    let chain: [IAMNode]
    /// The entity store for this check, sorted by (type, id).
    let entities: [CedarEntity]
    let grants: CedarRoleGrants
    /// Bindings along the chain that carried a `condition` document. The
    /// condition vocabulary is not compiled yet (no store writes one), and
    /// flattening a conditioned binding as if it were unconditional would turn
    /// a restricted grant into an open one — so they are skipped, which can
    /// only under-grant, and counted so the caller can log them.
    let skippedConditionedBindings: Int
    /// Whether the ancestor chain reached its root. A truncated chain (an
    /// orphaned intermediate node, a scopeless legacy site) under-grants
    /// harmlessly for tier 3 — but it is fail-*open* for tier-2 guardrails: a
    /// `forbid (… resource in Organization::"X")` silently stops matching the
    /// moment the parent edges no longer reach X, while an in-chain binding
    /// still fires its permit. The authorizer denies outright when this is
    /// false; a ceiling that "usually" applies is not a ceiling.
    let chainComplete: Bool

    /// The entity store in Cedar's entities JSON format.
    func entitiesJSON() throws -> String {
        try CedarText.json(entities)
    }

    /// The request context carrying the grants, shaped to the compiled
    /// schema: `roleIDs` is the caller's `Built.roleIDs`. Ambient conditions
    /// (`mfa`, `sourceIP`) belong to the request rather than the slice and
    /// will merge in at check time; shadow evaluation (#481) passes this
    /// through unchanged, so conditioned bindings are skipped and counted
    /// until cutover (#482) wires the ambient half.
    func baseContextValue(roleIDs: Set<UUID>) -> CedarValue {
        .record(["grants": grants.contextValue(roleIDs: roleIDs)])
    }
}

/// One question a batch asks: which principal, on which node.
///
/// The action is not part of it — grants are role-shaped and action resolution
/// happens in the policy set, so one slice serves any action on a node. A batch
/// therefore shares its action, and callers with mixed actions group by action
/// (the request cache makes the second group's chains and memberships free).
struct IAMCheckTarget: Hashable, Sendable {
    let principal: IAMPrincipal
    let node: IAMNode

    init(principal: IAMPrincipal, node: IAMNode) {
        self.principal = principal
        self.node = node
    }
}

enum EntitySliceLoader {

    /// Gather the slice for "may `userID` act on `node`?".
    ///
    /// One shared function on purpose: every check, whatever the action, loads
    /// through here — the resource's ancestor chain (with parent edges, so
    /// `in` walks the same tree `IAMResourceTree` does), the principal's group
    /// memberships and org memberships (cross-org principals included — the
    /// chain's org is not a filter), and the applicable bindings along the
    /// chain.
    ///
    /// The action is deliberately not a parameter. Grants are role-shaped and
    /// action resolution happens in the policy set, so one slice serves any
    /// action on the node — and there is no per-action code path here to get
    /// out of sync.
    static func load(
        userID: UUID, node: IAMNode, cache: IAMRequestCache? = nil, on db: any Database
    ) async throws -> CedarEntitySlice {
        try await load(principal: .user(userID), node: node, cache: cache, on: db)
    }

    /// Gather the slice for "may `principal` act on `node`?" — the typed form
    /// covering machine principals (issue #491). A service-account or
    /// workload principal has no group or org memberships to expand: its
    /// grants are exactly its own bindings along the chain.
    /// - Parameter action: the action being checked, when the caller knows it.
    ///   Only used to decide whether to compute attributes expensive enough to
    ///   be worth skipping when no policy could read them (today: the agent
    ///   foreign-workload inventory). Passing nil simply omits those.
    /// - Parameter cache: the request-scoped cache (#686). The principal's
    ///   memberships and the resource's ancestor chain are the same for every
    ///   check in a request, so they are loaded once and reused; passing nil
    ///   loads everything, which is what callers outside a request do.
    static func load(
        principal: IAMPrincipal, node: IAMNode, action: String? = nil,
        cache: IAMRequestCache? = nil, on db: any Database
    ) async throws -> CedarEntitySlice {
        let target = IAMCheckTarget(principal: principal, node: node)
        guard let slice = try await load([target], action: action, cache: cache, on: db)[target] else {
            // Unreachable: the batch is total over its inputs. Failing closed
            // beats a force-unwrap in the security-critical path.
            throw Abort(.internalServerError, reason: "Authorization entity slice unavailable")
        }
        return slice
    }

    /// Gather the slices for a whole batch of questions (#687).
    ///
    /// The single-target forms above are batches of one, so there is exactly
    /// one place that reads the database for a slice. What batching buys is
    /// that every read here is set-based: the ancestor chains resolve in one
    /// lockstep walk, the principals' memberships in three queries however many
    /// principals there are, and the bindings along every chain in a single
    /// query. Cedar evaluation itself is pure CPU, so the loader is the only
    /// part of a decision that needed batching at all.
    ///
    /// The number of queries therefore depends on the *shape* of the batch —
    /// tree depth and node types — not on its size: a hundred VMs in a list
    /// cost what one VM costs.
    static func load(
        _ targets: [IAMCheckTarget], action: String? = nil,
        cache: IAMRequestCache? = nil, on db: any Database
    ) async throws -> [IAMCheckTarget: CedarEntitySlice] {
        let distinct = Set(targets)
        guard !distinct.isEmpty else { return [:] }

        // Independent loads: the chain walk knows nothing about the principals
        // and the memberships know nothing about the resources. Only the
        // bindings query below needs both.
        async let resolvedChains = IAMResourceTree.resolve(distinct.map(\.node), cache: cache, on: db)
        async let principalFacts = IAMUserFacts.load(
            userIDs: Set(distinct.compactMap { $0.principal.type == .user ? $0.principal.id : nil }),
            cache: cache, on: db)
        let resolutions = try await resolvedChains
        var userFacts = try await principalFacts

        // `User`'s schema attributes are required, so a user standing as the
        // *resource* — an admin reading somebody else's record — needs them
        // too, or the whole entity store fails schema validation and the check
        // fails closed. Which users those are is known only once the chains are
        // in hand.
        let resourceUserIDs = Set(
            resolutions.values.lazy.flatMap(\.chain).filter { $0.type == .user }.map(\.id)
        ).subtracting(userFacts.keys)
        if !resourceUserIDs.isEmpty {
            let loaded = try await IAMUserFacts.load(userIDs: resourceUserIDs, cache: cache, on: db)
            userFacts.merge(loaded) { current, _ in current }
        }

        let bindings = try await bindingsAlongChains(
            for: distinct, resolutions: resolutions, userFacts: userFacts, on: db)
        let foreignWorkloads = try await agentForeignWorkloads(
            for: distinct.map(\.node), action: action, on: db)

        var slices: [IAMCheckTarget: CedarEntitySlice] = [:]
        slices.reserveCapacity(distinct.count)
        for target in distinct {
            slices[target] = slice(
                for: target,
                resolution: resolutions[target.node]
                    ?? IAMResourceTree.Resolution(chain: [target.node], leaf: IAMLeafFacts()),
                userFacts: userFacts,
                bindingsByNode: bindings,
                hostsForeignWorkloads: foreignWorkloads[target.node])
        }
        return slices
    }

    /// The binding subjects whose grants count as a principal's: itself, plus
    /// every group it belongs to. Machine principals have no groups by design,
    /// so their subject list is just themselves.
    private static func bindingSubjects(
        of principal: IAMPrincipal, userFacts: [UUID: IAMUserFacts]
    ) -> [IAMPrincipal] {
        var subjects = [principal]
        if principal.type == .user {
            subjects += (userFacts[principal.id]?.groupIDs ?? []).map { IAMPrincipal(type: .group, id: $0) }
        }
        return subjects
    }

    /// Every active binding that any target could see, in one query, indexed by
    /// the node it attaches to.
    ///
    /// Filtering to the batch's principals is what keeps the result
    /// batch-sized; `who-can` answers the all-principals question from the
    /// table directly. The `(type, id-set)` grouping keeps the predicate a
    /// handful of OR terms rather than one per node — a hundred-VM list is four
    /// or five terms, not a hundred.
    private static func bindingsAlongChains(
        for targets: Set<IAMCheckTarget>,
        resolutions: [IAMNode: IAMResourceTree.Resolution],
        userFacts: [UUID: IAMUserFacts],
        on db: any Database
    ) async throws -> [IAMNode: [RoleBinding]] {
        var subjectIDs: [IAMPrincipalType: Set<UUID>] = [:]
        var chainIDs: [IAMNodeType: Set<UUID>] = [:]
        for target in targets {
            for subject in bindingSubjects(of: target.principal, userFacts: userFacts) {
                subjectIDs[subject.type, default: []].insert(subject.id)
            }
            for node in resolutions[target.node]?.chain ?? [] {
                chainIDs[node.type, default: []].insert(node.id)
            }
        }
        guard !subjectIDs.isEmpty, !chainIDs.isEmpty else { return [:] }

        let rows = try await RoleBinding.query(on: db)
            .group(.or) { anyPrincipal in
                for (type, ids) in subjectIDs {
                    anyPrincipal.group(.and) { thisType in
                        thisType.filter(\.$principalType == type.rawValue)
                        thisType.filter(\.$principalID ~~ Array(ids))
                    }
                }
            }
            .group(.or) { anyNode in
                for (type, ids) in chainIDs {
                    anyNode.group(.and) { thisType in
                        thisType.filter(\.$nodeType == type.rawValue)
                        thisType.filter(\.$nodeID ~~ Array(ids))
                    }
                }
            }
            .active()
            .all()

        var byNode: [IAMNode: [RoleBinding]] = [:]
        for row in rows {
            guard let nodeType = IAMNodeType(rawValue: row.nodeType) else { continue }
            byNode[IAMNode(type: nodeType, id: row.nodeID), default: []].append(row)
        }
        return byNode
    }

    /// The agent foreign-workload inventory for the batch, or nothing when no
    /// policy could read it.
    ///
    /// Gated on the same constant the forbid's action list is built from, so
    /// the attribute is present exactly when a policy can read it.
    private static func agentForeignWorkloads(
        for nodes: [IAMNode], action: String?, on db: any Database
    ) async throws -> [IAMNode: Bool] {
        guard let action, IAMRoleRegistry.agentForeignWorkloadGuardedActions.contains(action) else { return [:] }
        let agentIDs = Set(nodes.lazy.filter { $0.type == .agent }.map(\.id))
        guard !agentIDs.isEmpty else { return [:] }

        var rows: [UUID: Agent] = [:]
        for agent in try await Agent.query(on: db).filter(\.$id ~~ Array(agentIDs)).all() {
            if let id = agent.id { rows[id] = agent }
        }
        var inventory: [IAMNode: Bool] = [:]
        for agentID in agentIDs {
            // Missing row → true: an agent we cannot inventory is not one to
            // let a delegated admin take down.
            inventory[IAMNode(type: .agent, id: agentID)] =
                try await rows[agentID]?.hostsForeignWorkloads(on: db) ?? true
        }
        return inventory
    }

    /// Assemble one slice from data already in memory. Pure — every database
    /// read the slice needs happened in `load(_:action:cache:on:)` above.
    private static func slice(
        for target: IAMCheckTarget,
        resolution: IAMResourceTree.Resolution,
        userFacts: [UUID: IAMUserFacts],
        bindingsByNode: [IAMNode: [RoleBinding]],
        hostsForeignWorkloads: Bool?
    ) -> CedarEntitySlice {
        let principal = target.principal
        let node = target.node
        let chain = resolution.chain
        let facts = principal.type == .user ? (userFacts[principal.id] ?? .none) : .none
        let groupIDs = facts.groupIDs
        let organizationIDs = facts.organizationIDs

        var grants = CedarRoleGrants()
        var skippedConditionedBindings = 0
        let subjects = Set(bindingSubjects(of: principal, userFacts: userFacts))
        for chainNode in chain {
            for binding in bindingsByNode[chainNode] ?? [] {
                guard let principalType = IAMPrincipalType(rawValue: binding.principalType),
                    subjects.contains(IAMPrincipal(type: principalType, id: binding.principalID))
                else { continue }
                guard binding.condition == nil else {
                    skippedConditionedBindings += 1
                    continue
                }
                // A role value that is no UUID is a row this build cannot
                // interpret; skipping under-grants, never over-grants.
                // (Whether the id names a *live* role is the compiled set's
                // call — `contextValue(roleIDs:)` filters against it at
                // context-build time.)
                guard let roleID = UUID(uuidString: binding.role) else { continue }
                switch principalType {
                case .user: grants.addUser(binding.principalID, roleID: roleID)
                case .group: grants.addGroup(binding.principalID, roleID: roleID)
                case .serviceAccount: grants.addServiceAccount(binding.principalID, roleID: roleID)
                case .workload: grants.addWorkload(binding.principalID, roleID: roleID)
                }
            }
        }

        // The chain is complete when it terminates at an organization — the
        // root every guardrail attach node resolves through. Two shapes are
        // rootless *by design* and stay complete: the organization itself, and
        // a global network (no project, no site), which is deliberately
        // project-less as the VM-create fallback (`platform-open-network-read`).
        var chainComplete = chain.last?.type == .organization
        if !chainComplete, node.type == .network, chain.count == 1 {
            // A network row we could not read leaves both facts nil, which
            // reads here as "not the global network" — incomplete, denied.
            chainComplete = resolution.leaf.networkHasProject == false && resolution.leaf.networkHasSite == false
        }
        // A user record is the third rootless-by-design shape: it has no
        // parent at all (see `IAMNodeType.user`), so its one-element chain is
        // as complete as it will ever be. Leaving it incomplete would make the
        // authorizer deny every identity-plane check outright.
        if !chainComplete, node.type == .user {
            chainComplete = chain.count == 1
        }

        var entities: [CedarEntity] = []

        let principalUID = principal.cedarUID
        // A *user* reading their own record is principal and resource at once.
        // The two roles must merge into one entity: a second entry under the
        // same UID would shadow `systemAdmin` and `memberOfOrgs`, silently
        // breaking both tier-1 policies.
        //
        // Scoped to user principals deliberately. A service account checked
        // against its own node is also principal-and-resource, but there the
        // opposite arrangement holds — the branch below emits no separate
        // principal entity and lets the chain supply it — so skipping the
        // chain entry would leave the store with none at all.
        let principalIsResource = principal.type == .user && node.cedarUID == principalUID
        if principal.type == .user {
            var attrs = userAttrs(organizationIDs: organizationIDs, isSystemAdmin: facts.isSystemAdmin)
            if principalIsResource, let environment = resolution.leaf.environment {
                attrs["environment"] = .string(environment)
            }
            entities.append(
                CedarEntity(
                    uid: principalUID,
                    attrs: attrs,
                    parents: groupIDs.map { CedarEntityUID(type: .group, id: $0) }.sorted { $0.id < $1.id }
                ))
        } else if !chain.contains(where: { $0.cedarUID == principalUID }) {
            // Machine principals are attribute- and parent-free by design:
            // the schema declares them memberships-less, so the
            // membership-shaped platform policies can never apply. When the
            // principal *is* the resource (a service account checked against
            // its own node), the chain entity below already carries the UID —
            // adding it twice would duplicate the entity in the store.
            entities.append(CedarEntity(uid: principalUID, attrs: [:], parents: []))
        }
        for groupID in groupIDs {
            entities.append(CedarEntity(uid: CedarEntityUID(type: .group, id: groupID), attrs: [:], parents: []))
        }

        for (index, chainNode) in chain.enumerated() {
            // Already emitted above, attributes and all, by the self-check merge.
            if principalIsResource, chainNode.cedarUID == principalUID { continue }
            var attrs: [String: CedarValue] = [:]
            if chainNode.type == .user {
                // The resource-side user attributes prefetched above. (The
                // self-check case never reaches here: it merged into the
                // principal.)
                let resourceUser = userFacts[chainNode.id] ?? .none
                attrs = userAttrs(
                    organizationIDs: resourceUser.organizationIDs, isSystemAdmin: resourceUser.isSystemAdmin)
            }
            if chainNode == node {
                if let environment = resolution.leaf.environment {
                    attrs["environment"] = .string(environment)
                }
                if node.type == .network {
                    // Missing row → false: an unreadable network must not
                    // become world-readable.
                    attrs["openToAllUsers"] = .bool(resolution.leaf.networkHasProject == false)
                }
                if node.type == .agent, let hostsForeignWorkloads {
                    attrs["hostsForeignWorkloads"] = .bool(hostsForeignWorkloads)
                }
            }
            let parents = index + 1 < chain.count ? [chain[index + 1].cedarUID] : []
            entities.append(CedarEntity(uid: chainNode.cedarUID, attrs: attrs, parents: parents))
        }

        entities.sort {
            ($0.uid.type, $0.uid.id) < ($1.uid.type, $1.uid.id)
        }

        return CedarEntitySlice(
            principal: principalUID,
            resource: node.cedarUID,
            chain: chain,
            entities: entities,
            grants: grants,
            skippedConditionedBindings: skippedConditionedBindings,
            chainComplete: chainComplete
        )
    }

    /// The schema-required attributes of a `User` entity. Both roles a user can
    /// play in a check need them: as principal (the tier-1 policies read
    /// `principal.systemAdmin` and `principal.memberOfOrgs`) and, since
    /// `IAMNodeType.user`, as resource — the schema declares them required, so
    /// an entity missing either one fails validation for the entire store.
    private static func userAttrs(organizationIDs: [UUID], isSystemAdmin: Bool) -> [String: CedarValue] {
        [
            "memberOfOrgs": .set(
                organizationIDs
                    .map { CedarEntityUID(type: .organization, id: $0) }
                    .sorted { $0.id < $1.id }
                    .map { .entity($0) }),
            "systemAdmin": .bool(isSystemAdmin),
        ]
    }
}
