import Fluent
import Foundation

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
    static func load(userID: UUID, node: IAMNode, on db: any Database) async throws -> CedarEntitySlice {
        try await load(principal: .user(userID), node: node, on: db)
    }

    /// Gather the slice for "may `principal` act on `node`?" — the typed form
    /// covering machine principals (issue #491). A service-account or
    /// workload principal has no group or org memberships to expand: its
    /// grants are exactly its own bindings along the chain.
    /// - Parameter action: the action being checked, when the caller knows it.
    ///   Only used to decide whether to compute attributes expensive enough to
    ///   be worth skipping when no policy could read them (today: the agent
    ///   foreign-workload inventory). Passing nil simply omits those.
    static func load(
        principal: IAMPrincipal, node: IAMNode, action: String? = nil, on db: any Database
    ) async throws -> CedarEntitySlice {
        let chain = try await IAMResourceTree.ancestors(of: node, on: db)

        let user = principal.type == .user ? try await User.find(principal.id, on: db) : nil
        let groupIDs: [UUID]
        let organizationIDs: [UUID]
        if principal.type == .user {
            groupIDs = try await UserGroup.query(on: db)
                .filter(\.$user.$id == principal.id)
                .all()
                .map { $0.$group.id }
            organizationIDs = try await UserOrganization.query(on: db)
                .filter(\.$user.$id == principal.id)
                .all()
                .map { $0.$organization.id }
        } else {
            groupIDs = []
            organizationIDs = []
        }

        var grants = CedarRoleGrants()
        var skippedConditionedBindings = 0
        if !chain.isEmpty {
            // The principal's own bindings plus those of every group it
            // belongs to, on any node in the chain. Filtering to this
            // principal is what keeps the slice per-check-sized; `who-can`
            // answers the all-principals question from the table directly.
            var principals: [(IAMPrincipalType, UUID)] = [(principal.type, principal.id)]
            principals += groupIDs.map { (IAMPrincipalType.group, $0) }

            let bindings = try await RoleBinding.query(on: db)
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
                .all()

            for binding in bindings {
                guard binding.condition == nil else {
                    skippedConditionedBindings += 1
                    continue
                }
                // A role value that is no UUID, or an unknown principal type,
                // is a row this build cannot interpret; skipping under-grants,
                // never over-grants. (Whether the id names a *live* role is
                // the compiled set's call — `contextValue(roleIDs:)` filters
                // against it at context-build time.)
                guard let roleID = UUID(uuidString: binding.role) else { continue }
                switch IAMPrincipalType(rawValue: binding.principalType) {
                case .user: grants.addUser(binding.principalID, roleID: roleID)
                case .group: grants.addGroup(binding.principalID, roleID: roleID)
                case .serviceAccount: grants.addServiceAccount(binding.principalID, roleID: roleID)
                case .workload: grants.addWorkload(binding.principalID, roleID: roleID)
                case nil: continue
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
            if let network = try await LogicalNetwork.find(node.id, on: db) {
                chainComplete = network.$project.id == nil && network.$site.id == nil
            }
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
            var attrs = userAttrs(organizationIDs: organizationIDs, isSystemAdmin: user?.isSystemAdmin ?? false)
            if principalIsResource,
                let environment = try await GuardrailStore.resourceEnvironment(of: node, on: db)
            {
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
                // `User`'s schema attributes are required, so a user standing
                // as the *resource* — an admin reading somebody else's record —
                // must carry them too, or the whole entity store fails schema
                // validation and the check fails closed. (The self-check case
                // never reaches here: it merged into the principal above.)
                let target = try await User.find(chainNode.id, on: db)
                let targetOrgIDs = try await UserOrganization.query(on: db)
                    .filter(\.$user.$id == chainNode.id)
                    .all()
                    .map { $0.$organization.id }
                attrs = userAttrs(
                    organizationIDs: targetOrgIDs, isSystemAdmin: target?.isSystemAdmin ?? false)
            }
            if chainNode == node {
                if let environment = try await GuardrailStore.resourceEnvironment(of: node, on: db) {
                    attrs["environment"] = .string(environment)
                }
                if node.type == .network {
                    // Missing row → false: an unreadable network must not
                    // become world-readable.
                    let network = try await LogicalNetwork.find(node.id, on: db)
                    attrs["openToAllUsers"] = .bool(network.map { $0.$project.id == nil } ?? false)
                }
                if node.type == .agent, let action,
                    IAMRoleRegistry.agentForeignWorkloadGuardedActions.contains(action)
                {
                    // Gated on the same constant the forbid's action list is
                    // built from, so the attribute is present exactly when a
                    // policy can read it. Missing row → true: an agent we
                    // cannot inventory is not one to let a delegated admin
                    // take down.
                    let agent = try await Agent.find(node.id, on: db)
                    let foreign = try await agent?.hostsForeignWorkloads(on: db) ?? true
                    attrs["hostsForeignWorkloads"] = .bool(foreign)
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
