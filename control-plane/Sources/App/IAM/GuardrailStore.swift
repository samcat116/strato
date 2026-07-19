import Fluent
import Foundation
import Vapor

/// Reads, writes, and evaluates tier-2 guardrails (issue #479).
///
/// Two responsibilities that belong together because they must not drift:
///
/// - **The write path** is where "forbid-only" and the fixed vocabulary are
///   enforced. Every rejection here is a `400` — a malformed ceiling is a bad
///   request, the same way illegal parentage is (docs/architecture/iam.md,
///   tier 0).
/// - **The evaluation path** answers "which ceilings forbid this?" by
///   collecting every guardrail along the resource's ancestry chain. They
///   intersect: the answer is a *list*, and any non-empty list is a denial.
///
/// Enforcement is not wired into request gating yet — SpiceDB still gates
/// requests through phase 1, and the evaluator lands with #480/#482. What
/// ships here is the store and the semantics, so the Cedar integration and the
/// symcc write-time check (#484) build on something already tested.
enum GuardrailStore {

    /// The node types a guardrail may attach to.
    ///
    /// Containers only. A ceiling exists to cover everything beneath it, and a
    /// leaf resource has nothing beneath it — a "ceiling" there would be an
    /// ordinary per-resource rule wearing tier 2's clothes, and it would let
    /// someone place a rule the resource's own admins cannot see coming from
    /// above.
    static let attachableNodeTypes: Set<IAMNodeType> = [.organization, .organizationalUnit, .project]

    // MARK: - Write path

    /// Reject anything that is not a forbid.
    ///
    /// The API takes an `effect` so a client sending `permit` gets told what is
    /// wrong, instead of the field being ignored and the caller believing a
    /// grant was created. Omitting it means `forbid`, since that is the only
    /// thing a guardrail can be.
    static func validateEffect(_ effect: String?) throws {
        guard let effect else { return }
        guard effect.lowercased() == GuardrailEffect.forbid.rawValue else {
            throw GuardrailError.permitRejected(effect)
        }
    }

    /// Create a guardrail, validating the whole shape first.
    ///
    /// The caller is responsible for bumping the policy-set version in the
    /// same transaction — see `GuardrailController`.
    static func create(
        name: String,
        description: String?,
        effect: String?,
        node: IAMNode,
        actions: [String],
        principalMatch: GuardrailPrincipalMatch,
        resourceMatch: GuardrailResourceMatch,
        enabled: Bool = true,
        createdBy: UUID?,
        on db: any Database
    ) async throws -> Guardrail {
        try validateEffect(effect)
        guard attachableNodeTypes.contains(node.type) else {
            throw GuardrailError.unattachableNode(node.type.rawValue)
        }
        let canonicalActions = try GuardrailActions.canonicalize(actions)
        try validateNotTotal(actions: canonicalActions, principalMatch: principalMatch, resourceMatch: resourceMatch)

        let guardrail = Guardrail(
            name: name,
            description: description,
            nodeType: node.type,
            nodeID: node.id,
            actions: canonicalActions,
            principalMatch: principalMatch,
            resourceMatch: resourceMatch,
            enabled: enabled,
            createdBy: createdBy
        )
        do {
            try await guardrail.save(on: db)
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw GuardrailError.duplicateName(name)
        }
        return guardrail
    }

    /// A guardrail that forbids every action, for every principal, on every
    /// resource is the one ceiling nobody can climb back out of: it denies the
    /// `iam:setPolicy` that would be needed to remove it, on the node it is
    /// attached to and everything below. Refusing it is not paternalism about
    /// strict policy — it is refusing to let an org lock itself out with a
    /// single write.
    private static func validateNotTotal(
        actions: [String],
        principalMatch: GuardrailPrincipalMatch,
        resourceMatch: GuardrailResourceMatch
    ) throws {
        guard actions == [GuardrailActions.wildcard],
            principalMatch == .any,
            resourceMatch == .any
        else { return }
        throw GuardrailError.forbidsEverything
    }

    /// Apply a partial update. Only the fields present are touched; the effect
    /// is not updatable, because there is nothing to change it to, and neither
    /// is the attach node — moving a ceiling changes which subtree it covers,
    /// which is a different guardrail, not an edit to this one.
    static func update(
        _ guardrail: Guardrail,
        description: String?,
        actions: [String]?,
        principalMatch: GuardrailPrincipalMatch?,
        resourceMatch: GuardrailResourceMatch?,
        enabled: Bool?,
        on db: any Database
    ) async throws -> Guardrail {
        if let description { guardrail.description = description }
        if let actions { guardrail.actions = try GuardrailActions.canonicalize(actions) }
        if let principalMatch {
            guardrail.principalMatchKind = principalMatch.kind.rawValue
            guardrail.principalMatchID = principalMatch.subjectID
        }
        if let resourceMatch {
            guardrail.resourceMatchKind = resourceMatch.kind.rawValue
            guardrail.resourceMatchValue = resourceMatch.value
        }
        if let enabled { guardrail.enabled = enabled }

        try validateNotTotal(
            actions: guardrail.actions,
            principalMatch: try guardrail.principalMatch(),
            resourceMatch: try guardrail.resourceMatch()
        )

        try await guardrail.save(on: db)
        return guardrail
    }

