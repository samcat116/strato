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
    static func load(principal: IAMPrincipal, node: IAMNode, on db: any Database) async throws -> CedarEntitySlice {
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

        var entities: [CedarEntity] = []

        let principalUID = principal.cedarUID
        if principal.type == .user {
            entities.append(
                CedarEntity(
                    uid: principalUID,
                    attrs: [
                        "memberOfOrgs": .set(
                            organizationIDs
                                .map { CedarEntityUID(type: .organization, id: $0) }
                                .sorted { $0.id < $1.id }
                                .map { .entity($0) }),
                        "systemAdmin": .bool(user?.isSystemAdmin ?? false),
                    ],
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
            var attrs: [String: CedarValue] = [:]
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
}
