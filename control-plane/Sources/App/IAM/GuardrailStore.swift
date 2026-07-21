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
/// Shipped ahead of the evaluator (#480/#482) as the store and the semantics,
/// so the Cedar integration and the symcc write-time check (#484) build on
/// something already tested; since cutover the evaluator enforces these
/// ceilings on every request.
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
        try validateNotSelfLocking(
            actions: canonicalActions, principalMatch: principalMatch, resourceMatch: resourceMatch)

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

    /// The action that removes a guardrail. A ceiling covering this one is a
    /// ceiling that can outlaw its own removal.
    static let policyWriteAction = "iam:setPolicy"

    /// Refuse the ceilings nobody can climb back out of.
    ///
    /// A guardrail that applies to **every** principal on **every** resource
    /// and forbids `iam:setPolicy` denies the one action needed to disable or
    /// delete it, on its own subtree and everything below. `*` is the obvious
    /// spelling, but `iam:*` and a bare `iam:setPolicy` bolt the same door, so
    /// the test is whether the action patterns *match* `iam:setPolicy` rather
    /// than whether they equal the wildcard.
    ///
    /// Conditioned ceilings on `iam:setPolicy` stay legal and are useful
    /// ("contractors may not set policy here"): someone outside the condition
    /// can still undo them. It is only the unconditional form that leaves no
    /// one holding the key.
    private static func validateNotSelfLocking(
        actions: [String],
        principalMatch: GuardrailPrincipalMatch,
        resourceMatch: GuardrailResourceMatch
    ) throws {
        guard principalMatch == .any, resourceMatch == .any else { return }
        guard GuardrailActions.matches(actions, action: policyWriteAction) else { return }
        throw GuardrailError.locksOutPolicyAdministration
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

        try validateNotSelfLocking(
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
    ///
    /// Every type that stores one has to be listed, or an environment ceiling
    /// silently stops covering that type — a snapshot of a production sandbox
    /// is as much a production resource as the sandbox. Containers are absent
    /// because they genuinely have no environment: it is an attribute, never a
    /// container.
    ///
    /// Shared with `EntitySliceLoader` (#480), which stamps the same attribute
    /// onto the Cedar entity so the compiled environment ceilings match
    /// exactly what this store's own evaluation matches.
    static func resourceEnvironment(of node: IAMNode, on db: any Database) async throws -> String? {
        switch node.type {
        case .virtualMachine:
            return try await VM.find(node.id, on: db)?.environment
        case .sandbox:
            return try await Sandbox.find(node.id, on: db)?.environment
        case .sandboxSnapshot:
            return try await SandboxSnapshot.find(node.id, on: db)?.environment
        case .organization, .organizationalUnit, .project, .image, .network,
            .floatingIP, .volume, .volumeSnapshot, .site, .agent:
            // Listed exhaustively rather than defaulted: a new resource type
            // carrying an environment should fail to compile here, not quietly
            // fall out of every environment ceiling.
            return nil
        }
    }
}