    // MARK: - Read path

    /// The guardrails attached directly to a node, enabled or not — what an
    /// admin of that node manages.
    static func attached(to node: IAMNode, on db: any Database) async throws -> [Guardrail] {
        try await Guardrail.query(on: db)
            .filter(\.$nodeType == node.type.rawValue)
            .filter(\.$nodeID == node.id)
            .sort(\.$name)
            .all()
    }

    /// Every enabled guardrail in force at `node`: those attached to it and
    /// those attached to anything above it.
    ///
    /// All of them apply. There is no precedence rule to consult and no
    /// "nearest wins" — ceilings intersect, so the effective ceiling is the
    /// conjunction of the whole chain.
    static func effective(at node: IAMNode, on db: any Database) async throws -> [Guardrail] {
        let chain = try await IAMResourceTree.ancestors(of: node, on: db)
        return try await effective(along: chain, on: db)
    }

    /// `effective(at:)` for a chain the caller already walked.
    static func effective(along chain: [IAMNode], on db: any Database) async throws -> [Guardrail] {
        guard !chain.isEmpty else { return [] }
        return try await Guardrail.query(on: db)
            .filter(\.$enabled == true)
            .group(.or) { anyNode in
                for node in chain {
                    anyNode.group(.and) { thisNode in
                        thisNode.filter(\.$nodeType == node.type.rawValue)
                        thisNode.filter(\.$nodeID == node.id)
                    }
                }
            }
            .sort(\.$name)
            .all()
    }

    // MARK: - Evaluation

    /// Every guardrail that forbids `principal` performing `action` on `node`.
    ///
    /// Returns all of them rather than the first: a denial should be able to
    /// name every ceiling in the way, or removing one guardrail looks like it
    /// will unblock a request that the next one still blocks.
    static func forbidding(
        action: String,
        principalType: IAMPrincipalType,
        principalID: UUID,
        node: IAMNode,
        on db: any Database
    ) async throws -> [Guardrail] {
        let chain = try await IAMResourceTree.ancestors(of: node, on: db)
        let candidates = try await effective(along: chain, on: db)
        guard !candidates.isEmpty else { return [] }

        let environment = try await resourceEnvironment(of: node, on: db)
        let organizationID = chain.first(where: { $0.type == .organization })?.id

        var matched: [Guardrail] = []
        for guardrail in candidates {
            guard GuardrailActions.matches(guardrail.actions, action: action) else { continue }
            guard try matches(try guardrail.resourceMatch(), environment: environment) else { continue }
            guard
                try await matches(
                    try guardrail.principalMatch(),
                    principalType: principalType,
                    principalID: principalID,
                    organizationID: organizationID,
                    on: db
                )
            else { continue }
            matched.append(guardrail)
        }
        return matched
    }

    private static func matches(_ match: GuardrailResourceMatch, environment: String?) throws -> Bool {
        switch match {
        case .any:
            return true
        case .environment(let wanted):
            // A resource with no environment attribute is not in any
            // environment, so an environment ceiling does not reach it.
            return environment == wanted
        }
    }

    private static func matches(
        _ match: GuardrailPrincipalMatch,
        principalType: IAMPrincipalType,
        principalID: UUID,
        organizationID: UUID?,
        on db: any Database
    ) async throws -> Bool {
        switch match {
        case .any:
            return true

        case .user(let id):
            return principalType == .user && principalID == id

        case .group(let id):
            if principalType == .group { return principalID == id }
            // A ceiling on a group covers its members: the group is how the
            // grant reaches the user, so it has to be how the ceiling does too.
            let memberships = try await UserGroup.query(on: db)
                .filter(\.$user.$id == principalID)
                .filter(\.$group.$id == id)
                .count()
            return memberships > 0

        case .externalToOrganization:
            // Without a resolvable organization there is no "outside" to be
            // on, and guessing would mean forbidding on a truncated tree walk.
            guard let organizationID else { return false }
            switch principalType {
            case .user:
                let memberships = try await UserOrganization.query(on: db)
                    .filter(\.$user.$id == principalID)
                    .filter(\.$organization.$id == organizationID)
                    .count()
                return memberships == 0
            case .group:
                guard let group = try await Group.find(principalID, on: db) else { return false }
                return group.$organization.id != organizationID
            }
        }
    }

    /// The `environment` attribute of a resource, for resource-side matching.
    /// Only the types that carry one answer; containers have no environment of
    /// their own, since environment is an attribute and never a container.
    private static func resourceEnvironment(of node: IAMNode, on db: any Database) async throws -> String? {
        switch node.type {
        case .virtualMachine:
            return try await VM.find(node.id, on: db)?.environment
        case .sandbox:
            return try await Sandbox.find(node.id, on: db)?.environment
        default:
            return nil
        }
    }
}
