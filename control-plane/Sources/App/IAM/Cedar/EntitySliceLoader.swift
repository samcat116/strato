import Fluent
import Foundation

// IAM phase 3 (issue #480): the entity-slice loader.
//
// **This is the security-critical component of the Cedar integration.** Cedar
// only knows what it is given: a missing edge here is an authorization bug —
// a false deny for permits, or worse, a false ALLOW where a guardrail's
// evidence (a group parent edge, an org membership, an environment attribute)
// failed to load. It gets the heaviest test investment in the system
// (`EntitySliceLoaderTests`, including the cross-check against
// `WhoCanService.can`).

/// The flattened role grants for one check: which users and groups hold each
/// role on the target resource or anything above it, from the active,
/// unconditioned `role_bindings` along the ancestor chain.
struct CedarRoleGrants: Equatable, Sendable {
    private(set) var users: [IAMRole: Set<UUID>] = [:]
    private(set) var groups: [IAMRole: Set<UUID>] = [:]

    mutating func addUser(_ id: UUID, role: IAMRole) {
        users[role, default: []].insert(id)
    }

    mutating func addGroup(_ id: UUID, role: IAMRole) {
        groups[role, default: []].insert(id)
    }

    func users(for role: IAMRole) -> Set<UUID> { users[role] ?? [] }
    func groups(for role: IAMRole) -> Set<UUID> { groups[role] ?? [] }

    /// The `Grants` record for `context.grants`, every field present (the
    /// schema declares them required) and sorted for determinism.
    var contextValue: CedarValue {
        var fields: [String: CedarValue] = [:]
        for role in IAMRole.allCases {
            fields[role.grantsUsersField] = .set(
                users(for: role)
                    .map { CedarEntityUID(type: .user, id: $0) }
                    .sorted { $0.id < $1.id }
                    .map { .entity($0) })
            fields[role.grantsGroupsField] = .set(
                groups(for: role)
                    .map { CedarEntityUID(type: .group, id: $0) }
                    .sorted { $0.id < $1.id }
                    .map { .entity($0) })
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

    /// The request context carrying the grants. Ambient conditions (`mfa`,
    /// `sourceIP`) belong to the request rather than the slice and will merge
    /// in at check time; shadow evaluation (#481) passes this through
    /// unchanged, so conditioned bindings are skipped and counted until
    /// cutover (#482) wires the ambient half.
    var baseContextValue: CedarValue {
        .record(["grants": grants.contextValue])
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
        let chain = try await IAMResourceTree.ancestors(of: node, on: db)

        let user = try await User.find(userID, on: db)
        let groupIDs = try await UserGroup.query(on: db)
            .filter(\.$user.$id == userID)
            .all()
            .map { $0.$group.id }
        let organizationIDs = try await UserOrganization.query(on: db)
            .filter(\.$user.$id == userID)
            .all()
            .map { $0.$organization.id }

        var grants = CedarRoleGrants()
        var skippedConditionedBindings = 0
        if !chain.isEmpty {
            // The principal's own bindings plus those of every group it
            // belongs to, on any node in the chain. Filtering to this
            // principal is what keeps the slice per-check-sized; `who-can`
            // answers the all-principals question from the table directly.
            var principals: [(IAMPrincipalType, UUID)] = [(.user, userID)]
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
                // An unknown role or principal type is a row this build cannot
                // interpret; skipping under-grants, never over-grants.
                guard let role = IAMRole(rawValue: binding.role) else { continue }
                switch IAMPrincipalType(rawValue: binding.principalType) {
                case .user: grants.addUser(binding.principalID, role: role)
                case .group: grants.addGroup(binding.principalID, role: role)
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

        let principalUID = CedarEntityUID(type: .user, id: userID)
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
